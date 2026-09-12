-- Chute, cross country race timing
-- Migration 0001: initial schema
--
-- Run this whole file in the Supabase SQL editor.
-- Every table has RLS enabled explicitly. Tables created through the SQL
-- editor do NOT get RLS by default, and the anon key lives in a public
-- repo, so this is not optional.

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------- teams

create table public.teams (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  short_name  text,
  is_home     boolean not null default false,
  created_at  timestamptz not null default now()
);

create unique index teams_name_key on public.teams (lower(name));

-- Only one home team. Drop this index if you ever time for two programs.
create unique index teams_one_home on public.teams (is_home) where is_home;

-- ------------------------------------------------------------- athletes

create table public.athletes (
  id          uuid primary key default gen_random_uuid(),
  team_id     uuid not null references public.teams (id) on delete cascade,
  first_name  text not null,
  last_name   text not null default '',
  division    text not null check (division in ('G','B')),
  grade       smallint check (grade between 5 and 8),
  active      boolean not null default true,
  sort_seed   integer not null default 0,   -- typed order, the race-one fallback
  created_at  timestamptz not null default now()
);

create index athletes_team_div on public.athletes (team_id, division) where active;

-- Same name twice on the same squad is almost always a typo, not twins.
create unique index athletes_name_key
  on public.athletes (team_id, division, lower(first_name), lower(last_name));

-- ---------------------------------------------------------------- meets

create table public.meets (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  -- plain date, never timestamptz. An 8pm race in Atlanta stamped in UTC
  -- reports as the next day.
  meet_date   date not null,
  venue       text,
  created_at  timestamptz not null default now()
);

create index meets_date on public.meets (meet_date desc);

-- ---------------------------------------------------------------- races

create table public.races (
  id          uuid primary key default gen_random_uuid(),
  meet_id     uuid not null references public.meets (id) on delete cascade,
  division    text not null check (division in ('G','B')),
  distance_m  integer,
  -- the gun. every finish is an offset from this.
  started_at  timestamptz,
  -- null means still running. "reopen clock" sets this back to null.
  ended_at    timestamptz,
  created_at  timestamptz not null default now(),

  constraint races_end_after_start
    check (ended_at is null or started_at is null or ended_at >= started_at)
);

create unique index races_meet_division on public.races (meet_id, division);
create index races_live on public.races (id) where ended_at is null;

-- ------------------------------------------------------------- finishes

create table public.finishes (
  id          uuid primary key default gen_random_uuid(),
  race_id     uuid not null references public.races (id) on delete cascade,

  -- timing facts. immutable once written, see the trigger below.
  place       integer not null check (place > 0),
  elapsed_ms  integer not null check (elapsed_ms >= 0),

  -- identity. freely editable during reconciliation.
  athlete_id  uuid references public.athletes (id) on delete set null,
  team_id     uuid references public.teams (id) on delete set null,

  -- generated on the device at tap time. the idempotency key: a POST that
  -- succeeds but whose response is lost can be retried safely.
  client_id   uuid not null,

  recorded_at timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create unique index finishes_race_place  on public.finishes (race_id, place);
create unique index finishes_race_client on public.finishes (race_id, client_id);
create index finishes_athlete on public.finishes (athlete_id) where athlete_id is not null;

-- An athlete cannot finish the same race twice.
create unique index finishes_race_athlete
  on public.finishes (race_id, athlete_id) where athlete_id is not null;

-- ------------------------------------------------- immutability + touch

create or replace function public.finishes_guard()
returns trigger language plpgsql as $$
begin
  if new.place <> old.place or new.elapsed_ms <> old.elapsed_ms then
    raise exception
      'place and elapsed_ms are immutable (finish %). Delete and re-record instead.',
      old.id;
  end if;
  new.updated_at := now();
  return new;
end $$;

create trigger finishes_guard_trg
  before update on public.finishes
  for each row execute function public.finishes_guard();

-- ------------------------------------------------------------------ RLS

alter table public.teams    enable row level security;
alter table public.athletes enable row level security;
alter table public.meets    enable row level security;
alter table public.races    enable row level security;
alter table public.finishes enable row level security;

-- Timers are signed in. Nothing is readable or writable anonymously.
-- The parent-facing read path is deliberately not built here; when it is,
-- it goes in as a view granted to anon, never as a policy on these tables.
do $$
declare t text;
begin
  foreach t in array array['teams','athletes','meets','races','finishes'] loop
    execute format(
      'create policy %I on public.%I for all to authenticated using (true) with check (true)',
      t || '_authenticated', t);
  end loop;
end $$;

-- ---------------------------------------------------------------- views

-- One row per finisher with everything the results screen needs.
create or replace view public.race_detail as
select
  f.race_id,
  m.meet_date,
  m.name                                as meet_name,
  r.division,
  f.place,
  f.elapsed_ms,
  t.name                                as team_name,
  t.is_home,
  a.id                                  as athlete_id,
  nullif(trim(a.first_name || ' ' || a.last_name), '') as runner,
  a.grade
from public.finishes f
join public.races r  on r.id = f.race_id
join public.meets m  on m.id = r.meet_id
left join public.teams    t on t.id = coalesce(f.team_id, (select team_id from public.athletes where id = f.athlete_id))
left join public.athletes a on a.id = f.athlete_id;

-- Team score: sum of the first five places. Runners 6 and 7 displace but
-- do not score. This scores on raw place across the whole field, which is
-- correct only when every other team fielded five. See the note in the app.
create or replace view public.team_scores as
with ranked as (
  select
    f.race_id,
    coalesce(f.team_id, a.team_id) as team_id,
    f.place,
    row_number() over (
      partition by f.race_id, coalesce(f.team_id, a.team_id)
      order by f.place
    ) as team_rank
  from public.finishes f
  left join public.athletes a on a.id = f.athlete_id
  where coalesce(f.team_id, a.team_id) is not null
)
select
  race_id,
  team_id,
  count(*) filter (where team_rank <= 5)            as scorers,
  sum(place) filter (where team_rank <= 5)          as score,
  min(place) filter (where team_rank = 6)           as sixth_place,  -- tiebreak
  count(*)                                          as finishers
from ranked
group by race_id, team_id
having count(*) filter (where team_rank <= 5) = 5;

-- Most recent result per athlete. This is what orders the name picker.
create or replace view public.athlete_last_result as
select distinct on (f.athlete_id)
  f.athlete_id,
  f.elapsed_ms,
  f.place,
  m.meet_date,
  m.name as meet_name
from public.finishes f
join public.races r on r.id = f.race_id
join public.meets m on m.id = r.meet_id
where f.athlete_id is not null
order by f.athlete_id, m.meet_date desc, f.recorded_at desc;

-- ----------------------------------------------------------------- seed

insert into public.teams (name, short_name, is_home)
values ('Peachtree MS', 'Peachtree', true);

-- Kept warm by the GitHub Actions ping so the free project does not pause.
create table public.heartbeat (
  id      smallint primary key default 1,
  beat_at timestamptz not null default now(),
  constraint heartbeat_singleton check (id = 1)
);
insert into public.heartbeat (id) values (1);
alter table public.heartbeat enable row level security;
create policy heartbeat_anon on public.heartbeat
  for select to anon using (true);

-- Chute
-- Migration 0003: strip residual anon privileges
--
-- 0002 granted SELECT on heartbeat without first revoking Supabase's blanket
-- grant, so anon kept DELETE, INSERT, REFERENCES, TRIGGER, TRUNCATE and
-- UPDATE on it as well.
--
-- Most of those are harmless: RLS evaluates them and the select-only policy
-- rejects the insert and filters update and delete to zero rows.
--
-- TRUNCATE is the exception. It is NOT subject to row-level security. Verified
-- against Postgres 16: as anon, `truncate heartbeat` succeeds and empties the
-- table while every other write verb is blocked. A grant that RLS does not
-- cover is not defence in depth, it is just a hole with a policy next to it.
--
-- Revoke first, then grant exactly what is needed. That order matters and is
-- the mistake 0002 made.

revoke all on public.heartbeat from anon;
grant select on public.heartbeat to anon;

-- Sweep anything else that survived, now and for objects added later.
do $$
declare r record;
begin
  for r in
    select table_name
    from information_schema.role_table_grants
    where table_schema = 'public'
      and grantee = 'anon'
      and table_name <> 'heartbeat'
  loop
    execute format('revoke all on public.%I from anon', r.table_name);
  end loop;
end $$;

revoke all on schema public from anon;
grant usage on schema public to anon;   -- required to reach heartbeat at all

-- Verify. Expect exactly one row: heartbeat, SELECT.
select
  table_name,
  string_agg(privilege_type, ', ' order by privilege_type) as privs
from information_schema.role_table_grants
where table_schema = 'public' and grantee = 'anon'
group by table_name
order by table_name;

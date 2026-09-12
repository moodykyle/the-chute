-- Chute
-- Migration 0002: close the view RLS bypass
--
-- Supabase grants everything in `public` to anon and authenticated by
-- default, so the views in 0001 inherited SELECT for anon. Views have no
-- RLS of their own, and in Postgres 15+ they default to
-- security_invoker = off, meaning they execute with the owner's rights and
-- read straight past the RLS on the tables underneath.
--
-- Net effect before this migration: anyone holding the anon key could read
-- athlete names, grades and times through athlete_last_result, even though
-- every base table reported RLS enabled.
--
-- Two independent fixes, applied together on purpose. Either alone would
-- close it; both means a future `grant` typo does not silently reopen it.

-- 1. Make the views run as the caller, so base-table RLS applies to them.
alter view public.race_detail          set (security_invoker = on);
alter view public.team_scores          set (security_invoker = on);
alter view public.athlete_last_result  set (security_invoker = on);

-- 2. Take anon off the views entirely. The parent-facing read path, when it
--    is built, gets its own purpose-built view and an explicit grant.
revoke all on public.race_detail         from anon;
revoke all on public.team_scores         from anon;
revoke all on public.athlete_last_result from anon;

-- Signed-in timers still need to read them.
grant select on public.race_detail          to authenticated;
grant select on public.team_scores          to authenticated;
grant select on public.athlete_last_result  to authenticated;

-- 3. Anon has no business writing to any table. RLS already blocks this,
--    but leaving write grants in place means the only thing standing
--    between a policy mistake and an open database is that one policy.
revoke all on public.teams    from anon;
revoke all on public.athletes from anon;
revoke all on public.meets    from anon;
revoke all on public.races    from anon;
revoke all on public.finishes from anon;

-- The keepalive workflow reads this with the anon key, so it stays.
grant select on public.heartbeat to anon;

-- 4. Stop future objects inheriting the same default grant.
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke all on sequences from anon;
alter default privileges in schema public revoke all on functions from anon;

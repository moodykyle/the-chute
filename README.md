# Chute

Cross country race timing for Peachtree MS. One phone, one thumb, one chute.

Tap once for every runner who crosses the line. Tap the team button when it is
one of ours. Sort out names afterward. Places and times are never edited once
recorded, only identities are.

## Layout

```
index.html                          the whole app, single file, vanilla JS
supabase/migrations/0001_init.sql   schema, constraints, RLS, views
.github/workflows/keepalive.yml     daily ping so the free project does not pause
```

## Setup order

1. Create the Supabase project, run `0001_init.sql` in the SQL editor.
2. Confirm RLS is on for all six tables (Database, Tables). Tables created
   through the SQL editor do not get RLS automatically.
3. Copy the project URL and the **anon** key. Never the service_role key.
4. Push this repo, enable Pages on `main` at root.
5. Add `SUPABASE_URL` and `SUPABASE_ANON_KEY` as Actions secrets, then run the
   keepalive workflow once by hand to confirm it returns 200.

## Current state

The app runs entirely on `localStorage`. Supabase is provisioned but not yet
wired in. The next piece is an IndexedDB queue that owns the capture path, so
no network call ever sits between a tap and a recorded finish.

## Rules that are load bearing

- `place` and `elapsed_ms` are immutable, enforced by a trigger. Reconciliation
  only ever touches `athlete_id` and `team_id`.
- Every finish carries a `client_id` generated on the device. It is the
  idempotency key. A POST that succeeds but whose response is lost can be
  retried without duplicating a runner.
- `meets.meet_date` is a plain `date`. An evening race stamped in UTC reports
  as the next day in Atlanta.
- Team score is the sum of the first five places. Runners six and seven
  displace but do not score. Scoring uses raw place across the field, which is
  correct only when every other team fielded five.
- No anon policies on any table. Parent-facing reads, when built, go in as a
  view granted to anon.

# Roulette Night

Roulette Night is a single-event multiplayer roulette app built with vanilla HTML, CSS, JavaScript, and Supabase.

## Open it

With Node.js installed, from this folder run:

```powershell
npx --yes http-server -p 8000
```

Then visit `http://localhost:8000`. Stop the server with `Ctrl+C`.

Alternatively, if Python is installed, run `python -m http.server 8000`.

For the Supabase entry screen, open `http://localhost:8000/?join=YOUR_EVENT_JOIN_CODE` or paste the event's join code into the form. The browser loads the Supabase JS v2 client from jsDelivr and reads the Project URL and publishable/anon key from the ignored local file `js/supabase-config.js`.

## Architecture and status

For a system diagram and explanation of Cloudflare Pages, Supabase, browser sessions, database RPCs, and the round worker, see [docs/architecture.md](docs/architecture.md).

The frontend is served as static files. `js/roulette.js` contains the shared roulette rules; `js/app.js` renders the table and chip tray; `js/supabase-join.js` restores guest/admin sessions and handles event/team entry; `js/supabase-game.js` reads shared snapshots and submits transactional bets and admin actions. Supabase owns bankrolls, rounds, results, and payouts. Snapshot polling keeps clients synchronized, with Realtime subscriptions as an additional update hint when enabled.

The table supports zero-less 1–36 roulette, the official red mapping, structured inside and outside bets, boundary hit targets, selectable $1/$5/$25/$100/$500/$1,000 chips, and standard payouts. Inside bet amounts are marked at their board positions, and bankrolls are shared by team.

The core transactional RPC definitions are in `supabase/migrations/20261014000200_roulette_rpcs.sql`; guest join/team/kick RPCs are in `supabase/migrations/20261016000100_guest_join_and_kick.sql`. The admin player roster and live activity feed are included in the migrations dated `20261021`. Configure `js/supabase-config.js` with the Project URL and publishable/anon key. Apply local schema updates with `npx supabase db push`. The automatic round worker requires `pg_cron` and `supabase/schedule_round_worker.sql`; for a one-time event, keep it enabled during testing and the event through final settlement, then deactivate it between sessions.

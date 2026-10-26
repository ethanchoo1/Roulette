# Roulette Night architecture

This page explains where the app runs, where game data lives, and how a player action reaches the shared game state.

## At a glance

```mermaid
flowchart LR
    Player[Player or admin browser]
    GitHub[GitHub repository]
    Pages[Cloudflare Pages<br/>static site and CDN]
    Auth[Supabase Auth<br/>guest sessions and admin sign-in]
    API[Supabase API<br/>RPC endpoints and access checks]
    DB[(Supabase Postgres<br/>events, teams, bets, rounds, ledger)]
    Cron[Supabase Cron<br/>pg_cron scheduler]
    Worker[system_advance_rounds()<br/>database transaction]

    GitHub -->|connected branch deploy| Pages
    Pages -->|HTML, CSS, JavaScript| Player
    Player <-->|sign-in and session| Auth
    Player <-->|snapshots and game RPCs| API
    API <-->|RLS, validation, transactions| DB
    Cron -->|about once per second while enabled| Worker
    Worker -->|locks expired rounds, picks result, pays bets| DB
    DB -. optional Realtime hints .-> Player
```

## What each service does

### Cloudflare Pages: serves the website

Cloudflare Pages hosts the static frontend files: `index.html`, `css/styles.css`, and the JavaScript under `js/`. It serves those files over HTTPS from its edge network. The GitHub connection watches the configured branch and publishes a new frontend deployment when changes are pushed.

Pages does **not** hold the game database or decide roulette results. This project does not currently use a separate application server or Cloudflare Worker for game logic.

### Supabase: authentication, database, and backend logic

Supabase is the backend service for this app. It combines:

- **Auth:** anonymous guest identities and password sign-in for the admin.
- **Postgres:** the source of truth for the event, memberships, teams, balances, bets, rounds, and bankroll ledger.
- **API and database RPCs:** the browser calls named SQL functions for operations such as joining, placing bets, changing balances, and advancing rounds. These functions validate access and update related records in transactions.
- **Row Level Security (RLS):** database policies limit what authenticated users can read. Sensitive changes go through the approved RPC functions; the browser does not directly write balances, results, or payouts.
- **Cron (`pg_cron`):** schedules the database worker that advances timed rounds. It should remain enabled during testing or an event through final settlement, and can be disabled between sessions.

Supabase is both the **data source** and the app’s **backend**. “Backend” here means Supabase Auth, its API, database policies, and SQL functions; there is no custom Node server in this repository.

### Browser: renders the game and sends requests

The browser runs the UI and roulette animation. It stores the authenticated session using Supabase’s browser client, requests snapshots, and sends user actions to Supabase. The visual countdown and animation are client-side, but betting deadlines, balances, winning numbers, and payouts are decided by the database.

The browser uses the project URL and public/publishable key from `js/supabase-config.js`. A public key is intended for browser use; a Supabase service-role or database secret must never be placed in frontend files.

## Typical game flow

```mermaid
sequenceDiagram
    participant B as Browser
    participant A as Supabase Auth
    participant S as Supabase RPC/API
    participant D as Postgres
    participant C as Supabase Cron

    B->>A: Create/restore guest session or sign in admin
    B->>S: Validate invite code and request join options
    B->>S: Join existing team or create one
    S->>D: Check event and membership; update transactionally
    B->>S: Read game snapshot and submit bet RPCs
    S->>D: Validate round, team funds, bet, deadline; update bet and ledger
    C->>D: Call system_advance_rounds()
    D->>D: Lock round, select official result, settle winning bets
    B->>S: Poll snapshot (Realtime can also hint that data changed)
    S->>D: Return current round, teams, balances, bets, and activity
    B->>B: Animate wheel to the server-selected result
```

### Joining

An invite code identifies the active event. A guest signs in anonymously, then chooses an existing team or creates one if fewer than four teams exist. The resulting Auth session and event membership are saved by the browser so a refresh can restore the same guest identity on that browser.

### Betting and settlement

When the admin opens betting, Postgres records the round status and deadline using its own clock. Bet RPCs validate the bet type and numbers, confirm the caller belongs to a team, check available funds and the deadline, then update the bet, team balance, and ledger in one transaction.

The scheduled worker advances the round and chooses the official winning number in Postgres. It pays winning bets and records the result there. The browser reads that result and animates to it; the animation does not determine the outcome.

### Keeping browsers in sync

The frontend polls `get_game_snapshot` every second. It also subscribes to Supabase Realtime changes for rounds, teams, and bets when those tables are enabled in the project’s Realtime publication. Polling is the synchronization fallback; Realtime is an update hint.

## Where the code lives

| Path | Responsibility |
| --- | --- |
| `index.html` | App structure and frontend script/style loading |
| `css/styles.css` | Casino UI, responsive layouts, and wheel appearance |
| `js/roulette.js` | Roulette number/color rules, bet validation, and payout helpers for UI use |
| `js/app.js` | UI rendering, board interactions, chips, and wheel animation |
| `js/supabase-config.js` | Browser-safe Supabase project URL and public key; ignored by Git in this setup |
| `js/supabase-join.js` | Guest/admin sign-in, invite handling, and team entry |
| `js/supabase-game.js` | Snapshot polling, Realtime subscription, bets, and admin RPC calls |
| `supabase/migrations/` | Database schema, policies, and transactional RPC definitions |
| `supabase/schedule_round_worker.sql` | SQL command to schedule the database round worker |
| `supabase/API.md` | RPC contract, access rules, and operational setup notes |

## Deployment and operations

1. Push frontend and migration files to the configured GitHub branch. Cloudflare Pages deploys the static website from that branch.
2. Apply database changes separately with `npx supabase db push`. A frontend deployment does not apply Supabase migrations.
3. Keep the Supabase round worker scheduled while testing or hosting the live event through its final settlement. Disable the schedule between sessions if the app is not in use.
4. Keep the service-role key and database credentials out of GitHub and browser code. Only the public/publishable key belongs in the frontend configuration.

For the database contract and detailed setup, see [`supabase/API.md`](../supabase/API.md). For the basic local run instructions, see [`README.md`](../README.md).

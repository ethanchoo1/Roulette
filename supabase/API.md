# Roulette Night backend contract

This document defines the Supabase backend boundary. The migrations create the schema, read policies, transactional game RPCs, guest entry/team membership RPCs, admin player roster, and activity feed. Run `npx supabase db push` to apply pending migrations. The browser must not write bankrolls, round state, results, or payouts directly.

## Data and access

The schema is in `migrations/20261014000100_roulette_core.sql`.

- `events`: single event configuration, including the server betting duration and legacy default chip value.
- `teams`: event teams and authoritative available balance.
- `event_members`: mapping from Supabase Auth users to a display name, team, and the `player` or `admin` role.
- `rounds`: round number, state, server deadline, and official result.
- `bets`: one row per team, round, bet kind, and canonical number set. `amount` is the accumulated stake; zero means the row has been fully removed and remains for audit history.
- `team_ledger`: immutable bankroll changes for wagers, refunds, payouts, and admin adjustments.

All exposed tables have RLS enabled. Authenticated event members can read event game state; a player can read only their own ledger, while admins can read all event ledgers. Browser roles have no direct table write privileges. A visitor must first use Supabase anonymous sign-in, which creates an authenticated user ID; unauthenticated requests still cannot read or change game data.

## RPC contract

User-facing RPCs run transactionally, require an authenticated caller, return the updated rows or a game snapshot, and raise a stable error code on rejection. Mutation requests carry a client-generated `request_id` UUID so network retries cannot apply the same bankroll change twice. Repeating the same request returns its prior result; reusing its ID for a different operation is rejected.

Stable rejection codes: `UNAUTHENTICATED`, `NOT_EVENT_MEMBER`, `ADMIN_REQUIRED`, `EVENT_NOT_ACTIVE`, `NO_ACTIVE_ROUND`, `INVALID_STATE`, `BETTING_CLOSED`, `INVALID_BET`, `INVALID_DELTA`, `INVALID_REQUEST`, `TEAM_REQUIRED`, `TEAM_NOT_FOUND`, `BET_NOT_FOUND`, `INSUFFICIENT_FUNDS`, `DUPLICATE_REQUEST`, `PAYOUT_OVERFLOW`, `JOIN_CLOSED_OR_INVALID`, `INVALID_DISPLAY_NAME`, `INVALID_TEAM_NAME`, `CHOOSE_OR_CREATE_TEAM`, `NAME_ALREADY_IN_USE`, `ADMIN_MEMBERSHIP_EXISTS`, `INVALID_KICK_TARGET`, and `PLAYER_NOT_FOUND`.

### `admin_prepare_round(p_event_id uuid)`

Admin only. Creates round 1 in `waiting`, or the next round after a prior `result`. Rejects if another round is active. Returns the new round.

### `admin_start_betting(p_event_id uuid)`

Admin only. Transitions the current `waiting` round to `betting`. Sets `opened_at` and `betting_deadline` from the database clock and the event's configured `betting_seconds` (60 by default). Returns the round and deadline.

### `member_change_bet(p_event_id uuid, p_bet_type text, p_numbers integer[], p_delta bigint, p_request_id uuid)`

Player or admin who belongs to a team. The server derives the team from `event_members`; callers cannot select another team's bankroll. Positive `p_delta` values must be $1, $5, $25, $100, $500, or $1,000. Negative values refund up to the entire remaining amount on the caller's team bet, allowing removal of the final remainder even when it is below the selected chip value. The server locks the current round and team rows, checks the round is `betting` and the database time is before the deadline, validates the complete roulette combination, then updates the bet and ledger atomically. Apply `20261017000100_multiple_chip_values.sql` to enable the selectable chip tray.

Canonical bet type and number combinations are `straight`, `split`, `street`, `corner`, `six-line`, `dozen`, `column`, `red`, `black`, `odd`, `even`, `low`, and `high`. Values must be unique integers from 1 through 36. For the even-money bets, the server uses the official fixed red set and number ranges; color is never derived from parity.

Payouts use standard net odds and return the stake as part of the gross payout: straight 35:1, split 17:1, street 11:1, corner 8:1, six-line 5:1, dozen/column 2:1, and even-money 1:1. A losing stake remains debited; a winning bet credits `stake × (net odds + 1)` once.

### `admin_lock_bets(p_event_id uuid)`

Admin only. Transitions `betting` to `locked` immediately, including before the deadline if the admin closes betting early. Repeated calls while already locked return the existing round; other invalid transitions are rejected.

### `admin_spin_round(p_event_id uuid)`

Admin only manual spin after `locked`. Sets state to `spinning`; the scheduled server worker selects the result and settles after the animation interval. Repeated calls while spinning return the existing round; it cannot replace a result.

### `system_advance_rounds()`

Service-only scheduled operation. Finds betting rounds whose database deadline has passed and advances them through `locked`, `spinning`, and `result`, with a short visible spin interval. At `result`, it selects a server-side number, settles each bet, and writes one payout ledger entry per winning bet. It is safe to retry. Run it on a trusted server schedule about once a second; the client timer is display-only, and a bet submitted at or after the deadline is rejected even if the worker has not run yet.

### `admin_adjust_team_balance(p_event_id uuid, p_team_id uuid, p_delta bigint, p_reason text, p_request_id uuid)`

Admin only. Applies a non-negative resulting balance and writes an `admin_adjustment` ledger row. It is the only bankroll setup/adjustment path after provisioning.

### `get_game_snapshot(p_event_id uuid)`

Authenticated event member. Returns the current round, teams and balances, current round's positive-stake bets, the caller's team membership, and up to eight recent join/bankroll/bet events. The member roster is populated only for admins. It never accepts a caller-supplied balance or result.

### `get_join_options(p_join_code uuid)`

Authenticated user, including an anonymous Auth user. Returns the active event name, chip value, and team names/player counts for the invite link. It does not expose balances. The join code is a capability; share it only with people invited to this one-time event.

### `join_event(p_join_code uuid, p_display_name text, p_team_id uuid, p_new_team_name text)`

Authenticated user, including an anonymous Auth user. Pass exactly one of `p_team_id` or `p_new_team_name`. Joins an existing team or atomically creates a team, gives it the event's configured `starting_balance`, writes the corresponding starting-funds ledger row, and adds the creator as a player. Display and team names are trimmed and limited to 32 characters; team names are unique without regard to case. Repeating the call for a user already in the event returns their current membership and team, making refresh/retry safe. It never moves an existing member to another team.

### `admin_kick_member(p_event_id uuid, p_user_id uuid)`

Admin only. Removes a player from the event membership list. Their current anonymous Auth session remains valid, so they can rejoin with that identity through the invite link. The team bankroll and bets remain intact. Admin memberships cannot be kicked through this function, and an admin cannot kick their own account.

## State transitions

```text
waiting --admin_start_betting--> betting
betting --admin_lock_bets / deadline--> locked
locked --admin_spin_round / system_advance_rounds--> spinning --> result
result --admin_prepare_round--> waiting
```

The normal path is automatic at the deadline. Admin lock/spin operations are manual recovery controls.

## Realtime reads

The browser currently refreshes `get_game_snapshot` every second and also subscribes to `rounds`, `teams`, and `bets` as a faster update hint. Enable those tables in the Supabase Realtime publication for push updates; polling remains a fallback. RLS and server-owned RPC writes remain authoritative.

## Initial setup and remaining decisions

1. Provision the event, initial admin membership, and starting balance through a trusted service-side setup script or Supabase dashboard. No public RPC can grant admin access or promote a member.
2. Enable anonymous sign-ins in Supabase Auth. The browser must use the public/publishable key only; never expose the service-role key.
3. Enable the Supabase Cron `pg_cron` extension and schedule `schedule_round_worker.sql` while testing or running an event. Keep it active through the final round settlement, then deactivate it between sessions. If it is inactive during a round, automatic deadline locking and result settlement pause.
4. Enable the game tables in Realtime for push updates; current polling covers the core game flow meanwhile. Admin player roster and live activity are implemented in the migrations dated `20261021`.

The frontend has a Supabase identity and team-entry gate in `js/supabase-join.js` and a shared game client in `js/supabase-game.js`. It restores Auth sessions, supports anonymous guest entry/team creation/joining and admin password sign-in, reads snapshots, submits bet chip changes, and routes admin round and balance actions through RPCs. The database remains authoritative for bets, round state, results, and payouts.

Do not put a Supabase service-role key in `index.html` or browser JavaScript. The existing `js/roulette.js` remains useful for local display and client-side validation, but all write decisions and payouts must be revalidated server-side.

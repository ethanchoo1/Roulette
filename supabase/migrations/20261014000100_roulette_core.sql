-- Roulette Night's first server-side schema.
-- All game writes are intended to go through authenticated database functions;
-- browser roles receive read-only access to member-visible rows.

create type public.round_status as enum (
  'waiting',
  'betting',
  'locked',
  'spinning',
  'result'
);

create or replace function public.valid_roulette_numbers(p_numbers integer[])
returns boolean
language sql
immutable
set search_path = ''
as $$
  select coalesce(
    cardinality(p_numbers) between 1 and 36
    and array_position(p_numbers, null) is null
    and (select bool_and(n between 1 and 36) from unnest(p_numbers) as n)
    and (select count(*) = count(distinct n) from unnest(p_numbers) as n),
    false
  );
$$;

create table public.events (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null,
  betting_seconds integer not null default 60 check (betting_seconds between 10 and 600),
  chip_value bigint not null default 25 check (chip_value > 0),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create unique index events_one_active_idx on public.events (active) where active;

create table public.teams (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  name text not null,
  balance bigint not null default 0 check (balance >= 0),
  created_at timestamptz not null default now(),
  unique (event_id, id),
  unique (event_id, name)
);

create table public.event_members (
  event_id uuid not null references public.events(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('admin', 'player')),
  team_id uuid,
  joined_at timestamptz not null default now(),
  primary key (event_id, user_id),
  foreign key (event_id, team_id) references public.teams(event_id, id),
  check (role = 'admin' or team_id is not null)
);

create table public.rounds (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  round_number integer not null check (round_number > 0),
  status public.round_status not null default 'waiting',
  betting_deadline timestamptz,
  winning_number smallint check (winning_number between 1 and 36),
  opened_by uuid references auth.users(id),
  opened_at timestamptz,
  locked_at timestamptz,
  spun_at timestamptz,
  settled_at timestamptz,
  created_at timestamptz not null default now(),
  unique (event_id, round_number),
  unique (event_id, id),
  check ((status = 'result') = (winning_number is not null)),
  check (status <> 'betting' or betting_deadline is not null)
);

create index rounds_event_latest_idx
  on public.rounds (event_id, round_number desc);

create table public.bets (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null,
  round_id uuid not null,
  team_id uuid not null,
  bet_type text not null check (bet_type in (
    'straight', 'split', 'street', 'corner', 'six-line',
    'dozen', 'column', 'red', 'black', 'odd', 'even', 'low', 'high'
  )),
  numbers integer[] not null check (public.valid_roulette_numbers(numbers)),
  amount bigint not null check (amount >= 0),
  placed_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (event_id, round_id) references public.rounds(event_id, id) on delete cascade,
  foreign key (event_id, team_id) references public.teams(event_id, id) on delete cascade,
  unique (round_id, team_id, bet_type, numbers)
);

create index bets_event_round_idx on public.bets (event_id, round_id);
create index bets_team_round_idx on public.bets (team_id, round_id);

create table public.team_ledger (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null,
  team_id uuid not null,
  round_id uuid,
  bet_id uuid references public.bets(id) on delete set null,
  entry_type text not null check (entry_type in (
    'starting_funds', 'wager', 'bet_refund', 'payout', 'admin_adjustment'
  )),
  reason text,
  amount_delta bigint not null check (amount_delta <> 0),
  balance_after bigint not null check (balance_after >= 0),
  request_id uuid not null,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  foreign key (event_id, team_id) references public.teams(event_id, id) on delete cascade,
  foreign key (event_id, round_id) references public.rounds(event_id, id),
  unique (team_id, request_id)
);

create index team_ledger_team_created_idx
  on public.team_ledger (team_id, created_at desc);

create unique index team_ledger_one_payout_per_bet_idx
  on public.team_ledger (round_id, bet_id)
  where entry_type = 'payout' and bet_id is not null;

-- Exposed tables are readable by authenticated members only. Mutations will be
-- granted to narrow RPC functions after those functions are implemented.
alter table public.events enable row level security;
alter table public.teams enable row level security;
alter table public.event_members enable row level security;
alter table public.rounds enable row level security;
alter table public.bets enable row level security;
alter table public.team_ledger enable row level security;

revoke all on public.events, public.teams, public.event_members,
  public.rounds, public.bets, public.team_ledger
  from anon, authenticated;
grant select on public.events, public.teams, public.event_members,
  public.rounds, public.bets, public.team_ledger to authenticated;

create policy "members read their events"
  on public.events for select to authenticated
  using (exists (
    select 1 from public.event_members m
    where m.event_id = events.id and m.user_id = (select auth.uid())
  ));

create policy "event members read teams"
  on public.teams for select to authenticated
  using (exists (
    select 1 from public.event_members m
    where m.event_id = teams.event_id and m.user_id = (select auth.uid())
  ));

create policy "users read their own membership"
  on public.event_members for select to authenticated
  using (user_id = (select auth.uid()));

create policy "event members read rounds"
  on public.rounds for select to authenticated
  using (exists (
    select 1 from public.event_members m
    where m.event_id = rounds.event_id and m.user_id = (select auth.uid())
  ));

create policy "event members read bets"
  on public.bets for select to authenticated
  using (exists (
    select 1 from public.event_members m
    where m.event_id = bets.event_id and m.user_id = (select auth.uid())
  ));

create policy "team members and admins read ledger"
  on public.team_ledger for select to authenticated
  using (exists (
    select 1 from public.event_members m
    where m.event_id = team_ledger.event_id
      and m.user_id = (select auth.uid())
      and (m.role = 'admin' or m.team_id = team_ledger.team_id)
  ));

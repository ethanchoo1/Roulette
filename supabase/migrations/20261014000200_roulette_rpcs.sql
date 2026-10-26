-- Transactional game operations. These functions are the only client write path.

create schema if not exists app_private;
revoke all on schema app_private from public, anon, authenticated;
grant usage on schema app_private to postgres, service_role;

create or replace function app_private.require_event_member(
  p_event_id uuid,
  p_admin_only boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role text;
  v_team_id uuid;
begin
  if auth.uid() is null then
    raise exception using errcode = 'P0001', message = 'UNAUTHENTICATED';
  end if;

  select m.role, m.team_id into v_role, v_team_id
  from public.event_members m
  join public.events e on e.id = m.event_id
  where m.event_id = p_event_id
    and m.user_id = auth.uid()
    and e.active;

  if not found then
    raise exception using errcode = 'P0001', message = 'NOT_EVENT_MEMBER';
  end if;
  if p_admin_only and v_role <> 'admin' then
    raise exception using errcode = 'P0001', message = 'ADMIN_REQUIRED';
  end if;
  return v_team_id;
end;
$$;

create or replace function app_private.valid_roulette_bet(
  p_bet_type text,
  p_numbers integer[]
)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_numbers integer[];
  v_expected integer[];
  v_count integer;
  v_first integer;
  v_valid boolean := false;
begin
  if not public.valid_roulette_numbers(p_numbers) then
    return false;
  end if;
  select array_agg(n order by n), count(*)
    into v_numbers, v_count
  from unnest(p_numbers) as n;
  if v_count <> cardinality(p_numbers) then
    return false;
  end if;
  v_first := v_numbers[1];

  case p_bet_type
    when 'straight' then v_valid := v_count = 1;
    when 'split' then
      v_valid := v_count = 2 and
        abs((v_numbers[1] - 1) / 3 - (v_numbers[2] - 1) / 3) +
        abs((v_numbers[1] - 1) % 3 - (v_numbers[2] - 1) % 3) = 1;
    when 'street' then
      v_valid := v_count = 3 and (v_first - 1) % 3 = 0
        and v_numbers[2] = v_first + 1 and v_numbers[3] = v_first + 2;
    when 'corner' then
      v_valid := v_count = 4 and v_first <= 32
        and (v_first - 1) % 3 in (0, 1)
        and v_numbers = array[v_first, v_first + 1, v_first + 3, v_first + 4];
    when 'six-line' then
      v_valid := v_count = 6 and v_first <= 31
        and (v_first - 1) % 3 = 0
        and v_numbers = array[v_first, v_first + 1, v_first + 2,
          v_first + 3, v_first + 4, v_first + 5];
    when 'dozen' then
      v_valid := v_count = 12 and v_first in (1, 13, 25);
      if v_valid then
        select array_agg(n order by n) into v_expected
        from generate_series(v_first, v_first + 11) as n;
        v_valid := v_numbers = v_expected;
      end if;
    when 'column' then
      v_valid := v_count = 12 and v_first between 1 and 3;
      if v_valid then
        select array_agg(n order by n) into v_expected
        from generate_series(v_first, 36, 3) as n;
        v_valid := v_numbers = v_expected;
      end if;
    when 'red' then
      v_expected := array[1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36];
      v_valid := v_numbers = v_expected;
    when 'black' then
      select array_agg(n order by n) into v_expected
      from generate_series(1,36) as n
      where n <> all(array[1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36]);
      v_valid := v_numbers = v_expected;
    when 'odd' then
      select array_agg(n order by n) into v_expected from generate_series(1,35,2) as n;
      v_valid := v_numbers = v_expected;
    when 'even' then
      select array_agg(n order by n) into v_expected from generate_series(2,36,2) as n;
      v_valid := v_numbers = v_expected;
    when 'low' then
      select array_agg(n order by n) into v_expected from generate_series(1,18) as n;
      v_valid := v_numbers = v_expected;
    when 'high' then
      select array_agg(n order by n) into v_expected from generate_series(19,36) as n;
      v_valid := v_numbers = v_expected;
    else
      v_valid := false;
  end case;
  return coalesce(v_valid, false);
end;
$$;

create or replace function app_private.gross_payout(
  p_bet_type text,
  p_numbers integer[],
  p_stake bigint,
  p_result integer
)
returns bigint
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_net_odds integer;
  v_gross numeric;
begin
  if not app_private.valid_roulette_bet(p_bet_type, p_numbers)
    or p_result not between 1 and 36 or p_stake < 0 then
    raise exception using errcode = 'P0001', message = 'INVALID_BET';
  end if;
  if p_result <> all(p_numbers) then
    return 0;
  end if;
  v_net_odds := case p_bet_type
    when 'straight' then 35 when 'split' then 17 when 'street' then 11
    when 'corner' then 8 when 'six-line' then 5
    when 'dozen' then 2 when 'column' then 2
    when 'red' then 1 when 'black' then 1 when 'odd' then 1
    when 'even' then 1 when 'low' then 1 when 'high' then 1
  end;
  v_gross := p_stake::numeric * (v_net_odds + 1);
  if v_gross > 9223372036854775807 then
    raise exception using errcode = 'P0001', message = 'PAYOUT_OVERFLOW';
  end if;
  return v_gross::bigint;
end;
$$;

create or replace function public.admin_prepare_round(p_event_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_round public.rounds%rowtype;
  v_next integer;
begin
  perform app_private.require_event_member(p_event_id, true);
  perform 1 from public.events e where e.id = p_event_id and e.active for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'EVENT_NOT_ACTIVE';
  end if;
  if exists (select 1 from public.rounds r where r.event_id = p_event_id
      and r.status <> 'result') then
    raise exception using errcode = 'P0001', message = 'INVALID_STATE';
  end if;
  select coalesce(max(r.round_number), 0) + 1 into v_next
  from public.rounds r where r.event_id = p_event_id;
  insert into public.rounds(event_id, round_number, status)
  values (p_event_id, v_next, 'waiting') returning * into v_round;
  return to_jsonb(v_round);
end;
$$;

create or replace function public.admin_start_betting(p_event_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_round public.rounds%rowtype;
  v_seconds integer;
  v_now timestamptz := pg_catalog.clock_timestamp();
begin
  perform app_private.require_event_member(p_event_id, true);
  select e.betting_seconds into v_seconds
  from public.events e where e.id = p_event_id and e.active for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'EVENT_NOT_ACTIVE';
  end if;
  select r.* into v_round from public.rounds r
  where r.event_id = p_event_id order by r.round_number desc limit 1 for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'NO_ACTIVE_ROUND';
  end if;
  if v_round.status <> 'waiting' then
    raise exception using errcode = 'P0001', message = 'INVALID_STATE';
  end if;
  update public.rounds r set status = 'betting', opened_at = v_now,
      betting_deadline = v_now + pg_catalog.make_interval(secs => v_seconds),
      opened_by = auth.uid()
  where r.id = v_round.id returning * into v_round;
  return to_jsonb(v_round);
end;
$$;

create or replace function public.member_change_bet(
  p_event_id uuid,
  p_bet_type text,
  p_numbers integer[],
  p_delta bigint,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_team_id uuid;
  v_round public.rounds%rowtype;
  v_team public.teams%rowtype;
  v_bet public.bets%rowtype;
  v_prior public.team_ledger%rowtype;
  v_numbers integer[];
  v_chip bigint;
  v_ledger_type text;
  v_ledger_delta bigint;
begin
  v_team_id := app_private.require_event_member(p_event_id, false);
  if v_team_id is null then
    raise exception using errcode = 'P0001', message = 'TEAM_REQUIRED';
  end if;
  if p_request_id is null or p_delta is null then
    raise exception using errcode = 'P0001', message = 'INVALID_REQUEST';
  end if;
  if not public.valid_roulette_numbers(p_numbers)
    or cardinality(p_numbers) <> cardinality(array(select distinct n from unnest(p_numbers) as n)) then
    raise exception using errcode = 'P0001', message = 'INVALID_BET';
  end if;
  select array_agg(n order by n) into v_numbers from unnest(p_numbers) as n;
  if not app_private.valid_roulette_bet(p_bet_type, v_numbers) then
    raise exception using errcode = 'P0001', message = 'INVALID_BET';
  end if;

  select t.chip_value into v_chip from public.events t
  where t.id = p_event_id and t.active;
  if not found then
    raise exception using errcode = 'P0001', message = 'EVENT_NOT_ACTIVE';
  end if;
  if p_delta not in (v_chip, -v_chip) then
    raise exception using errcode = 'P0001', message = 'INVALID_DELTA';
  end if;
  v_ledger_type := case when p_delta > 0 then 'wager' else 'bet_refund' end;
  v_ledger_delta := -p_delta;

  -- Fast idempotent replay, including retries after the round has closed.
  select l.* into v_prior from public.team_ledger l
  where l.team_id = v_team_id and l.request_id = p_request_id;
  if found then
    if v_prior.entry_type <> v_ledger_type or v_prior.amount_delta <> v_ledger_delta then
      raise exception using errcode = 'P0001', message = 'DUPLICATE_REQUEST';
    end if;
    select t.* into v_team from public.teams t where t.id = v_team_id;
    select b.* into v_bet from public.bets b where b.id = v_prior.bet_id;
    if v_bet.id is null or v_bet.bet_type <> p_bet_type or v_bet.numbers <> v_numbers then
      raise exception using errcode = 'P0001', message = 'DUPLICATE_REQUEST';
    end if;
    return jsonb_build_object('replayed', true, 'round_id', v_prior.round_id,
      'bet', to_jsonb(v_bet), 'team', to_jsonb(v_team));
  end if;

  select r.* into v_round from public.rounds r
  where r.event_id = p_event_id order by r.round_number desc limit 1 for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'NO_ACTIVE_ROUND';
  end if;
  if v_round.status <> 'betting' or v_round.betting_deadline <= pg_catalog.clock_timestamp() then
    raise exception using errcode = 'P0001', message = 'BETTING_CLOSED';
  end if;

  select t.* into v_team from public.teams t
  where t.id = v_team_id and t.event_id = p_event_id for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'TEAM_REQUIRED';
  end if;
  -- Recheck after acquiring the team lock to serialize repeated client requests.
  select l.* into v_prior from public.team_ledger l
  where l.team_id = v_team_id and l.request_id = p_request_id;
  if found then
    if v_prior.entry_type <> v_ledger_type or v_prior.amount_delta <> v_ledger_delta then
      raise exception using errcode = 'P0001', message = 'DUPLICATE_REQUEST';
    end if;
    select b.* into v_bet from public.bets b where b.id = v_prior.bet_id;
    if v_bet.id is null or v_bet.bet_type <> p_bet_type or v_bet.numbers <> v_numbers then
      raise exception using errcode = 'P0001', message = 'DUPLICATE_REQUEST';
    end if;
    return jsonb_build_object('replayed', true, 'round_id', v_prior.round_id,
      'bet', to_jsonb(v_bet), 'team', to_jsonb(v_team));
  end if;

  select b.* into v_bet from public.bets b
  where b.round_id = v_round.id and b.team_id = v_team_id
    and b.bet_type = p_bet_type and b.numbers = v_numbers for update;
  if p_delta > 0 then
    if v_team.balance < p_delta then
      raise exception using errcode = 'P0001', message = 'INSUFFICIENT_FUNDS';
    end if;
    if found then
      update public.bets b set amount = b.amount + p_delta,
        updated_at = pg_catalog.clock_timestamp()
      where b.id = v_bet.id returning * into v_bet;
    else
      insert into public.bets(event_id, round_id, team_id, bet_type, numbers,
        amount, placed_by)
      values(p_event_id, v_round.id, v_team_id, p_bet_type, v_numbers,
        p_delta, auth.uid()) returning * into v_bet;
    end if;
    update public.teams t set balance = t.balance - p_delta
    where t.id = v_team_id returning * into v_team;
  else
    if not found or v_bet.amount < -p_delta then
      raise exception using errcode = 'P0001', message = 'BET_NOT_FOUND';
    end if;
    update public.bets b set amount = b.amount + p_delta,
      updated_at = pg_catalog.clock_timestamp()
    where b.id = v_bet.id returning * into v_bet;
    update public.teams t set balance = t.balance - p_delta
    where t.id = v_team_id returning * into v_team;
  end if;
  insert into public.team_ledger(event_id, team_id, round_id, bet_id,
    entry_type, amount_delta, balance_after, request_id, created_by)
  values(p_event_id, v_team_id, v_round.id, v_bet.id, v_ledger_type,
    v_ledger_delta, v_team.balance, p_request_id, auth.uid());
  return jsonb_build_object('replayed', false, 'round_id', v_round.id,
    'bet', to_jsonb(v_bet), 'team', to_jsonb(v_team));
end;
$$;

create or replace function public.admin_lock_bets(p_event_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_round public.rounds%rowtype;
begin
  perform app_private.require_event_member(p_event_id, true);
  select r.* into v_round from public.rounds r
  where r.event_id = p_event_id order by r.round_number desc limit 1 for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'NO_ACTIVE_ROUND';
  end if;
  if v_round.status = 'locked' then
    return to_jsonb(v_round);
  end if;
  if v_round.status <> 'betting' then
    raise exception using errcode = 'P0001', message = 'INVALID_STATE';
  end if;
  update public.rounds r set status = 'locked',
    locked_at = pg_catalog.clock_timestamp()
  where r.id = v_round.id returning * into v_round;
  return to_jsonb(v_round);
end;
$$;

create or replace function public.admin_spin_round(p_event_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_round public.rounds%rowtype;
begin
  perform app_private.require_event_member(p_event_id, true);
  select r.* into v_round from public.rounds r
  where r.event_id = p_event_id order by r.round_number desc limit 1 for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'NO_ACTIVE_ROUND';
  end if;
  if v_round.status = 'spinning' or v_round.status = 'result' then
    return to_jsonb(v_round);
  end if;
  if v_round.status <> 'locked' then
    raise exception using errcode = 'P0001', message = 'INVALID_STATE';
  end if;
  update public.rounds r set status = 'spinning',
    spun_at = pg_catalog.clock_timestamp()
  where r.id = v_round.id returning * into v_round;
  return to_jsonb(v_round);
end;
$$;

create or replace function public.admin_adjust_team_balance(
  p_event_id uuid,
  p_team_id uuid,
  p_delta bigint,
  p_reason text,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_team public.teams%rowtype;
  v_prior public.team_ledger%rowtype;
begin
  perform app_private.require_event_member(p_event_id, true);
  if p_delta is null or p_delta = 0 or p_request_id is null
    or pg_catalog.length(pg_catalog.btrim(coalesce(p_reason, ''))) = 0 then
    raise exception using errcode = 'P0001', message = 'INVALID_REQUEST';
  end if;
  select t.* into v_team from public.teams t
  where t.id = p_team_id and t.event_id = p_event_id for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'TEAM_NOT_FOUND';
  end if;
  select l.* into v_prior from public.team_ledger l
  where l.team_id = p_team_id and l.request_id = p_request_id;
  if found then
    if v_prior.entry_type <> 'admin_adjustment' or v_prior.amount_delta <> p_delta then
      raise exception using errcode = 'P0001', message = 'DUPLICATE_REQUEST';
    end if;
    return jsonb_build_object('replayed', true, 'team', to_jsonb(v_team), 'ledger', to_jsonb(v_prior));
  end if;
  if v_team.balance + p_delta < 0 then
    raise exception using errcode = 'P0001', message = 'INSUFFICIENT_FUNDS';
  end if;
  update public.teams t set balance = t.balance + p_delta
  where t.id = p_team_id returning * into v_team;
  insert into public.team_ledger(event_id, team_id, entry_type, amount_delta,
    balance_after, request_id, created_by, reason)
  values(p_event_id, p_team_id, 'admin_adjustment', p_delta, v_team.balance,
    p_request_id, auth.uid(), pg_catalog.btrim(p_reason)) returning * into v_prior;
  return jsonb_build_object('replayed', false, 'team', to_jsonb(v_team), 'ledger', to_jsonb(v_prior));
end;
$$;

create or replace function public.get_game_snapshot(p_event_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_team_id uuid;
  v_snapshot jsonb;
begin
  v_team_id := app_private.require_event_member(p_event_id, false);
  select jsonb_build_object(
    'event', to_jsonb(e),
    'round', (select to_jsonb(r) from public.rounds r
      where r.event_id = p_event_id order by r.round_number desc limit 1),
    'teams', coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at, t.id)
      from public.teams t where t.event_id = p_event_id), '[]'::jsonb),
    'bets', coalesce((select jsonb_agg(to_jsonb(b) order by b.team_id, b.bet_type, b.numbers)
      from public.bets b join public.rounds r on r.id = b.round_id
      where b.event_id = p_event_id and r.round_number =
        (select max(r2.round_number) from public.rounds r2 where r2.event_id = p_event_id)
        and b.amount > 0), '[]'::jsonb),
    'team_id', v_team_id
  ) into v_snapshot
  from public.events e where e.id = p_event_id;
  return v_snapshot;
end;
$$;

create or replace function public.system_advance_rounds()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_round public.rounds%rowtype;
  v_bet public.bets%rowtype;
  v_team public.teams%rowtype;
  v_result integer;
  v_payout bigint;
  v_locked integer := 0;
  v_spinning integer := 0;
  v_finished integer := 0;
begin
  if not pg_catalog.pg_try_advisory_xact_lock(8242, 1536) then
    return jsonb_build_object('skipped', true);
  end if;

  for v_round in
    select r.* from public.rounds r
    where r.status = 'betting' and r.betting_deadline <= pg_catalog.clock_timestamp()
    order by r.betting_deadline for update skip locked
  loop
    update public.rounds r set status = 'locked',
      locked_at = pg_catalog.clock_timestamp() where r.id = v_round.id;
    v_locked := v_locked + 1;
  end loop;

  for v_round in
    select r.* from public.rounds r
    where r.status = 'locked'
      and r.locked_at <= pg_catalog.clock_timestamp() - interval '1 second'
    order by r.locked_at for update skip locked
  loop
    update public.rounds r set status = 'spinning',
      spun_at = pg_catalog.clock_timestamp() where r.id = v_round.id;
    v_spinning := v_spinning + 1;
  end loop;

  for v_round in
    select r.* from public.rounds r
    where r.status = 'spinning'
      and r.spun_at <= pg_catalog.clock_timestamp() - interval '3 seconds'
    order by r.spun_at for update skip locked
  loop
    v_result := floor(pg_catalog.random() * 36)::integer + 1;
    for v_bet in
      select b.* from public.bets b
      where b.round_id = v_round.id and b.amount > 0
      order by b.team_id, b.id for update
    loop
      v_payout := app_private.gross_payout(v_bet.bet_type,
        v_bet.numbers, v_bet.amount, v_result);
      if v_payout > 0 then
        update public.teams t set balance = t.balance + v_payout
        where t.id = v_bet.team_id and t.event_id = v_bet.event_id
        returning * into v_team;
        if not found then
          raise exception using errcode = 'P0001', message = 'TEAM_NOT_FOUND';
        end if;
        insert into public.team_ledger(event_id, team_id, round_id, bet_id,
          entry_type, amount_delta, balance_after, request_id)
        values(v_bet.event_id, v_bet.team_id, v_round.id, v_bet.id,
          'payout', v_payout, v_team.balance, pg_catalog.gen_random_uuid());
      end if;
    end loop;
    update public.rounds r set status = 'result', winning_number = v_result,
      settled_at = pg_catalog.clock_timestamp() where r.id = v_round.id;
    v_finished := v_finished + 1;
  end loop;
  return jsonb_build_object('locked', v_locked, 'spinning', v_spinning, 'finished', v_finished);
end;
$$;

-- Authenticated clients may call only member/admin operations. The scheduler
-- calls system_advance_rounds with a server-held service-role credential.
revoke all on function public.admin_prepare_round(uuid) from public, anon;
revoke all on function public.admin_start_betting(uuid) from public, anon;
revoke all on function public.member_change_bet(uuid,text,integer[],bigint,uuid) from public, anon;
revoke all on function public.admin_lock_bets(uuid) from public, anon;
revoke all on function public.admin_spin_round(uuid) from public, anon;
revoke all on function public.admin_adjust_team_balance(uuid,uuid,bigint,text,uuid) from public, anon;
revoke all on function public.get_game_snapshot(uuid) from public, anon;
revoke all on function public.system_advance_rounds() from public, anon, authenticated;

grant execute on function public.admin_prepare_round(uuid) to authenticated;
grant execute on function public.admin_start_betting(uuid) to authenticated;
grant execute on function public.member_change_bet(uuid,text,integer[],bigint,uuid) to authenticated;
grant execute on function public.admin_lock_bets(uuid) to authenticated;
grant execute on function public.admin_spin_round(uuid) to authenticated;
grant execute on function public.admin_adjust_team_balance(uuid,uuid,bigint,text,uuid) to authenticated;
grant execute on function public.get_game_snapshot(uuid) to authenticated;
grant execute on function public.system_advance_rounds() to service_role;

revoke all on function app_private.require_event_member(uuid,boolean) from public, anon, authenticated;
revoke all on function app_private.valid_roulette_bet(text,integer[]) from public, anon, authenticated;
revoke all on function app_private.gross_payout(text,integer[],bigint,integer) from public, anon, authenticated;

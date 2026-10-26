-- Allow the advertised chip tray while keeping every chip change
-- transactional and limited to fixed, server-approved denominations.
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

  if p_delta = 0
    or p_delta = '-9223372036854775808'::bigint
    or (p_delta > 0 and p_delta not in (1, 5, 25, 100, 500, 1000)) then
    raise exception using errcode = 'P0001', message = 'INVALID_DELTA';
  end if;
  if not exists (
    select 1 from public.events e where e.id = p_event_id and e.active
  ) then
    raise exception using errcode = 'P0001', message = 'EVENT_NOT_ACTIVE';
  end if;
  v_ledger_type := case when p_delta > 0 then 'wager' else 'bet_refund' end;
  v_ledger_delta := -p_delta;

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

revoke all on function public.member_change_bet(uuid,text,integer[],bigint,uuid) from public, anon;
grant execute on function public.member_change_bet(uuid,text,integer[],bigint,uuid) to authenticated;

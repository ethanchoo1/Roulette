-- Admin team cleanup, exact bankroll setting, round-label reset, and team cap.

alter table public.events
  add column next_round_number integer not null default 1
    check (next_round_number > 0);

alter table public.rounds
  add column display_round_number integer not null default 1
    check (display_round_number > 0);

update public.rounds
set display_round_number = round_number;

update public.events e
set next_round_number = coalesce((
  select max(r.round_number) + 1
  from public.rounds r
  where r.event_id = e.id
), 1);

create or replace function app_private.enforce_event_team_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event_id uuid;
begin
  select e.id into v_event_id
  from public.events e
  where e.id = new.event_id
  for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'EVENT_NOT_FOUND';
  end if;

  if (select count(*) from public.teams t where t.event_id = new.event_id) >= 4 then
    raise exception using errcode = 'P0001', message = 'TEAM_LIMIT_REACHED';
  end if;
  return new;
end;
$$;

revoke all on function app_private.enforce_event_team_limit() from public, anon, authenticated;

create trigger teams_enforce_event_team_limit
before insert on public.teams
for each row execute function app_private.enforce_event_team_limit();

create or replace function public.admin_prepare_round(p_event_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_round public.rounds%rowtype;
  v_next integer;
  v_display integer;
begin
  perform app_private.require_event_member(p_event_id, true);
  select e.next_round_number into v_display
  from public.events e where e.id = p_event_id and e.active for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'EVENT_NOT_ACTIVE';
  end if;
  if exists (select 1 from public.rounds r where r.event_id = p_event_id
      and r.status <> 'result') then
    raise exception using errcode = 'P0001', message = 'INVALID_STATE';
  end if;
  select coalesce(max(r.round_number), 0) + 1 into v_next
  from public.rounds r where r.event_id = p_event_id;
  insert into public.rounds(event_id, round_number, display_round_number, status)
  values (p_event_id, v_next, v_display, 'waiting') returning * into v_round;
  update public.events set next_round_number = v_display + 1
  where id = p_event_id;
  return to_jsonb(v_round);
end;
$$;

create or replace function public.admin_reset_round_counter(p_event_id uuid)
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

  if exists (select 1 from public.rounds r
      where r.event_id = p_event_id and r.status in ('betting', 'locked', 'spinning')) then
    raise exception using errcode = 'P0001', message = 'ROUND_IN_PROGRESS';
  end if;

  select r.* into v_round from public.rounds r
  where r.event_id = p_event_id order by r.round_number desc limit 1 for update;
  if found and v_round.status = 'waiting' then
    update public.rounds set display_round_number = 1 where id = v_round.id
    returning * into v_round;
  else
    select coalesce(max(r.round_number), 0) + 1 into v_next
    from public.rounds r where r.event_id = p_event_id;
    insert into public.rounds(event_id, round_number, display_round_number, status)
    values (p_event_id, v_next, 1, 'waiting') returning * into v_round;
  end if;
  update public.events set next_round_number = 2 where id = p_event_id;
  return to_jsonb(v_round);
end;
$$;

create or replace function public.admin_set_team_balance(
  p_event_id uuid,
  p_team_id uuid,
  p_balance bigint,
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
  v_round public.rounds%rowtype;
  v_prior public.team_ledger%rowtype;
  v_delta bigint;
  v_reason text := pg_catalog.btrim(coalesce(p_reason, ''));
begin
  perform app_private.require_event_member(p_event_id, true);
  perform 1 from public.events e where e.id = p_event_id and e.active for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'EVENT_NOT_ACTIVE';
  end if;
  select r.* into v_round from public.rounds r
  where r.event_id = p_event_id order by r.round_number desc limit 1 for update;
  if found and v_round.status in ('betting', 'locked', 'spinning') then
    raise exception using errcode = 'P0001', message = 'ROUND_IN_PROGRESS';
  end if;

  if p_team_id is null or p_balance is null or p_balance < 0
    or p_request_id is null or v_reason = '' then
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
    if v_prior.entry_type <> 'admin_adjustment'
      or v_prior.balance_after <> p_balance or v_prior.reason <> v_reason then
      raise exception using errcode = 'P0001', message = 'DUPLICATE_REQUEST';
    end if;
    return jsonb_build_object('replayed', true, 'team', to_jsonb(v_team), 'ledger', to_jsonb(v_prior));
  end if;

  v_delta := p_balance - v_team.balance;
  if v_delta = 0 then
    return jsonb_build_object('replayed', false, 'team', to_jsonb(v_team), 'ledger', null);
  end if;

  update public.teams set balance = p_balance
  where id = p_team_id returning * into v_team;
  insert into public.team_ledger(event_id, team_id, entry_type, amount_delta,
    balance_after, request_id, created_by, reason)
  values(p_event_id, p_team_id, 'admin_adjustment', v_delta, v_team.balance,
    p_request_id, auth.uid(), v_reason) returning * into v_prior;
  return jsonb_build_object('replayed', false, 'team', to_jsonb(v_team), 'ledger', to_jsonb(v_prior));
end;
$$;

create or replace function public.admin_delete_team(p_event_id uuid, p_team_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_team public.teams%rowtype;
  v_round public.rounds%rowtype;
begin
  perform app_private.require_event_member(p_event_id, true);
  perform 1 from public.events e where e.id = p_event_id and e.active for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'EVENT_NOT_ACTIVE';
  end if;
  select r.* into v_round from public.rounds r
  where r.event_id = p_event_id order by r.round_number desc limit 1 for update;
  if found and v_round.status in ('betting', 'locked', 'spinning') then
    raise exception using errcode = 'P0001', message = 'ROUND_IN_PROGRESS';
  end if;
  select t.* into v_team from public.teams t
  where t.id = p_team_id and t.event_id = p_event_id for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'TEAM_NOT_FOUND';
  end if;
  if exists (select 1 from public.event_members m
      where m.event_id = p_event_id and m.team_id = p_team_id and m.role = 'admin') then
    raise exception using errcode = 'P0001', message = 'TEAM_HAS_ADMIN';
  end if;

  -- Membership rows, bets, ledger entries, and activity for this team are removed.
  delete from public.event_members m
  where m.event_id = p_event_id and m.team_id = p_team_id;
  delete from public.teams t where t.id = p_team_id and t.event_id = p_event_id;
  return jsonb_build_object('team_id', v_team.id, 'team_name', v_team.name);
end;
$$;

revoke all on function public.admin_prepare_round(uuid) from public, anon;
revoke all on function public.admin_reset_round_counter(uuid) from public, anon;
revoke all on function public.admin_set_team_balance(uuid,uuid,bigint,text,uuid) from public, anon;
revoke all on function public.admin_delete_team(uuid,uuid) from public, anon;
grant execute on function public.admin_prepare_round(uuid) to authenticated;
grant execute on function public.admin_reset_round_counter(uuid) to authenticated;
grant execute on function public.admin_set_team_balance(uuid,uuid,bigint,text,uuid) to authenticated;
grant execute on function public.admin_delete_team(uuid,uuid) to authenticated;

-- Keep activity labels stable when the display counter is reset.
create or replace function public.get_game_snapshot(p_event_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_team_id uuid;
  v_role text;
  v_snapshot jsonb;
begin
  v_team_id := app_private.require_event_member(p_event_id, false);
  select m.role into v_role
  from public.event_members m
  where m.event_id = p_event_id and m.user_id = auth.uid();

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
    'team_id', v_team_id,
    'members', case when v_role = 'admin' then coalesce((
      select jsonb_agg(jsonb_build_object(
        'user_id', m.user_id,
        'team_id', m.team_id,
        'display_name', m.display_name,
        'joined_at', m.joined_at
      ) order by m.joined_at, m.user_id)
      from public.event_members m
      where m.event_id = p_event_id and m.role = 'player'
    ), '[]'::jsonb) else '[]'::jsonb end,
    'activity', coalesce((
      select jsonb_agg(to_jsonb(activity_row) order by activity_row.created_at desc)
      from (
        select * from (
          select m.display_name as actor,
            'joined'::text as action,
            t.name as team_name,
            null::text as bet_type,
            null::integer[] as numbers,
            null::bigint as amount_delta,
            null::integer as round_number,
            m.joined_at as created_at,
            null::text as reason,
            ('join:' || m.user_id::text) as activity_id
          from public.event_members m
          join public.teams t on t.id = m.team_id
          where m.event_id = p_event_id and m.role = 'player'

          union all

          select coalesce(member.display_name,
              case when l.entry_type = 'payout' then 'Roulette' else 'Player' end) as actor,
            l.entry_type as action,
            t.name as team_name,
            b.bet_type,
            b.numbers,
            l.amount_delta,
            r.display_round_number as round_number,
            l.created_at,
            l.reason,
            ('ledger:' || l.id::text) as activity_id
          from public.team_ledger l
          join public.teams t on t.id = l.team_id
          left join public.event_members member
            on member.event_id = l.event_id and member.user_id = l.created_by
          left join public.bets b on b.id = l.bet_id
          left join public.rounds r on r.id = l.round_id
          where l.event_id = p_event_id
            and l.entry_type in ('wager', 'bet_refund', 'payout', 'admin_adjustment')
        ) activity_union
        order by activity_union.created_at desc
        limit 8
      ) activity_row
    ), '[]'::jsonb)
  ) into v_snapshot
  from public.events e where e.id = p_event_id;
  return v_snapshot;
end;
$$;

revoke all on function public.get_game_snapshot(uuid) from public, anon;
grant execute on function public.get_game_snapshot(uuid) to authenticated;

-- Guest entry, team creation/joining, and admin removal.
-- Anonymous users are authenticated Supabase users; their browser session is
-- persisted by the Supabase JS client so a normal refresh keeps the same ID.

alter table public.events
  add column join_code uuid not null default gen_random_uuid(),
  add column join_open boolean not null default true,
  add column starting_balance bigint not null default 1000
    check (starting_balance >= 0);

create unique index events_join_code_idx on public.events(join_code);

alter table public.event_members
  add column display_name text not null default 'Host'
    check (length(btrim(display_name)) between 1 and 32);

create unique index teams_event_lower_name_idx
  on public.teams(event_id, lower(name));

create or replace function public.get_join_options(p_join_code uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event public.events%rowtype;
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception using errcode = 'P0001', message = 'UNAUTHENTICATED';
  end if;
  select e.* into v_event from public.events e
  where e.join_code = p_join_code and e.active and e.join_open;
  if not found then
    raise exception using errcode = 'P0001', message = 'JOIN_CLOSED_OR_INVALID';
  end if;

  select jsonb_build_object(
    'event_id', v_event.id,
    'event_name', v_event.name,
    'chip_value', v_event.chip_value,
    'teams', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', t.id,
        'name', t.name,
        'players', (select count(*) from public.event_members m
          where m.event_id = t.event_id and m.team_id = t.id and m.role = 'player')
      ) order by t.created_at, t.id)
      from public.teams t where t.event_id = v_event.id
    ), '[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;

create or replace function public.join_event(
  p_join_code uuid,
  p_display_name text,
  p_team_id uuid default null,
  p_new_team_name text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event public.events%rowtype;
  v_team public.teams%rowtype;
  v_member public.event_members%rowtype;
  v_name text := pg_catalog.btrim(coalesce(p_display_name, ''));
  v_team_name text := pg_catalog.btrim(coalesce(p_new_team_name, ''));
  v_request_id uuid;
begin
  if auth.uid() is null then
    raise exception using errcode = 'P0001', message = 'UNAUTHENTICATED';
  end if;
  if pg_catalog.length(v_name) not between 1 and 32 then
    raise exception using errcode = 'P0001', message = 'INVALID_DISPLAY_NAME';
  end if;
  if (p_team_id is null) = (pg_catalog.length(v_team_name) = 0) then
    raise exception using errcode = 'P0001', message = 'CHOOSE_OR_CREATE_TEAM';
  end if;
  if pg_catalog.length(v_team_name) > 32 then
    raise exception using errcode = 'P0001', message = 'INVALID_TEAM_NAME';
  end if;

  -- Serialize entry/team creation for this event. Recheck membership after the
  -- lock so a retry or two tabs cannot create two memberships/teams.
  select e.* into v_event from public.events e
  where e.join_code = p_join_code and e.active and e.join_open
  for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'JOIN_CLOSED_OR_INVALID';
  end if;

  select m.* into v_member from public.event_members m
  where m.event_id = v_event.id and m.user_id = auth.uid();
  if found then
    if v_member.team_id is null then
      raise exception using errcode = 'P0001', message = 'ADMIN_MEMBERSHIP_EXISTS';
    end if;
    select t.* into v_team from public.teams t where t.id = v_member.team_id;
    return jsonb_build_object('replayed', true,
      'event_id', v_event.id, 'display_name', v_member.display_name,
      'role', v_member.role, 'team', to_jsonb(v_team));
  end if;

  if p_team_id is not null then
    select t.* into v_team from public.teams t
    where t.id = p_team_id and t.event_id = v_event.id for update;
    if not found then
      raise exception using errcode = 'P0001', message = 'TEAM_NOT_FOUND';
    end if;
  else
    insert into public.teams(event_id, name, balance)
    values(v_event.id, v_team_name, v_event.starting_balance)
    returning * into v_team;

    if v_team.balance > 0 then
      v_request_id := pg_catalog.gen_random_uuid();
      insert into public.team_ledger(event_id, team_id, entry_type,
        amount_delta, balance_after, request_id, created_by, reason)
      values(v_event.id, v_team.id, 'starting_funds', v_team.balance,
        v_team.balance, v_request_id, auth.uid(), 'Initial team bankroll');
    end if;
  end if;

  insert into public.event_members(event_id, user_id, role, team_id, display_name)
  values(v_event.id, auth.uid(), 'player', v_team.id, v_name)
  returning * into v_member;

  return jsonb_build_object('replayed', false,
    'event_id', v_event.id, 'display_name', v_member.display_name,
    'role', v_member.role, 'team', to_jsonb(v_team));
exception
  when unique_violation then
    -- Includes a duplicate case-insensitive team name or a concurrent attempt.
    raise exception using errcode = 'P0001', message = 'NAME_ALREADY_IN_USE';
end;
$$;

create or replace function public.admin_kick_member(
  p_event_id uuid,
  p_user_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin_team uuid;
  v_member public.event_members%rowtype;
begin
  v_admin_team := app_private.require_event_member(p_event_id, true);
  if p_user_id is null or p_user_id = auth.uid() then
    raise exception using errcode = 'P0001', message = 'INVALID_KICK_TARGET';
  end if;

  select m.* into v_member from public.event_members m
  where m.event_id = p_event_id and m.user_id = p_user_id for update;
  if not found or v_member.role <> 'player' then
    raise exception using errcode = 'P0001', message = 'PLAYER_NOT_FOUND';
  end if;

  delete from public.event_members m
  where m.event_id = p_event_id and m.user_id = p_user_id;
  -- Bets and bankroll belong to the team, so removing a player leaves them intact.
  return jsonb_build_object('removed_user_id', p_user_id,
    'team_id', v_member.team_id, 'display_name', v_member.display_name);
end;
$$;

revoke all on function public.get_join_options(uuid) from public, anon;
revoke all on function public.join_event(uuid,text,uuid,text) from public, anon;
revoke all on function public.admin_kick_member(uuid,uuid) from public, anon;
grant execute on function public.get_join_options(uuid) to authenticated;
grant execute on function public.join_event(uuid,text,uuid,text) to authenticated;
grant execute on function public.admin_kick_member(uuid,uuid) to authenticated;

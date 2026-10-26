-- Expose the event roster to admins through the existing snapshot RPC.
-- Regular players receive an empty member list and cannot inspect other users.
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
    ), '[]'::jsonb) else '[]'::jsonb end
  ) into v_snapshot
  from public.events e where e.id = p_event_id;
  return v_snapshot;
end;
$$;

revoke all on function public.get_game_snapshot(uuid) from public, anon;
grant execute on function public.get_game_snapshot(uuid) to authenticated;

-- Return recent joins and bankroll/bet events in the shared game snapshot.
-- Roster details remain admin-only; activity is visible to event members.
create index if not exists team_ledger_event_created_idx
  on public.team_ledger (event_id, created_at desc);

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
          r.round_number,
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

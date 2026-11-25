-- Keep the tied main-vote score private until results are published.
create or replace function private.get_runoff(p_runoff_id uuid) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  actor public.members := private.current_member();
  round private.vote_runoffs;
  result jsonb;
  tally jsonb := '[]';
begin
  if actor.id is null then raise exception '행사 명단에 등록된 계정이 필요합니다.' using errcode = '42501'; end if;
  select * into round from private.vote_runoffs where id = p_runoff_id;
  if not found then return null; end if;
  if round.closed_at is not null and (actor.role in ('owner', 'staff') or
    exists (select 1 from public.event_settings where id and vote_status = 'published')) then
    select coalesce(jsonb_agg(to_jsonb(t) order by t.raw_rank, t.name, t.team_id), '[]') into tally
      from private.runoff_tally(round.id) t;
  end if;
  select jsonb_build_object(
    'id', round.id, 'status', case when round.closed_at is not null then 'closed'
      when round.closes_at <= clock_timestamp() then 'expired' else 'open' end,
    'opens_at', round.opens_at, 'closes_at', least(round.closes_at, round.closed_at),
    'main_vote_count', case when actor.role in ('owner', 'staff') or
      exists (select 1 from public.event_settings where id and vote_status = 'published') then round.main_vote_count end,
    'eligible', actor.role = 'participant' and exists (select 1 from private.runoff_eligibility where runoff_id = round.id and member_id = actor.id),
    'voted', actor.role = 'participant' and exists (select 1 from private.runoff_votes where runoff_id = round.id and member_id = actor.id),
    'eligible_count', case when actor.role in ('owner', 'staff') then (select count(*) from private.runoff_eligibility where runoff_id = round.id) end,
    'voted_count', case when actor.role in ('owner', 'staff') then (select count(*) from private.runoff_votes where runoff_id = round.id) end,
    'choice_id', case when actor.role = 'participant' then (select team_id from private.runoff_votes where runoff_id = round.id and member_id = actor.id) end,
    'candidates', (select jsonb_agg(jsonb_build_object('id', c.team_id, 'name', c.name, 'presentation_order', c.presentation_order)
      order by c.presentation_order nulls last, c.name, c.team_id) from private.runoff_candidates rc
      join private.vote_candidates c on c.team_id = rc.team_id where rc.runoff_id = round.id),
    'results', tally
  ) into result;
  return result;
end;
$$;

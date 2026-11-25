-- Gemini evidence gives a team one point. Original ballots and vote_count stay unchanged.
create table private.team_bonus (
  team_id uuid primary key references public.teams(id),
  gemini_qualified boolean not null,
  note text check (char_length(note) between 1 and 500),
  approved_by uuid not null references public.members(id),
  approved_at timestamptz not null,
  check (not gemini_qualified or note is not null)
);
alter table private.team_bonus enable row level security;
revoke all on private.team_bonus from public, anon, authenticated, service_role;

create function private.get_gemini_bonuses() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_owner();
  return jsonb_build_object(
    'locked', exists(select 1 from private.vote_runoffs) or exists(select 1 from public.event_settings where id and vote_status='published'),
    'teams', coalesce((select jsonb_agg(jsonb_build_object('team_id', t.id, 'name', t.name,
      'approved', coalesce(b.gemini_qualified,false), 'note', b.note,
      'decided_by_name', m.name, 'decided_at', b.approved_at) order by t.presentation_order nulls last, t.name, t.id)
      from public.teams t left join private.team_bonus b on b.team_id=t.id
      left join public.members m on m.id=b.approved_by), '[]'::jsonb)
  );
end;
$$;

create function private.set_gemini_bonus(p_team_id uuid, p_approved boolean, p_note text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor_id uuid;
  event public.event_settings;
  previous private.team_bonus;
  saved private.team_bonus;
  clean_note text := nullif(btrim(p_note),'');
begin
  perform private.require_owner();
  select * into strict event from public.event_settings where id for update;
  actor_id := private.require_owner();
  if event.vote_status='published' or exists(select 1 from private.vote_runoffs) then
    raise exception '첫 재투표를 시작했거나 결과를 공개한 뒤에는 가산점을 변경할 수 없습니다.' using errcode='22023';
  end if;
  if p_approved is null or char_length(clean_note)>500
    or (p_approved and (clean_note is null or clean_note !~ '[^[:space:]]')) then
    raise exception 'Gemini 결과물 확인 근거를 1~500자로 입력해 주세요.' using errcode='22023';
  end if;
  if p_team_id is null or not exists(select 1 from public.teams where id=p_team_id) then
    raise exception '가산점을 설정할 팀을 확인해 주세요.' using errcode='22023';
  end if;
  select * into previous from private.team_bonus where team_id=p_team_id;
  if coalesce(previous.gemini_qualified,false)=p_approved and previous.note is not distinct from clean_note then return; end if;
  insert into private.team_bonus(team_id,gemini_qualified,note,approved_by,approved_at)
    values(p_team_id,p_approved,clean_note,actor_id,clock_timestamp())
    on conflict(team_id) do update set gemini_qualified=excluded.gemini_qualified,note=excluded.note,
      approved_by=excluded.approved_by,approved_at=excluded.approved_at returning * into saved;
  insert into public.audit_logs(actor_id,action,target_id,details) values(actor_id,'gemini_bonus_changed',p_team_id,
    jsonb_build_object('before',case when previous.team_id is not null then to_jsonb(previous) end,'after',to_jsonb(saved)));
end;
$$;

create function public.get_gemini_bonuses() returns jsonb
language sql stable security invoker set search_path='' as $$ select private.get_gemini_bonuses(); $$;
create function public.set_gemini_bonus(p_team_id uuid,p_approved boolean,p_note text) returns void
language sql security invoker set search_path='' as $$ select private.set_gemini_bonus(p_team_id,p_approved,p_note); $$;

-- Keep the legacy raw count for existing records/API consumers. A new mixed-raw
-- score tie has no single raw count, so that field is null rather than fabricated.
alter table private.vote_runoffs add column main_score integer;
update private.vote_runoffs set main_score=main_vote_count;
alter table private.vote_runoffs alter column main_score set not null;
alter table private.vote_runoffs add constraint vote_runoffs_main_score_key unique(main_score);
alter table private.vote_runoffs add constraint vote_runoffs_main_score_check check(main_score>=0);
alter table private.vote_runoffs drop constraint vote_runoffs_main_vote_count_key;
alter table private.vote_runoffs alter column main_vote_count drop not null;

create function private.main_score_tally()
returns table(team_id uuid,name text,vote_count integer,gemini_bonus integer,total_score integer,raw_rank integer,tied_count integer)
language sql stable set search_path='' as $$
  with scores as (
    select m.team_id,m.name,m.vote_count,case when b.gemini_qualified then 1 else 0 end as gemini_bonus,
      m.vote_count+case when b.gemini_qualified then 1 else 0 end as total_score
    from private.main_vote_tally() m left join private.team_bonus b on b.team_id=m.team_id
  ) select s.team_id,s.name,s.vote_count,s.gemini_bonus,s.total_score,
    rank() over(order by s.total_score desc)::integer,count(*) over(partition by s.total_score)::integer from scores s;
$$;

-- Preserve the existing return signature used by the main publish validator.
create or replace function private.vote_tally()
returns table(team_id uuid,name text,vote_count integer,raw_rank integer,tied_count integer)
language sql stable set search_path='' as $$
  with scores as (
    select m.*,coalesce(r.vote_count,0) as runoff_count from private.main_score_tally() m
    left join private.vote_runoffs vr on vr.main_score=m.total_score and vr.closed_at is not null
    left join lateral private.runoff_tally(vr.id) r on r.team_id=m.team_id
  ) select s.team_id,s.name,s.vote_count,
    rank() over(order by s.total_score desc,s.runoff_count desc)::integer,
    count(*) over(partition by s.total_score,s.runoff_count)::integer from scores s;
$$;

revoke all on function private.main_score_tally(),private.get_gemini_bonuses(),private.set_gemini_bonus(uuid,boolean,text),
  public.get_gemini_bonuses(),public.set_gemini_bonus(uuid,boolean,text) from public,anon,authenticated,service_role;
grant execute on function private.get_gemini_bonuses(),private.set_gemini_bonus(uuid,boolean,text),
  public.get_gemini_bonuses(),public.set_gemini_bonus(uuid,boolean,text) to authenticated;

create or replace function private.manage_runoff(p_action text, p_candidate_ids uuid[], p_closes_at timestamptz, p_runoff_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  actor public.members := private.current_member();
  event public.event_settings;
  round private.vote_runoffs;
  action_at timestamptz;
  score integer;
  common_vote_count integer;
  tied integer;
begin
  perform private.require_vote_manager();
  select * into strict event from public.event_settings where id for update;
  actor := private.current_member();
  perform private.require_vote_manager();
  action_at := clock_timestamp();
  if event.vote_status <> 'closed' then
    raise exception '본투표 마감을 확정한 뒤, 결과 공개 전에만 재투표를 진행할 수 있습니다.' using errcode = '22023';
  end if;
  case p_action
    when 'start' then
      if exists (select 1 from private.vote_runoffs where closed_at is null) then
        raise exception '진행 중인 재투표의 마감을 먼저 확정해 주세요.' using errcode = '22023';
      end if;
      if p_closes_at is null or not isfinite(p_closes_at) or p_closes_at <= action_at then
        raise exception '현재 시각 이후의 재투표 마감을 입력해 주세요.' using errcode = '22023';
      end if;
      if coalesce(cardinality(p_candidate_ids), 0) not between 2 and 200 then
        raise exception '동점 팀을 2개 이상 선택해 주세요.' using errcode = '22023';
      end if;
      select total_score, tied_count into score, tied from private.main_score_tally() where team_id = p_candidate_ids[1];
      if score is null or tied <> cardinality(p_candidate_ids) or
        (select count(*) from private.main_score_tally() where total_score = score and team_id = any(p_candidate_ids)) <> tied then
        raise exception '본투표 원득표와 Gemini 가산점 합계가 같은 동점 팀 전체를 선택해 주세요.' using errcode = '22023';
      end if;
      if exists (select 1 from private.vote_runoffs where main_score = score) then
        raise exception '이 동점 그룹은 이미 재투표했습니다. 다시 동점이면 사유를 적어 최종 순위를 정해 주세요.' using errcode = '22023';
      end if;
      select case when min(vote_count)=max(vote_count) then min(vote_count) end into common_vote_count
        from private.main_score_tally() where total_score=score;
      insert into private.vote_runoffs (main_vote_count, main_score, opens_at, closes_at, created_by)
        values (common_vote_count, score, action_at, p_closes_at, actor.id) returning * into round;
      insert into private.runoff_candidates (runoff_id, team_id) select round.id, unnest(p_candidate_ids);
      insert into private.runoff_eligibility (runoff_id, member_id)
        select round.id, member_id from private.vote_eligibility where not (team_id = any(p_candidate_ids));
      if not found then
        raise exception '후보팀 소속을 제외하면 유권자가 없습니다. 동점 결정 사유를 적어 순위를 정해 주세요.' using errcode = '22023';
      end if;
    when 'close' then
      select * into round from private.vote_runoffs where id = p_runoff_id;
      if not found or round.closed_at is not null then
        raise exception '진행 중인 재투표만 마감할 수 있습니다.' using errcode = '22023';
      end if;
      update private.vote_runoffs set closed_at = action_at where id = round.id;
    else raise exception '재투표 작업을 다시 선택해 주세요.' using errcode = '22023';
  end case;
  insert into public.audit_logs (actor_id, action, details) values (actor.id, 'runoff_' || p_action,
    jsonb_build_object('runoff_id', round.id, 'main_vote_count', round.main_vote_count, 'main_score', round.main_score, 'closes_at', round.closes_at));
end;
$$;

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
    'main_score', case when actor.role in ('owner', 'staff') or
      exists (select 1 from public.event_settings where id and vote_status = 'published') then round.main_score end,
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

create or replace function private.get_vote_details() returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare
  actor public.members := private.current_member();
  result jsonb := private.get_main_vote_details();
  runoff jsonb;
  groups jsonb := '[]';
  history jsonb := '[]';
  results jsonb := '[]';
begin
  select private.get_runoff(id) into runoff from private.vote_runoffs order by opens_at desc,id desc limit 1;
  if actor.role in ('owner','staff') and result->>'status'='closed' then
    select coalesce(jsonb_agg(to_jsonb(g) order by g.raw_rank),'[]') into groups from (
      select min(m.raw_rank) as raw_rank,m.total_score as main_score,
        case when min(m.vote_count)=max(m.vote_count) then min(m.vote_count) end as vote_count,
        exists(select 1 from private.vote_runoffs vr where vr.main_score=m.total_score) as completed,
        jsonb_agg(jsonb_build_object('id',m.team_id,'name',m.name,'presentation_order',c.presentation_order)
          order by c.presentation_order nulls last,m.name,m.team_id) as candidates
      from private.main_score_tally() m join private.vote_candidates c on c.team_id=m.team_id
      where m.tied_count>1 group by m.total_score
    ) g;
  end if;
  if result->>'status'='published' or (actor.role in ('owner','staff') and result->>'status'='closed') then
    select coalesce(jsonb_agg(private.get_runoff(id) order by opens_at,id),'[]') into history
      from private.vote_runoffs where closed_at is not null;
    select coalesce(jsonb_agg(value || jsonb_build_object('main_rank',m.raw_rank,'main_tied_count',m.tied_count,
      'gemini_bonus',m.gemini_bonus,'total_score',m.total_score,'runoff_vote_count',rt.vote_count)
      order by (value->>'raw_rank')::integer,value->>'name',value->>'team_id'),'[]') into results
      from jsonb_array_elements(result->'results') j
      join private.main_score_tally() m on m.team_id=(value->>'team_id')::uuid
      left join private.vote_runoffs vr on vr.main_score=m.total_score and vr.closed_at is not null
      left join lateral private.runoff_tally(vr.id) rt on rt.team_id=m.team_id;
  end if;
  return result || jsonb_build_object('runoff',runoff,'runoff_groups',groups,'runoff_history',history,'results',results);
end;
$$;

-- Keep the existing publish checks, using terminology that includes the bonus.
create or replace function private.manage_main_vote(p_action text, p_candidate_ids uuid[], p_awards jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor public.members := private.current_member();
  event public.event_settings;
  action_at timestamptz;
  award jsonb;
  ranking integer := 0;
  team uuid;
  label text;
  reason text;
  tally record;
begin
  perform private.require_vote_manager();
  select * into strict event from public.event_settings where id for update;
  actor := private.current_member();
  perform private.require_vote_manager();
  action_at := clock_timestamp();

  case p_action
    when 'open' then
      if event.vote_status <> 'draft' then raise exception '준비 상태에서만 투표를 열 수 있습니다.' using errcode = '22023'; end if;
      if event.vote_closes_at is null or not isfinite(event.vote_closes_at) or event.vote_closes_at <= action_at then
        raise exception '설정에서 현재 시각 이후의 투표 마감을 지정해 주세요.' using errcode = '22023';
      end if;
      if coalesce(cardinality(p_candidate_ids), 0) not between 2 and 200 or
        (select count(*) from public.teams where id = any(p_candidate_ids)) <> cardinality(p_candidate_ids) then
        raise exception '서로 다른 후보 팀을 2개 이상 선택해 주세요.' using errcode = '22023';
      end if;
      insert into private.vote_candidates (team_id, name, presentation_order)
        select id, name, presentation_order from public.teams where id = any(p_candidate_ids);
      insert into private.vote_eligibility (member_id, team_id)
        select id, team_id from public.members where role = 'participant' and active and team_id is not null;
      if not found then raise exception '팀이 배정된 활성 참가자가 필요합니다.' using errcode = '22023'; end if;
      update public.event_settings set vote_status = 'open', vote_opens_at = action_at where id;
    when 'close' then
      if event.vote_status <> 'open' or event.vote_opens_at is null or event.vote_opens_at > action_at then
        raise exception '진행 중인 투표만 마감할 수 있습니다.' using errcode = '22023';
      end if;
      update public.event_settings set vote_status = 'closed', vote_closed_at = action_at where id;
    when 'publish' then
      if event.vote_status <> 'closed' then raise exception '마감한 투표만 공개할 수 있습니다.' using errcode = '22023'; end if;
      if jsonb_typeof(p_awards) is distinct from 'array' then raise exception '수상 정보를 확인해 주세요.' using errcode = '22023'; end if;
      if jsonb_array_length(p_awards) not between 1 and (select count(*) from private.vote_candidates) then
        raise exception '수상 팀 수는 1개 이상, 후보 팀 수 이하여야 합니다.' using errcode = '22023';
      end if;
      for award in select value from jsonb_array_elements(p_awards) loop
        ranking := ranking + 1;
        team := (award->>'team_id')::uuid;
        label := btrim(award->>'award_name');
        reason := nullif(btrim(award->>'tie_reason'), '');
        if jsonb_typeof(award->'award_name') is distinct from 'string' or char_length(label) not between 1 and 80
          or coalesce(jsonb_typeof(award->'tie_reason'), 'null') not in ('null', 'string') or char_length(reason) > 500 then
          raise exception '수상명이나 동점 결정 사유를 확인해 주세요.' using errcode = '22023';
        end if;
        select * into tally from private.vote_tally() where team_id = team;
        if not found or ranking < tally.raw_rank or ranking >= tally.raw_rank + tally.tied_count then
          raise exception '수상 순위는 합계 점수와 재투표 결과를 따릅니다. 최종 동점 팀 안에서만 순서를 정해 주세요.' using errcode = '22023';
        end if;
        if tally.tied_count > 1 and reason is null then
          raise exception '동점인 팀의 수상 순위를 정한 사유를 입력해 주세요.' using errcode = '22023';
        end if;
        insert into private.award_decisions (final_rank, team_id, award_name, tie_reason, decided_by)
          values (ranking, team, label, case when tally.tied_count > 1 then reason end, actor.id);
      end loop;
      update public.event_settings set vote_status = 'published', vote_published_at = action_at where id;
    else
      raise exception '투표 작업을 다시 선택해 주세요.' using errcode = '22023';
  end case;

  insert into public.audit_logs (actor_id, action, details) values (actor.id, 'vote_' || p_action,
    case p_action when 'open' then jsonb_build_object('candidate_count', cardinality(p_candidate_ids))
      when 'publish' then jsonb_build_object('award_count', ranking) else '{}'::jsonb end);
exception
  when unique_violation then raise exception '같은 팀을 여러 수상 순위에 지정할 수 없습니다.' using errcode = '22023';
  when invalid_text_representation then raise exception '선택한 팀을 다시 확인해 주세요.' using errcode = '22023';
end;
$$;

-- A confirmed schedule freezes the same ballot as an immediate opening.
-- The stored status remains open; the database clock determines whether voting
-- has started. No cron job, client clock, or background write is required.
create function private.schedule_vote(p_opens_at timestamptz, p_candidate_ids uuid[]) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor public.members := private.current_member();
  event public.event_settings;
  action_at timestamptz;
begin
  if actor.id is null or actor.role <> 'owner' then
    raise exception '총관리자 권한이 필요합니다.' using errcode = '42501';
  end if;
  select * into strict event from public.event_settings where id for update;
  actor := private.current_member();
  if actor.id is null or actor.role <> 'owner' then
    raise exception '총관리자 권한이 필요합니다.' using errcode = '42501';
  end if;
  action_at := clock_timestamp();
  if event.vote_status <> 'draft' then
    raise exception '준비 상태에서만 투표를 예약할 수 있습니다.' using errcode = '22023';
  end if;
  if p_opens_at is null or not isfinite(p_opens_at) or p_opens_at <= action_at then
    raise exception '현재 시각 이후의 투표 시작 시각을 지정해 주세요.' using errcode = '22023';
  end if;
  if event.vote_closes_at is null or not isfinite(event.vote_closes_at) or p_opens_at >= event.vote_closes_at then
    raise exception '투표 시작은 설정된 투표 마감보다 빨라야 합니다.' using errcode = '22023';
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
  update public.event_settings set vote_status = 'open', vote_opens_at = p_opens_at where id;
  insert into public.audit_logs (actor_id, action, details) values (actor.id, 'vote_schedule',
    jsonb_build_object('opens_at', p_opens_at, 'candidate_count', cardinality(p_candidate_ids)));
end;
$$;

create function private.cancel_vote_schedule() returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor public.members := private.current_member();
  event public.event_settings;
begin
  if actor.id is null or actor.role <> 'owner' then
    raise exception '총관리자 권한이 필요합니다.' using errcode = '42501';
  end if;
  select * into strict event from public.event_settings where id for update;
  actor := private.current_member();
  if actor.id is null or actor.role <> 'owner' then
    raise exception '총관리자 권한이 필요합니다.' using errcode = '42501';
  end if;
  if event.vote_status <> 'open' or event.vote_opens_at is null
    or event.vote_opens_at <= clock_timestamp() then
    raise exception '시작 전인 투표 예약만 취소할 수 있습니다.' using errcode = '22023';
  end if;
  -- Legitimate schedules cannot have votes before opening. Preserve any ballot
  -- records if the database was changed outside these authorized RPCs.
  if exists (select 1 from private.votes) or exists (select 1 from private.award_decisions) then
    raise exception '이미 투표 기록이 있어 예약을 취소할 수 없습니다.' using errcode = '22023';
  end if;
  delete from private.vote_eligibility e
    where not exists (select 1 from private.votes v where v.member_id = e.member_id);
  delete from private.vote_candidates c
    where not exists (select 1 from private.votes v where v.team_id = c.team_id)
      and not exists (select 1 from private.award_decisions a where a.team_id = c.team_id);
  update public.event_settings set vote_status = 'draft', vote_opens_at = null where id;
  insert into public.audit_logs (actor_id, action, details) values (actor.id, 'vote_schedule_cancel',
    jsonb_build_object('opens_at', event.vote_opens_at));
end;
$$;

create or replace function private.get_vote_overview() returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  actor public.members := private.current_member();
  event public.event_settings;
  eligible_count integer;
  voted_count integer;
  observed_at timestamptz;
begin
  if actor.id is null then
    raise exception '행사 명단에 등록된 계정이 필요합니다.' using errcode = '42501';
  end if;
  select * into strict event from public.event_settings where id;
  observed_at := clock_timestamp();
  if actor.role in ('owner', 'staff') then
    if event.vote_status = 'draft' then
      select count(*) into eligible_count from public.members where active and role = 'participant' and team_id is not null;
      voted_count := 0;
    else
      select count(*) into eligible_count from private.vote_eligibility;
      select count(*) into voted_count from private.votes;
    end if;
  end if;
  return jsonb_build_object(
    'status', case
      when event.vote_status = 'open' and event.vote_opens_at > observed_at then 'scheduled'
      when event.vote_status = 'open' and event.vote_closes_at <= observed_at then 'expired'
      else event.vote_status end,
    'opens_at', event.vote_opens_at,
    'closes_at', least(event.vote_closes_at, event.vote_closed_at),
    'eligible', actor.role = 'participant' and exists (select 1 from private.vote_eligibility where member_id = actor.id),
    'voted', actor.role = 'participant' and exists (select 1 from private.votes where member_id = actor.id),
    'eligible_count', eligible_count, 'voted_count', voted_count
  );
end;
$$;

-- These reads can cross a start/deadline even within one SQL statement. Mark
-- every wrapper volatile as well, so PostgreSQL cannot cache a past phase.
alter function public.get_vote_overview() volatile;
alter function private.get_vote_details() volatile;
alter function public.get_vote_details() volatile;

create or replace function private.cast_vote(p_team_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor public.members := private.current_member();
  event public.event_settings;
  own_team_id uuid;
  action_at timestamptz;
begin
  if actor.id is null or actor.role <> 'participant' then
    raise exception '참가자에게만 투표권이 있습니다.' using errcode = '42501';
  end if;
  -- Roster edits, scheduling/cancellation, votes, and closing use the same lock.
  select * into strict event from public.event_settings where id for update;
  actor := private.current_member();
  if actor.id is null or actor.role <> 'participant' then
    raise exception '참가자에게만 투표권이 있습니다.' using errcode = '42501';
  end if;
  action_at := clock_timestamp();
  if event.vote_status <> 'open' or event.vote_opens_at is null or event.vote_closes_at is null
    or event.vote_opens_at > action_at or event.vote_closes_at <= action_at then
    raise exception '지금은 투표할 수 없습니다.' using errcode = '22023';
  end if;
  select team_id into own_team_id from private.vote_eligibility where member_id = actor.id;
  if not found then raise exception '이번 투표의 유권자 명단에 없습니다.' using errcode = '42501'; end if;
  if own_team_id = p_team_id then raise exception '자기 팀에는 투표할 수 없습니다.' using errcode = '22023'; end if;
  if not exists (select 1 from private.vote_candidates where team_id = p_team_id) then
    raise exception '투표 후보 팀을 다시 선택해 주세요.' using errcode = '22023';
  end if;

  insert into private.votes (member_id, own_team_id, team_id) values (actor.id, own_team_id, p_team_id)
  on conflict (member_id) do update set team_id = excluded.team_id, updated_at = clock_timestamp()
    where votes.team_id is distinct from excluded.team_id;
end;
$$;

create or replace function private.manage_vote(p_action text, p_candidate_ids uuid[], p_awards jsonb) returns void
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
  if actor.id is null or actor.role <> 'owner' then
    raise exception '총관리자 권한이 필요합니다.' using errcode = '42501';
  end if;
  select * into strict event from public.event_settings where id for update;
  actor := private.current_member();
  if actor.id is null or actor.role <> 'owner' then
    raise exception '총관리자 권한이 필요합니다.' using errcode = '42501';
  end if;
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
          raise exception '수상 순위는 득표순을 따릅니다. 동점 팀 안에서만 순서를 정해 주세요.' using errcode = '22023';
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

create function public.schedule_vote(p_opens_at timestamptz, p_candidate_ids uuid[]) returns void
language sql security invoker set search_path = '' as $$ select private.schedule_vote(p_opens_at, p_candidate_ids) $$;
create function public.cancel_vote_schedule() returns void
language sql security invoker set search_path = '' as $$ select private.cancel_vote_schedule() $$;

revoke all on function private.schedule_vote(timestamptz, uuid[]), private.cancel_vote_schedule(),
  public.schedule_vote(timestamptz, uuid[]), public.cancel_vote_schedule() from public, anon, authenticated, service_role;
grant execute on function private.schedule_vote(timestamptz, uuid[]), private.cancel_vote_schedule(),
  public.schedule_vote(timestamptz, uuid[]), public.cancel_vote_schedule() to authenticated;

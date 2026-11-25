-- One active staff member may operate voting; all other owner powers stay owner-only.
create table private.vote_delegation (
  id boolean primary key default true check (id),
  member_id uuid references public.members(id),
  updated_by uuid references public.members(id),
  updated_at timestamptz
);
insert into private.vote_delegation(id) values (true);
alter table private.vote_delegation enable row level security;
revoke all on private.vote_delegation from public, anon, authenticated, service_role;

create function private.can_manage_vote() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.members m
    where m.auth_user_id = (select auth.uid()) and m.active
      and (m.role = 'owner' or (m.role = 'staff' and exists (
        select 1 from private.vote_delegation d where d.id and d.member_id = m.id
      )))
  );
$$;

create function private.require_vote_manager() returns uuid
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.can_manage_vote() then
    raise exception '총관리자 또는 지정된 투표 대행자 권한이 필요합니다.' using errcode = '42501';
  end if;
  return (private.current_member()).id;
end;
$$;

create function private.get_vote_delegation() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_owner();
  return (select jsonb_build_object('member_id', member_id, 'updated_at', updated_at, 'updated_by', updated_by)
    from private.vote_delegation where id);
end;
$$;

create function private.set_vote_delegate(p_member_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor_id uuid;
  previous_id uuid;
begin
  perform private.require_owner();
  -- Share the voting/settings lock so revocation and the next operation serialize.
  perform id from public.event_settings where id for update;
  actor_id := private.require_owner();
  if p_member_id is not null and not exists (
    select 1 from public.members where id = p_member_id and active and role = 'staff'
  ) then
    raise exception '활성 운영진만 투표 대행자로 지정할 수 있습니다.' using errcode = '22023';
  end if;
  select member_id into strict previous_id from private.vote_delegation where id;
  if previous_id is not distinct from p_member_id then return; end if;
  update private.vote_delegation set member_id = p_member_id, updated_by = actor_id, updated_at = clock_timestamp() where id;
  insert into public.audit_logs(actor_id, action, details) values (actor_id, 'vote_delegate_changed',
    jsonb_build_object('previous_member_id', previous_id, 'member_id', p_member_id));
end;
$$;

create function public.can_manage_vote() returns boolean
language sql stable security invoker set search_path = '' as $$ select private.can_manage_vote(); $$;
create function public.get_vote_delegation() returns jsonb
language sql stable security invoker set search_path = '' as $$ select private.get_vote_delegation(); $$;
create function public.set_vote_delegate(p_member_id uuid) returns void
language sql security invoker set search_path = '' as $$ select private.set_vote_delegate(p_member_id); $$;

revoke all on function private.can_manage_vote(), private.require_vote_manager(), private.get_vote_delegation(),
  private.set_vote_delegate(uuid), public.can_manage_vote(), public.get_vote_delegation(), public.set_vote_delegate(uuid)
  from public, anon, authenticated, service_role;
grant execute on function private.can_manage_vote(), private.get_vote_delegation(), private.set_vote_delegate(uuid),
  public.can_manage_vote(), public.get_vote_delegation(), public.set_vote_delegate(uuid) to authenticated;

-- Only these existing voting entry points broaden their permission check.
-- State, clock, candidate, electorate and award validation remain unchanged.
create or replace function private.schedule_vote(p_opens_at timestamptz, p_candidate_ids uuid[]) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor public.members := private.current_member();
  event public.event_settings;
  action_at timestamptz;
begin
  perform private.require_vote_manager();
  select * into strict event from public.event_settings where id for update;
  actor := private.current_member();
  perform private.require_vote_manager();
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

create or replace function private.cancel_vote_schedule() returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor public.members := private.current_member();
  event public.event_settings;
begin
  perform private.require_vote_manager();
  select * into strict event from public.event_settings where id for update;
  actor := private.current_member();
  perform private.require_vote_manager();
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

create or replace function private.manage_vote(p_action text, p_candidate_ids uuid[], p_awards jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare actor public.members := private.current_member();
begin
  perform private.require_vote_manager();
  perform 1 from public.event_settings where id for update;
  actor := private.current_member();
  perform private.require_vote_manager();
  if p_action = 'publish' and exists (select 1 from private.vote_runoffs where closed_at is null) then
    raise exception '진행 중인 재투표의 마감을 먼저 확정해 주세요.' using errcode = '22023';
  end if;
  perform private.manage_main_vote(p_action, p_candidate_ids, p_awards);
end;
$$;

create or replace function private.manage_runoff(p_action text, p_candidate_ids uuid[], p_closes_at timestamptz, p_runoff_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  actor public.members := private.current_member();
  event public.event_settings;
  round private.vote_runoffs;
  action_at timestamptz;
  score integer;
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
      select vote_count, tied_count into score, tied from private.main_vote_tally() where team_id = p_candidate_ids[1];
      if score is null or tied <> cardinality(p_candidate_ids) or
        (select count(*) from private.main_vote_tally() where vote_count = score and team_id = any(p_candidate_ids)) <> tied then
        raise exception '본투표에서 같은 득표수인 동점 팀 전체를 선택해 주세요.' using errcode = '22023';
      end if;
      if exists (select 1 from private.vote_runoffs where main_vote_count = score) then
        raise exception '이 동점 그룹은 이미 재투표했습니다. 다시 동점이면 사유를 적어 최종 순위를 정해 주세요.' using errcode = '22023';
      end if;
      insert into private.vote_runoffs (main_vote_count, opens_at, closes_at, created_by)
        values (score, action_at, p_closes_at, actor.id) returning * into round;
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
    jsonb_build_object('runoff_id', round.id, 'main_vote_count', round.main_vote_count, 'closes_at', round.closes_at));
end;
$$;

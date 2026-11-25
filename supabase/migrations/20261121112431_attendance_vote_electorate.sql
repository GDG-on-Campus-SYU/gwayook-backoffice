-- This view is used only while preparing a vote. An existing electorate is a snapshot.
create view private.checked_in_vote_electorate with (security_invoker = true) as
  select m.id as member_id, m.team_id
  from public.members m join private.participant_operations o on o.member_id = m.id
  where m.role = 'participant' and m.active and m.team_id is not null
    and o.attendance_status in ('present', 'late');
revoke all on private.checked_in_vote_electorate from public, anon, authenticated, service_role;

create function private.start_checked_in_vote(p_candidate_ids uuid[], p_expected_eligible_count integer, p_opens_at timestamptz)
returns void language plpgsql security definer set search_path = '' as $$
declare
  actor_id uuid;
  event public.event_settings;
  action_at timestamptz;
  voter_count integer;
begin
  perform private.require_vote_manager();
  -- Attendance corrections, team assignments, and other vote operations also take this lock.
  select * into strict event from public.event_settings where id for update;
  actor_id := private.require_vote_manager();
  if actor_id is null then raise exception '약관 동의와 로그인이 필요합니다.' using errcode = '42501'; end if;
  action_at := clock_timestamp();

  if event.vote_status <> 'draft' then
    raise exception '준비 상태에서만 투표를 열거나 예약할 수 있습니다.' using errcode = '22023';
  end if;
  if p_expected_eligible_count < 0 then
    raise exception '확인한 현장 유권자 수를 확인해 주세요.' using errcode = '22023';
  end if;
  if p_opens_at is not null and (not isfinite(p_opens_at) or p_opens_at <= action_at) then
    raise exception '현재 시각 이후의 투표 시작 시각을 지정해 주세요.' using errcode = '22023';
  end if;
  if event.vote_closes_at is null or not isfinite(event.vote_closes_at)
    or coalesce(p_opens_at, action_at) >= event.vote_closes_at then
    raise exception '투표 시작보다 늦은 마감 시각을 설정해 주세요.' using errcode = '22023';
  end if;
  if coalesce(cardinality(p_candidate_ids), 0) not between 2 and 200 or
    (select count(*) from public.teams where id = any(p_candidate_ids)) <> cardinality(p_candidate_ids) then
    raise exception '서로 다른 후보 팀을 2개 이상 선택해 주세요.' using errcode = '22023';
  end if;

  insert into private.vote_candidates (team_id, name, presentation_order)
    select id, name, presentation_order from public.teams where id = any(p_candidate_ids);
  insert into private.vote_eligibility (member_id, team_id)
    select member_id, team_id from private.checked_in_vote_electorate;
  get diagnostics voter_count = row_count;
  if p_expected_eligible_count is not null and voter_count <> p_expected_eligible_count then
    raise exception '현장 유권자 수가 %명에서 %명으로 바뀌었습니다. 새 인원을 확인해 주세요.',
      p_expected_eligible_count, voter_count using errcode = '40001';
  end if;
  if voter_count = 0 then
    raise exception '팀에 배정된 활성 참가자 중 출석 또는 지각으로 확인된 사람이 필요합니다.' using errcode = '22023';
  end if;

  update public.event_settings set vote_status = 'open', vote_opens_at = coalesce(p_opens_at, action_at) where id;
  insert into public.audit_logs (actor_id, action, details)
    values (actor_id, case when p_opens_at is null then 'vote_open' else 'vote_schedule' end,
      jsonb_strip_nulls(jsonb_build_object('candidate_count', cardinality(p_candidate_ids),
        'eligible_count', voter_count, 'opens_at', p_opens_at)));
end;
$$;

create function public.confirm_vote_start(
  p_candidate_ids uuid[], p_expected_eligible_count integer, p_opens_at timestamptz default null
) returns void language plpgsql security invoker set search_path = '' as $$
begin
  if p_expected_eligible_count is null then
    raise exception '확인한 현장 유권자 수를 입력해 주세요.' using errcode = '22023';
  end if;
  perform private.start_checked_in_vote(p_candidate_ids, p_expected_eligible_count, p_opens_at);
end;
$$;
revoke all on function private.start_checked_in_vote(uuid[],integer,timestamptz),
  public.confirm_vote_start(uuid[],integer,timestamptz) from public, anon, authenticated, service_role;
grant execute on function private.start_checked_in_vote(uuid[],integer,timestamptz),
  public.confirm_vote_start(uuid[],integer,timestamptz) to authenticated;

-- Legacy calls did not supply a preview count. They still capture only checked-in voters.
create or replace function private.schedule_vote(p_opens_at timestamptz, p_candidate_ids uuid[])
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_opens_at is null then
    perform private.require_vote_manager();
    raise exception '현재 시각 이후의 투표 시작 시각을 지정해 주세요.' using errcode = '22023';
  end if;
  perform private.start_checked_in_vote(p_candidate_ids, null, p_opens_at);
end;
$$;

do $migration$
declare
  definition text;
  first_pos integer;
  next_pos integer;
  old_query constant text := 'select count(*) into eligible_count from public.members where active and role = ''participant'' and team_id is not null;';
begin
  definition := pg_get_functiondef('private.get_main_vote_overview()'::regprocedure);
  if strpos(definition, old_query) = 0 then raise exception 'Draft voter count query not found'; end if;
  execute replace(definition, old_query, 'select count(*) into eligible_count from private.checked_in_vote_electorate;');

  -- Replace just the opening branch; leave the close and award validators in place.
  definition := pg_get_functiondef('private.manage_main_vote(text,uuid[],jsonb)'::regprocedure);
  first_pos := strpos(definition, '    when ''open'' then');
  next_pos := strpos(definition, '    when ''close'' then');
  if first_pos = 0 or next_pos <= first_pos
    or strpos(substr(definition, first_pos, next_pos-first_pos), 'insert into private.vote_eligibility') = 0 then
    raise exception 'Expected main vote opening branch not found';
  end if;
  execute overlay(definition placing $new$    when 'open' then
      perform private.start_checked_in_vote(p_candidate_ids, null, null);
      return;
$new$ from first_pos for next_pos-first_pos);
end;
$migration$;

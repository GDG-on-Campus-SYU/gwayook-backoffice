-- Participant-submitted GSA email is separate from the app login identity.
-- Existing values are preserved; new checks never infer evidence from old status.
alter table private.participant_operations
  add column gsa_plus_active boolean not null default false,
  add column gsa_email_matched boolean not null default false;

create function private.get_my_gsa() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare actor public.members := private.current_member();
begin
  if actor.id is null or actor.role <> 'participant' then
    raise exception '등록된 참가자만 자신의 GSA 신청 정보를 확인할 수 있습니다.' using errcode = '42501';
  end if;
  return (select jsonb_build_object('gsa_email', o.gsa_email, 'gsa_status', coalesce(o.gsa_status, 'pending'),
    'gsa_updated_at', o.gsa_updated_at) from (values(actor.id)) m(id)
    left join private.participant_operations o on o.member_id = m.id);
end;
$$;

create function private.submit_my_gsa_email(p_email text, p_expected_updated_at timestamptz) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor public.members := private.current_member();
  previous private.participant_operations;
  saved private.participant_operations;
  clean_email text := lower(btrim(p_email));
  recorded_at timestamptz;
begin
  if actor.id is null or actor.role <> 'participant' then
    raise exception '등록된 참가자만 자신의 GSA 신청 이메일을 저장할 수 있습니다.' using errcode = '42501';
  end if;
  perform id from public.event_settings where id for update;
  actor := private.current_member();
  if actor.id is null or actor.role <> 'participant' then
    raise exception '등록된 참가자만 자신의 GSA 신청 이메일을 저장할 수 있습니다.' using errcode = '42501';
  end if;
  if clean_email is null or char_length(clean_email) > 254
    or clean_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception 'GSA 신청에 사용한 이메일을 입력해 주세요. 앱 로그인 이메일은 바뀌지 않습니다.' using errcode = '22023';
  end if;
  select * into previous from private.participant_operations where member_id = actor.id for update;
  -- Retrying the same normalized email never resets a completed verification.
  if previous.gsa_email is not distinct from clean_email then return; end if;
  if previous.gsa_updated_at is distinct from p_expected_updated_at then
    raise exception 'GSA 정보가 변경되었습니다. 새로고침 후 입력한 이메일과 확인 상태를 다시 확인해 주세요.' using errcode = '22023';
  end if;
  recorded_at := greatest(clock_timestamp(), previous.gsa_updated_at + interval '1 microsecond');
  insert into private.participant_operations(member_id, gsa_email, gsa_status, gsa_plus_active, gsa_email_matched, gsa_updated_by, gsa_updated_at)
    values(actor.id, clean_email, 'pending', false, false, actor.id, recorded_at)
    on conflict(member_id) do update set gsa_email = excluded.gsa_email, gsa_status = 'pending',
      gsa_plus_active = false, gsa_email_matched = false, gsa_updated_by = excluded.gsa_updated_by,
      gsa_updated_at = excluded.gsa_updated_at returning * into saved;
  insert into public.audit_logs(actor_id, action, target_id, details) values(actor.id, 'participant_gsa_email_submitted', actor.id,
    jsonb_build_object('before', jsonb_build_object('email', previous.gsa_email, 'status', coalesce(previous.gsa_status, 'pending'),
      'plus_active', previous.gsa_plus_active, 'email_matched', previous.gsa_email_matched,
      'updated_by', previous.gsa_updated_by, 'updated_at', previous.gsa_updated_at),
      'after', jsonb_build_object('email', saved.gsa_email, 'status', saved.gsa_status,
      'plus_active', saved.gsa_plus_active, 'email_matched', saved.gsa_email_matched,
      'updated_by', saved.gsa_updated_by, 'updated_at', saved.gsa_updated_at)));
end;
$$;

-- Remove the old five-argument endpoint entirely so it cannot mark verified
-- without the two new evidence checks. No overload/default can select it.
drop function public.set_participant_gsa(uuid, text, text, text, timestamptz);
drop function private.set_participant_gsa(uuid, text, text, text, timestamptz);

create function private.set_participant_gsa(p_member_id uuid, p_status text, p_gsa_email text, p_note text,
  p_expected_updated_at timestamptz, p_plus_active boolean, p_email_matched boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor_id uuid;
  previous private.participant_operations;
  saved private.participant_operations;
  clean_email text := nullif(lower(btrim(p_gsa_email)), '');
  clean_note text := case when p_note ~ '[^[:space:]]' then btrim(p_note) end;
  recorded_at timestamptz;
begin
  perform private.require_staff();
  perform id from public.event_settings where id for update;
  actor_id := private.require_staff();
  if p_status is null or p_status not in ('pending', 'verified', 'failed')
    or p_plus_active is null or p_email_matched is null then
    raise exception 'GSA 확인 상태와 현장 확인 항목을 다시 확인해 주세요.' using errcode = '22023';
  end if;
  if clean_email is not null and (char_length(clean_email) > 254 or clean_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$') then
    raise exception 'GSA 가입 이메일을 확인해 주세요. 앱 로그인 이메일과는 별도 기록입니다.' using errcode = '22023';
  end if;
  if char_length(clean_note) > 500 then raise exception '메모는 500자 이내로 입력해 주세요.' using errcode = '22023'; end if;
  if not exists(select 1 from public.members where id = p_member_id and role = 'participant') then
    raise exception '기록할 참가자를 찾을 수 없습니다.' using errcode = '22023';
  end if;
  select * into previous from private.participant_operations where member_id = p_member_id for update;
  if previous.gsa_email is distinct from clean_email and (p_status <> 'pending' or p_plus_active or p_email_matched) then
    raise exception '이메일 정정은 확인 대기 상태로 먼저 저장해 주세요. 정정된 이메일로 두 항목을 다시 확인해야 합니다.' using errcode = '22023';
  end if;
  if p_status = 'verified' and (clean_email is null or not p_plus_active or not p_email_matched) then
    raise exception '확인 완료는 저장된 신청 이메일, Google AI Plus 활성 상태와 실제 Google 계정 이메일 일치를 모두 확인해야 합니다.' using errcode = '22023';
  end if;
  if p_status <> 'verified' and (p_plus_active or p_email_matched) then
    raise exception '확인 대기·실패 상태에서는 현장 확인 항목을 해제해 주세요.' using errcode = '22023';
  end if;
  if coalesce(previous.gsa_status, 'pending') = p_status and previous.gsa_email is not distinct from clean_email
    and previous.gsa_note is not distinct from clean_note and coalesce(previous.gsa_plus_active, false) = p_plus_active
    and coalesce(previous.gsa_email_matched, false) = p_email_matched then return; end if;
  if previous.gsa_updated_at is distinct from p_expected_updated_at then
    raise exception '다른 화면에서 GSA 기록을 변경했습니다. 새로고침 후 다시 확인해 주세요.' using errcode = '22023';
  end if;
  recorded_at := greatest(clock_timestamp(), previous.gsa_updated_at + interval '1 microsecond');
  insert into private.participant_operations(member_id, gsa_status, gsa_email, gsa_note, gsa_plus_active, gsa_email_matched, gsa_updated_by, gsa_updated_at)
    values(p_member_id, p_status, clean_email, clean_note, p_plus_active, p_email_matched, actor_id, recorded_at)
    on conflict(member_id) do update set gsa_status = excluded.gsa_status, gsa_email = excluded.gsa_email,
      gsa_note = excluded.gsa_note, gsa_plus_active = excluded.gsa_plus_active, gsa_email_matched = excluded.gsa_email_matched,
      gsa_updated_by = excluded.gsa_updated_by, gsa_updated_at = excluded.gsa_updated_at returning * into saved;
  insert into public.audit_logs(actor_id, action, target_id, details) values(actor_id, 'participant_gsa_changed', p_member_id,
    jsonb_build_object('before', jsonb_build_object('status', coalesce(previous.gsa_status, 'pending'), 'email', previous.gsa_email,
      'note', previous.gsa_note, 'plus_active', previous.gsa_plus_active, 'email_matched', previous.gsa_email_matched,
      'updated_by', previous.gsa_updated_by, 'updated_at', previous.gsa_updated_at),
      'after', jsonb_build_object('status', saved.gsa_status, 'email', saved.gsa_email, 'note', saved.gsa_note,
      'plus_active', saved.gsa_plus_active, 'email_matched', saved.gsa_email_matched,
      'updated_by', saved.gsa_updated_by, 'updated_at', saved.gsa_updated_at)));
end;
$$;

create function public.get_my_gsa() returns jsonb
language sql stable security invoker set search_path = '' as $$ select private.get_my_gsa(); $$;
create function public.submit_my_gsa_email(p_email text, p_expected_updated_at timestamptz) returns void
language sql security invoker set search_path = '' as $$ select private.submit_my_gsa_email(p_email, p_expected_updated_at); $$;
create function public.set_participant_gsa(p_member_id uuid, p_status text, p_gsa_email text, p_note text,
  p_expected_updated_at timestamptz, p_plus_active boolean, p_email_matched boolean) returns void
language sql security invoker set search_path = '' as $$
  select private.set_participant_gsa(p_member_id, p_status, p_gsa_email, p_note, p_expected_updated_at, p_plus_active, p_email_matched); $$;
revoke all on function private.get_my_gsa(), private.submit_my_gsa_email(text, timestamptz),
  private.set_participant_gsa(uuid, text, text, text, timestamptz, boolean, boolean), public.get_my_gsa(),
  public.submit_my_gsa_email(text, timestamptz), public.set_participant_gsa(uuid, text, text, text, timestamptz, boolean, boolean)
  from public, anon, authenticated, service_role;
grant execute on function private.get_my_gsa(), private.submit_my_gsa_email(text, timestamptz),
  private.set_participant_gsa(uuid, text, text, text, timestamptz, boolean, boolean), public.get_my_gsa(),
  public.submit_my_gsa_email(text, timestamptz), public.set_participant_gsa(uuid, text, text, text, timestamptz, boolean, boolean) to authenticated;

create or replace function private.get_participant_operations() returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
  perform private.require_staff();
  return coalesce((select jsonb_agg(jsonb_build_object(
    'member_id',m.id,'name',m.name,'email',m.email,'team_id',m.team_id,'team_name',t.name,'active',m.active,
    'gsa_status',coalesce(o.gsa_status,'pending'),'gsa_email',o.gsa_email,'gsa_note',o.gsa_note,
    'gsa_plus_active',coalesce(o.gsa_plus_active,false),'gsa_email_matched',coalesce(o.gsa_email_matched,false),
    'gsa_updated_by_name',g.name,'gsa_updated_at',o.gsa_updated_at,
    'attendance_status',coalesce(o.attendance_status,'pending'),'attendance_note',o.attendance_note,
    'checked_in_at',o.checked_in_at,'attendance_updated_by_name',a.name,'attendance_updated_at',o.attendance_updated_at
  ) order by m.name,m.email,m.id) from public.members m
    left join public.teams t on t.id=m.team_id
    left join private.participant_operations o on o.member_id=m.id
    left join public.members g on g.id=o.gsa_updated_by
    left join public.members a on a.id=o.attendance_updated_by
    where m.role='participant'),'[]'::jsonb);
end;
$$;

create or replace function private.get_event_export(p_kind text) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare
  headers jsonb;
  export_rows jsonb:='[]';
  details jsonb;
  round_rows jsonb;
  selected_round integer;
begin
  perform private.require_staff();
  -- Keep authorization and event state stable while producing the export.
  perform id from public.event_settings where id for share;
  perform private.require_staff();
  case p_kind
    when 'teams' then
      headers:='["팀명","발표 순서","대표자","이름","로그인 이메일","참가 상태"]'::jsonb;
      with roster as (
        select t.name as team_name,t.presentation_order,r.name as representative_name,m.name as member_name,m.email,m.active
        from public.teams t left join public.members r on r.id=t.representative_id
        left join public.members m on m.team_id=t.id and m.role='participant'
        union all
        select '미배정',null,null,m.name,m.email,m.active from public.members m where m.role='participant' and m.team_id is null
      ) select coalesce(jsonb_agg(jsonb_build_array(team_name,presentation_order,representative_name,member_name,email,
        case when active then '활성' when not active then '비활성' end)
        order by presentation_order nulls last,team_name,member_name,email),'[]') into export_rows from roster;
    when 'attendance' then
      headers:='["이름","로그인 이메일","팀","참가 상태","출석 상태","체크인 시각 (한국 시간)","출석 메모","기록자","변경 시각 (한국 시간)"]'::jsonb;
      details:=private.get_participant_operations();
      select coalesce(jsonb_agg(jsonb_build_array(p->>'name',p->>'email',coalesce(p->>'team_name','미배정'),
        case when (p->>'active')::boolean then '활성' else '비활성' end,
        case p->>'attendance_status' when 'pending' then '미확인' when 'present' then '출석' when 'late' then '지각' else '불참' end,
        to_char((p->>'checked_in_at')::timestamptz at time zone 'Asia/Seoul','YYYY-MM-DD HH24:MI:SS.US'),
        p->>'attendance_note',p->>'attendance_updated_by_name',
        to_char((p->>'attendance_updated_at')::timestamptz at time zone 'Asia/Seoul','YYYY-MM-DD HH24:MI:SS.US')) order by n),'[]')
        into export_rows from jsonb_array_elements(details) with ordinality records(p,n);
    when 'gsa' then
      headers:='["이름","로그인 이메일","팀","참가 상태","GSA 가입 이메일","GSA 확인 상태","Google AI Plus 활성 확인","Google 이메일 일치 확인","확인 메모","기록자","변경 시각 (한국 시간)"]'::jsonb;
      details:=private.get_participant_operations();
      select coalesce(jsonb_agg(jsonb_build_array(p->>'name',p->>'email',coalesce(p->>'team_name','미배정'),
        case when (p->>'active')::boolean then '활성' else '비활성' end,p->>'gsa_email',
        case p->>'gsa_status' when 'pending' then '확인 대기' when 'verified' then '확인 완료' else '확인 실패' end,
        case when (p->>'gsa_plus_active')::boolean then '확인' else '미확인' end,
        case when (p->>'gsa_email_matched')::boolean then '확인' else '미확인' end,
        p->>'gsa_note',p->>'gsa_updated_by_name',
        to_char((p->>'gsa_updated_at')::timestamptz at time zone 'Asia/Seoul','YYYY-MM-DD HH24:MI:SS.US')) order by n),'[]')
        into export_rows from jsonb_array_elements(details) with ordinality records(p,n);
    when 'bingo' then
      headers:='["회차","이름","로그인 이메일","O표 수","완성 줄 수","완성 순위","공동 순위 인원","첫 3줄 완성 시각 (한국 시간)","완성 소요 초","완성 당시 팀","검토 표시 수"]'::jsonb;
      for selected_round in select round_no from private.bingo_rounds where opens_at is not null order by round_no loop
        details:=private.get_bingo_round(selected_round);
        select coalesce(jsonb_agg(jsonb_build_array(selected_round,p->>'name',p->>'email',(p->>'marked_count')::integer,
          (p->>'completed_lines')::integer,(p->>'completion_rank')::integer,(p->>'completion_tied_count')::integer,
          to_char((p->>'completed_at')::timestamptz at time zone 'Asia/Seoul','YYYY-MM-DD HH24:MI:SS.US'),
          (p->>'completion_elapsed_seconds')::numeric,
          case when p->>'completed_at' is not null then coalesce(p->>'completed_team_name','기록 없음') end,
          (p->>'suspicious_count')::integer) order by n),'[]') into round_rows
          from jsonb_array_elements(details->'participants') with ordinality records(p,n);
        export_rows:=export_rows || round_rows;
      end loop;
    when 'voting' then
      details:=private.get_vote_details();
      if details->>'status' not in ('closed','published') then
        raise exception '본투표 마감을 확정한 뒤 집계 CSV를 내려받을 수 있습니다.' using errcode='22023';
      end if;
      headers:='["팀","본투표 원득표","Gemini 가산점","합계 점수","마감된 재투표 득표","현재 순위","동점 팀 수","결과 상태"]'::jsonb;
      select coalesce(jsonb_agg(jsonb_build_array(p->>'name',(p->>'vote_count')::integer,(p->>'gemini_bonus')::integer,
        (p->>'total_score')::integer,(p->>'runoff_vote_count')::integer,(p->>'raw_rank')::integer,(p->>'tied_count')::integer,
        case details->>'status' when 'published' then '결과 공개' else '마감 · 미공개' end) order by n),'[]')
        into export_rows from jsonb_array_elements(details->'results') with ordinality records(p,n);
    when 'awards' then
      details:=private.get_vote_details();
      if details->>'status' is distinct from 'published' then
        raise exception '수상 결과를 공개한 뒤 수상 CSV를 내려받을 수 있습니다.' using errcode='22023';
      end if;
      headers:='["최종 순위","수상명","팀","본투표 원득표","Gemini 가산점","합계 점수","마감된 재투표 득표","동점 결정 사유"]'::jsonb;
      select coalesce(jsonb_agg(jsonb_build_array((p->>'final_rank')::integer,p->>'award_name',p->>'name',
        (p->>'vote_count')::integer,(p->>'gemini_bonus')::integer,(p->>'total_score')::integer,
        (p->>'runoff_vote_count')::integer,p->>'tie_reason') order by (p->>'final_rank')::integer),'[]')
        into export_rows from jsonb_array_elements(details->'results') p where p->>'final_rank' is not null;
    else raise exception '내보내기 종류를 다시 선택해 주세요.' using errcode='22023';
  end case;
  return jsonb_build_object('kind',p_kind,'headers',headers,'rows',export_rows);
end;
$$;

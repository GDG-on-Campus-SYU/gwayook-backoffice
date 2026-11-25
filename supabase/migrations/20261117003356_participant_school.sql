-- School is optional operational roster data. Existing rows remain unclassified.
alter table public.members add column school text
  check (school is null or (char_length(school) between 1 and 100 and school = regexp_replace(school, '^[[:space:]]+|[[:space:]]+$', '', 'g')));

-- Patch the established locked mutations and logged read bodies, preserving their
-- role checks, consent gates, grants and access-log wrappers. Fail on schema drift.
do $migration$
declare patch record; definition text;
begin
  for patch in select * from (values
    ('private.manage_participant_registration(text,jsonb)',
      '  case p_action',
      $new$  if p_action = 'create_member' and (
    coalesce(jsonb_typeof(p_payload->'school'), 'null') not in ('null', 'string')
    or char_length(regexp_replace(p_payload->>'school', '^[[:space:]]+|[[:space:]]+$', '', 'g')) > 100
  ) then raise exception '학교는 100자 이내로 입력해 주세요.' using errcode = '22023'; end if;
  case p_action$new$),
    ('private.manage_participant_registration(text,jsonb)',
      'insert into public.members (name, email, team_id, role)',
      'insert into public.members (name, email, team_id, role, school)'),
    ('private.manage_participant_registration(text,jsonb)',
      $old$(new_name, new_email, (p_payload->>'team_id')::uuid, 'participant')$old$,
      $new$(new_name, new_email, (p_payload->>'team_id')::uuid, 'participant', nullif(regexp_replace(p_payload->>'school', '^[[:space:]]+|[[:space:]]+$', '', 'g'), ''))$new$),
    ('private.manage_roster(text,jsonb)',
      $old$    when 'update_member' then$old$,
      $new$    when 'update_member' then
      if coalesce(jsonb_typeof(p_payload->'school'), 'null') not in ('null', 'string')
        or char_length(regexp_replace(p_payload->>'school', '^[[:space:]]+|[[:space:]]+$', '', 'g')) > 100 then
        raise exception '학교는 100자 이내로 입력해 주세요.' using errcode = '22023';
      end if;$new$),
    ('private.manage_roster(text,jsonb)',
      'update public.members set name = new_name, team_id = destination_id, active = new_active where',
      $new$update public.members set name = new_name, team_id = destination_id, active = new_active,
        school = case when p_payload ? 'school' then nullif(regexp_replace(p_payload->>'school', '^[[:space:]]+|[[:space:]]+$', '', 'g'), '') else school end where$new$),
    ('private.roster_preview_without_access_log(jsonb)',
      '  member_name text;', '  member_school text; member_name text;'),
    ('private.roster_preview_without_access_log(jsonb)',
      $old$    member_name := btrim(input->>'name');$old$,
      $new$    member_school := nullif(regexp_replace(input->>'school', '^[[:space:]]+|[[:space:]]+$', '', 'g'), '');
    if coalesce(jsonb_typeof(input->'school'), 'null') not in ('null', 'string') or char_length(member_school) > 100 then
      errors := errors || jsonb_build_array(row_label || '학교는 100자 이내의 문자로 입력해 주세요.');
      continue;
    end if;
    member_name := btrim(input->>'name');$new$),
    ('private.roster_preview_without_access_log(jsonb)',
      '    select * into previous_team',
      $new$    member_school := coalesce(member_school, existing_member.school);
    select * into previous_team$new$),
    ('private.roster_preview_without_access_log(jsonb)',
      $old$'row', row_no, 'name', member_name, 'email', member_email,$old$,
      $new$'row', row_no, 'name', member_name, 'email', member_email, 'school', member_school,$new$),
    ('private.roster_preview_without_access_log(jsonb)',
      'when existing_member.name <> member_name or',
      'when existing_member.school is distinct from member_school or existing_member.name <> member_name or'),
    ('private.roster_preview_without_access_log(jsonb)',
      $old$jsonb_build_object('name', existing_member.name, 'team', previous_team.name,$old$,
      $new$jsonb_build_object('name', existing_member.name, 'school', existing_member.school, 'team', previous_team.name,$new$),
    ('private.roster_preview_without_access_log(jsonb)',
      'jsonb_build_array(id, name, email, team_id, role, active)',
      'jsonb_build_array(id, name, email, team_id, role, active, school)'),
    ('private.roster_apply(jsonb,text)',
      'insert into public.members (name, email, team_id)',
      'insert into public.members (name, email, team_id, school)'),
    ('private.roster_apply(jsonb,text)',
      $old$select r.value->>'name', r.value->>'email', t.id$old$,
      $new$select r.value->>'name', r.value->>'email', t.id, r.value->>'school'$new$),
    ('private.roster_apply(jsonb,text)',
      'do update set name = excluded.name, team_id = excluded.team_id',
      'do update set name = excluded.name, team_id = excluded.team_id, school = excluded.school'),
    ('private.get_participant_operations_without_access_log()',
      $old$'member_id',m.id,'name',m.name,'email',m.email,$old$,
      $new$'member_id',m.id,'name',m.name,'email',m.email,'school',m.school,$new$),
    ('private.get_event_export_without_access_log(text)',
      $old$["팀명","발표 순서","대표자","이름","로그인 이메일","참가 상태"]$old$,
      $new$["팀명","발표 순서","대표자","이름","로그인 이메일","참가 상태","학교"]$new$),
    ('private.get_event_export_without_access_log(text)',
      'm.name as member_name,m.email,m.active',
      'm.name as member_name,m.email,m.active,m.school'),
    ('private.get_event_export_without_access_log(text)',
      $old$select '미배정',null,null,m.name,m.email,m.active from$old$,
      $new$select '미배정',null,null,m.name,m.email,m.active,m.school from$new$),
    ('private.get_event_export_without_access_log(text)',
      $old$case when active then '활성' when not active then '비활성' end)$old$,
      $new$case when active then '활성' when not active then '비활성' end,school)$new$),
    ('private.get_event_export_without_access_log(text)',
      $old$["이름","로그인 이메일","팀","참가 상태","출석 상태","체크인 시각 (한국 시간)","출석 메모","기록자","변경 시각 (한국 시간)"]$old$,
      $new$["이름","로그인 이메일","팀","참가 상태","출석 상태","체크인 시각 (한국 시간)","출석 메모","기록자","변경 시각 (한국 시간)","학교"]$new$),
    ('private.get_event_export_without_access_log(text)',
      $old$to_char((p->>'attendance_updated_at')::timestamptz at time zone 'Asia/Seoul','YYYY-MM-DD HH24:MI:SS.US'))$old$,
      $new$to_char((p->>'attendance_updated_at')::timestamptz at time zone 'Asia/Seoul','YYYY-MM-DD HH24:MI:SS.US'),p->>'school')$new$)
  ) patches(signature, old, new) loop
    definition := replace(pg_get_functiondef(patch.signature::regprocedure), E'\r\n', E'\n');
    if strpos(definition, patch.old) = 0 or (length(definition)-length(replace(definition,patch.old,'')))/length(patch.old) <> 1 then
      raise exception 'School migration requires exactly one match in %: %', patch.signature, patch.old;
    end if;
    execute replace(definition, patch.old, patch.new);
  end loop;
end;
$migration$;

create or replace function private.roster_preview(p_rows jsonb) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  actor_id uuid := private.require_staff();
  input jsonb;
  ordinal integer := 0;
  row_no integer;
  row_label text;
  member_name text;
  member_email text;
  team_name text;
  representative boolean;
  previous_rep boolean;
  existing_member public.members;
  previous_team public.teams;
  destination public.teams;
  item jsonb;
  seen text[] := array[]::text[];
  preview_rows jsonb := '[]';
  errors jsonb := '[]';
  new_teams jsonb;
  revision text;
begin
  if jsonb_typeof(p_rows) is distinct from 'array' then
    return jsonb_build_object('revision', '', 'rows', '[]'::jsonb, 'new_teams', '[]'::jsonb, 'errors', jsonb_build_array('참가자 명단을 확인해 주세요.'));
  end if;
  if jsonb_array_length(p_rows) not between 1 and 200 then
    return jsonb_build_object('revision', '', 'rows', '[]'::jsonb, 'new_teams', '[]'::jsonb, 'errors', jsonb_build_array('참가자 명단은 1~200행으로 업로드해 주세요.'));
  end if;

  for input in select value from jsonb_array_elements(p_rows) loop
    ordinal := ordinal + 1;
    row_no := case when input->>'row' ~ '^[1-9][0-9]{0,6}$' then (input->>'row')::integer else ordinal + 1 end;
    row_label := row_no || '행: ';
    member_name := btrim(input->>'name');
    member_email := lower(btrim(input->>'email'));
    team_name := nullif(regexp_replace(input->>'team', '^[[:space:]]+|[[:space:]]+$', '', 'g'), '');

    if jsonb_typeof(input->'name') is distinct from 'string' or char_length(member_name) not between 1 and 100
      or coalesce(jsonb_typeof(input->'team'), 'null') not in ('null', 'string') or char_length(team_name) > 100
      or jsonb_typeof(input->'email') is distinct from 'string' or char_length(member_email) > 254
      or member_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
      or coalesce(jsonb_typeof(input->'representative'), 'null') not in ('null', 'boolean') then
      errors := errors || jsonb_build_array(row_label || '이름, 이메일, 팀명 또는 대표자 값이 올바르지 않습니다.');
      continue;
    end if;

    if member_email = any(seen) then
      errors := errors || jsonb_build_array(row_label || '파일 내 이메일이 중복되었습니다.');
      continue;
    end if;
    seen := array_append(seen, member_email);

    select * into existing_member from public.members where email = member_email;
    if existing_member.role in ('staff', 'owner') then
      errors := errors || jsonb_build_array(row_label || '운영진 이메일은 참가자 명단에 추가할 수 없습니다.');
      continue;
    end if;

    select * into previous_team from public.teams where id = existing_member.team_id;
    team_name := coalesce(team_name, previous_team.name);
    select * into destination from public.teams where lower(name) = lower(team_name);
    team_name := coalesce(destination.name, team_name);
    previous_rep := coalesce(previous_team.representative_id = existing_member.id, false);
    representative := coalesce((input->>'representative')::boolean, previous_rep and destination.id is not null and destination.id = previous_team.id);
    if representative and team_name is null then
      errors := errors || jsonb_build_array(row_label || '팀에 배정된 참가자만 대표자로 지정할 수 있습니다.');
      continue;
    end if;
    if representative and existing_member.active is false then
      errors := errors || jsonb_build_array(row_label || '비활성 참가자는 대표자로 지정할 수 없습니다.');
      continue;
    end if;

    item := jsonb_build_object(
      'row', row_no, 'name', member_name, 'email', member_email, 'team', team_name, 'representative', representative,
      'action', case when existing_member.id is null then 'insert'
        when existing_member.name <> member_name or existing_member.team_id is distinct from destination.id
          or (team_name is not null and destination.id is null) or previous_rep <> representative then 'update'
        else 'unchanged' end
    );
    if existing_member.id is not null then
      item := item || jsonb_build_object('before', jsonb_build_object('name', existing_member.name, 'team', previous_team.name, 'representative', previous_rep));
    end if;
    preview_rows := preview_rows || jsonb_build_array(item);
  end loop;

  select errors || coalesce(jsonb_agg('팀명이 대소문자만 다르게 입력되었습니다: ' || team_names), '[]'::jsonb) into errors
  from (
    select string_agg(distinct value->>'team', ', ') as team_names from jsonb_array_elements(preview_rows)
    group by lower(value->>'team') having count(distinct value->>'team') > 1
  ) variants;

  select errors || coalesce(jsonb_agg(team || ' 팀의 대표자가 여러 명입니다.'), '[]'::jsonb) into errors
  from (
    select team from (
      select value->>'team' as team from jsonb_array_elements(preview_rows) where (value->>'representative')::boolean
      union all
      select t.name from public.teams t join public.members m on m.id = t.representative_id
      where not (m.email = any(seen))
    ) representatives group by team having count(*) > 1
  ) conflicts;

  select coalesce(jsonb_agg(team order by team), '[]'::jsonb) into new_teams
  from (select distinct value->>'team' as team from jsonb_array_elements(preview_rows)
        where value->>'team' is not null and not exists (select 1 from public.teams t where t.name = value->>'team')) missing;

  revision := encode(sha256(convert_to(jsonb_build_array(
    actor_id, p_rows,
    (select jsonb_agg(jsonb_build_array(id, name, email, team_id, role, active) order by id) from public.members),
    (select jsonb_agg(to_jsonb(t) order by t.id) from public.teams t)
  )::text, 'UTF8')), 'hex');

  return jsonb_build_object('revision', revision, 'rows', preview_rows, 'new_teams', new_teams, 'errors', errors);
end;
$$;

create or replace function private.roster_apply(p_rows jsonb, p_revision text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  actor_id uuid;
  preview jsonb;
  changed_count integer;
begin
  -- Serialize roster mutations so validation and application observe the same roster.
  perform private.require_staff();
  perform id from public.event_settings where id for update;
  actor_id := private.require_staff();
  preview := private.roster_preview(p_rows);
  if jsonb_array_length(preview->'errors') > 0 then return preview; end if;
  if p_revision is distinct from preview->>'revision' then
    return jsonb_set(preview, '{errors}', jsonb_build_array('명단이 변경되었습니다. 다시 미리보기 해 주세요.'));
  end if;

  insert into public.teams (name) select value from jsonb_array_elements_text(preview->'new_teams');

  update public.teams t set representative_id = null
  from public.members m, jsonb_array_elements(preview->'rows') r
  where t.representative_id = m.id and m.email = r.value->>'email'
    and (t.name is distinct from (r.value->>'team') or not (r.value->>'representative')::boolean);

  insert into public.members (name, email, team_id)
  select r.value->>'name', r.value->>'email', t.id
  from jsonb_array_elements(preview->'rows') r left join public.teams t on t.name = r.value->>'team'
  where r.value->>'action' <> 'unchanged'
  on conflict (email) do update set name = excluded.name, team_id = excluded.team_id
  where members.role = 'participant';
  get diagnostics changed_count = row_count;

  update public.teams t set representative_id = m.id
  from public.members m, jsonb_array_elements(preview->'rows') r
  where m.email = r.value->>'email' and t.id = m.team_id and (r.value->>'representative')::boolean
    and t.representative_id is distinct from m.id;

  if changed_count > 0 then
    insert into public.audit_logs (actor_id, action, details)
    values (actor_id, 'roster_import', jsonb_build_object('changed_members', changed_count, 'new_teams', jsonb_array_length(preview->'new_teams')));
  end if;
  return preview;
end;
$$;

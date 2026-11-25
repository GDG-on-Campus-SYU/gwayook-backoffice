create schema private;
revoke all on schema private from public, anon, authenticated;
grant usage on schema private to authenticated;
alter default privileges in schema private revoke execute on functions from public;

create table public.event_settings (
  id boolean primary key default true check (id),
  name text not null,
  event_date date not null,
  notice text,
  contact text,
  event_starts_at timestamptz,
  event_ends_at timestamptz,
  submission_deadline timestamptz,
  vote_opens_at timestamptz,
  vote_closes_at timestamptz,
  check (event_ends_at > event_starts_at),
  check (vote_closes_at > vote_opens_at)
);
insert into public.event_settings (name, event_date) values ('과육톤', '2026-11-24');

create table public.teams (
  id uuid primary key default gen_random_uuid(),
  name text not null check (name = btrim(name) and char_length(name) between 1 and 100),
  representative_id uuid,
  presentation_order integer check (presentation_order between 1 and 200)
);
create unique index teams_name_unique on public.teams (lower(name));

create table public.members (
  id uuid primary key default gen_random_uuid(),
  name text not null check (name = btrim(name) and char_length(name) between 1 and 100),
  email text not null unique check (
    email = lower(btrim(email)) and char_length(email) <= 254 and email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
  ),
  auth_user_id uuid unique references auth.users (id) on delete set null,
  team_id uuid references public.teams (id),
  role text not null default 'participant' check (role in ('participant', 'staff', 'owner')),
  active boolean not null default true,
  representative_team_id uuid generated always as (
    case when active and role = 'participant' then team_id end
  ) stored,
  unique (id, representative_team_id),
  check (role = 'participant' or team_id is null)
);
create index members_team_id on public.members (team_id);

alter table public.teams add constraint representative_is_active_team_member
  foreign key (representative_id, id) references public.members (id, representative_team_id);

create table public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid not null references public.members (id),
  action text not null,
  target_id uuid,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.event_settings enable row level security;
alter table public.teams enable row level security;
alter table public.members enable row level security;
alter table public.audit_logs enable row level security;

revoke all on public.event_settings, public.teams, public.members, public.audit_logs from public, anon, authenticated;
grant select on public.event_settings, public.teams, public.members, public.audit_logs to authenticated;

create function private.current_member() returns public.members
language sql stable security definer set search_path = '' as $$
  select m from public.members m where m.auth_user_id = (select auth.uid()) and m.active;
$$;

create policy read_own_member_or_staff on public.members for select to authenticated
  using (active and auth_user_id = (select auth.uid()) or (select (private.current_member()).role) in ('staff', 'owner'));
create policy read_active_member_teams on public.teams for select to authenticated
  using ((select (private.current_member()).id) is not null);
create policy read_active_member_event on public.event_settings for select to authenticated
  using ((select (private.current_member()).id) is not null);
create policy read_staff_audit on public.audit_logs for select to authenticated
  using ((select (private.current_member()).role) in ('staff', 'owner'));

create function private.require_staff() returns uuid
language plpgsql stable set search_path = '' as $$
declare
  actor public.members := private.current_member();
begin
  if actor.id is null or actor.role not in ('staff', 'owner') then
    raise exception '운영진 권한이 필요합니다.' using errcode = '42501';
  end if;
  return actor.id;
end;
$$;

create function private.bind_member() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  user_id uuid := auth.uid();
  verified_email text;
  matched public.members;
begin
  if user_id is null then return null; end if;

  select lower(btrim(u.email)) into verified_email
  from auth.users u
  where u.id = user_id and u.email_confirmed_at is not null
    and exists (
      select 1 from auth.identities i
      where i.user_id = u.id and i.provider = 'google'
        and i.identity_data->'email_verified' = 'true'::jsonb
        and lower(btrim(i.identity_data->>'email')) = lower(btrim(u.email))
    );

  if verified_email is null then return null; end if;

  select m.* into matched from public.members m
  where m.email = verified_email and m.active for update;
  if not found or (matched.auth_user_id is not null and matched.auth_user_id <> user_id) then
    return null;
  end if;

  if matched.auth_user_id is null then
    if exists (select 1 from public.members m where m.auth_user_id = user_id) then
      return null;
    end if;
    update public.members set auth_user_id = user_id where id = matched.id returning * into matched;
  end if;
  return to_jsonb(matched) - 'representative_team_id';
end;
$$;

create function private.get_my_team() returns jsonb
language sql stable security definer set search_path = '' as $$
  select to_jsonb(t) || jsonb_build_object('members', (
    select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name) order by m.name, m.id), '[]'::jsonb)
    from public.members m where m.team_id = t.id and m.active
  ))
  from public.teams t where t.id = (private.current_member()).team_id;
$$;

create function private.roster_preview(p_rows jsonb) returns jsonb
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
    team_name := btrim(input->>'team');

    if jsonb_typeof(input->'name') is distinct from 'string' or char_length(member_name) not between 1 and 100
      or jsonb_typeof(input->'team') is distinct from 'string' or char_length(team_name) not between 1 and 100
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
    select * into destination from public.teams where lower(name) = lower(team_name);
    team_name := coalesce(destination.name, team_name);
    previous_rep := coalesce(previous_team.representative_id = existing_member.id, false);
    representative := coalesce((input->>'representative')::boolean, previous_rep and destination.id is not null and destination.id = previous_team.id);
    if representative and existing_member.active is false then
      errors := errors || jsonb_build_array(row_label || '비활성 참가자는 대표자로 지정할 수 없습니다.');
      continue;
    end if;

    item := jsonb_build_object(
      'row', row_no, 'name', member_name, 'email', member_email, 'team', team_name, 'representative', representative,
      'action', case when existing_member.id is null then 'insert'
        when existing_member.name <> member_name or existing_member.team_id is distinct from destination.id
          or destination.id is null or previous_rep <> representative then 'update'
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
        where not exists (select 1 from public.teams t where t.name = value->>'team')) missing;

  revision := encode(sha256(convert_to(jsonb_build_array(
    actor_id, p_rows,
    (select jsonb_agg(jsonb_build_array(id, name, email, team_id, role, active) order by id) from public.members),
    (select jsonb_agg(to_jsonb(t) order by t.id) from public.teams t)
  )::text, 'UTF8')), 'hex');

  return jsonb_build_object('revision', revision, 'rows', preview_rows, 'new_teams', new_teams, 'errors', errors);
end;
$$;

create function private.roster_apply(p_rows jsonb, p_revision text) returns jsonb
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
    and (t.name <> r.value->>'team' or not (r.value->>'representative')::boolean);

  insert into public.members (name, email, team_id)
  select r.value->>'name', r.value->>'email', t.id
  from jsonb_array_elements(preview->'rows') r join public.teams t on t.name = r.value->>'team'
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

create function private.manage_roster(p_action text, p_payload jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor_id uuid;
  target_id uuid;
  destination_id uuid;
  new_representative_id uuid;
  new_name text := btrim(p_payload->>'name');
  new_order integer;
  new_active boolean;
  details jsonb := '{}'::jsonb;
begin
  perform private.require_staff();
  perform id from public.event_settings where id for update;
  actor_id := private.require_staff();

  if p_action in ('create_team', 'update_team', 'update_member') and (
    jsonb_typeof(p_payload->'name') is distinct from 'string' or char_length(new_name) not between 1 and 100
  ) then
    raise exception '이름은 1~100자로 입력해 주세요.' using errcode = '22023';
  end if;

  if p_action in ('create_team', 'update_team') and p_payload->>'presentation_order' is not null then
    if jsonb_typeof(p_payload->'presentation_order') <> 'number' or p_payload->>'presentation_order' !~ '^[1-9][0-9]{0,2}$'
      or (p_payload->>'presentation_order')::numeric > 200 then
      raise exception '발표 순서는 1~200 사이의 정수로 입력해 주세요.' using errcode = '22023';
    end if;
    new_order := (p_payload->>'presentation_order')::integer;
  end if;

  if p_action <> 'create_team' then target_id := (p_payload->>'id')::uuid; end if;

  case p_action
    when 'create_team' then
      insert into public.teams (name, presentation_order) values (new_name, new_order) returning id into target_id;
    when 'update_team' then
      update public.teams set name = new_name, presentation_order = new_order where id = target_id;
      if not found then raise exception '팀을 찾을 수 없습니다.' using errcode = '22023'; end if;
    when 'update_member' then
      if jsonb_typeof(p_payload->'active') is distinct from 'boolean' then
        raise exception '참가 상태를 확인해 주세요.' using errcode = '22023';
      end if;
      destination_id := (p_payload->>'team_id')::uuid;
      new_active := (p_payload->>'active')::boolean;
      if not exists (select 1 from public.members where id = target_id and role = 'participant') then
        raise exception '수정할 참가자를 찾을 수 없습니다.' using errcode = '22023';
      end if;
      update public.teams set representative_id = null
      where teams.representative_id = target_id and (not new_active or id is distinct from destination_id);
      update public.members set name = new_name, team_id = destination_id, active = new_active where id = target_id and role = 'participant';
      details := jsonb_build_object('team_id', destination_id, 'active', new_active);
    when 'set_representative' then
      new_representative_id := (p_payload->>'representative_id')::uuid;
      if new_representative_id is not null and not exists (
        select 1 from public.members m where m.id = new_representative_id and m.representative_team_id = target_id
      ) then
        raise exception '대표자는 해당 팀의 활성 참가자여야 합니다.' using errcode = '22023';
      end if;
      update public.teams set representative_id = new_representative_id where id = target_id;
      if not found then raise exception '팀을 찾을 수 없습니다.' using errcode = '22023'; end if;
      details := jsonb_build_object('representative_id', new_representative_id);
    else
      raise exception '지원하지 않는 명단 변경입니다.' using errcode = '22023';
  end case;
  insert into public.audit_logs (actor_id, action, target_id, details) values (actor_id, p_action, target_id, details);
exception
  when unique_violation then raise exception '이미 사용 중인 팀 이름입니다.' using errcode = '22023';
  when foreign_key_violation or invalid_text_representation then raise exception '선택한 팀 또는 참가자를 확인해 주세요.' using errcode = '22023';
end;
$$;

create function public.bind_member() returns jsonb
language sql security invoker set search_path = '' as $$ select private.bind_member() $$;
create function public.get_my_team() returns jsonb
language sql stable security invoker set search_path = '' as $$ select private.get_my_team() $$;
create function public.roster_preview(p_rows jsonb) returns jsonb
language sql stable security invoker set search_path = '' as $$ select private.roster_preview(p_rows) $$;
create function public.roster_apply(p_rows jsonb, p_revision text) returns jsonb
language sql security invoker set search_path = '' as $$ select private.roster_apply(p_rows, p_revision) $$;
create function public.manage_roster(p_action text, p_payload jsonb) returns void
language sql security invoker set search_path = '' as $$ select private.manage_roster(p_action, p_payload) $$;

revoke all on all functions in schema private from public, anon, authenticated;
revoke all on function public.bind_member(), public.get_my_team(), public.roster_preview(jsonb),
  public.roster_apply(jsonb, text), public.manage_roster(text, jsonb) from public, anon, authenticated;
grant execute on function public.bind_member(), public.get_my_team(), public.roster_preview(jsonb),
  public.roster_apply(jsonb, text), public.manage_roster(text, jsonb) to authenticated;
grant execute on function private.current_member(), private.bind_member(), private.get_my_team(), private.roster_preview(jsonb),
  private.roster_apply(jsonb, text), private.manage_roster(text, jsonb) to authenticated;

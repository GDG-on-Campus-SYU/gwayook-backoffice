create function private.assign_team_members(p_team_id uuid, p_members jsonb, p_confirm_move boolean default false) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  actor_id uuid;
  member_ids uuid[];
  changed_ids uuid[];
  changed_count integer;
begin
  perform private.require_staff();
  -- Use the same lock as imports, individual edits and staff permission changes.
  perform id from public.event_settings where id for update;
  actor_id := private.require_staff();

  if p_team_id is null or not exists (select 1 from public.teams where id = p_team_id) then
    raise exception '추가할 팀을 다시 선택해 주세요.' using errcode = '22023';
  end if;
  if jsonb_typeof(p_members) is distinct from 'array' then
    raise exception '추가할 참가자를 1~200명 선택해 주세요.' using errcode = '22023';
  end if;
  if jsonb_array_length(p_members) not between 1 and 200 then
    raise exception '추가할 참가자를 1~200명 선택해 주세요.' using errcode = '22023';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_members) item
    where jsonb_typeof(item) is distinct from 'object'
      or jsonb_typeof(item->'id') is distinct from 'string'
      or not (item ? 'expected_team_id')
      or jsonb_typeof(item->'expected_team_id') not in ('string', 'null')
  ) then
    raise exception '참가자 선택과 현재 팀 정보를 다시 확인해 주세요.' using errcode = '22023';
  end if;

  select array_agg(item.id) into member_ids
  from jsonb_to_recordset(p_members) as item(id uuid, expected_team_id uuid);
  if (select count(distinct id) from unnest(member_ids) id) <> cardinality(member_ids) then
    raise exception '같은 참가자를 중복 선택할 수 없습니다.' using errcode = '22023';
  end if;

  perform id from public.members where id = any(member_ids) order by id for update;
  if (select count(*) from public.members where id = any(member_ids) and active and role = 'participant') <> cardinality(member_ids) then
    raise exception '활성 참가자만 팀에 추가할 수 있습니다. 명단을 새로고침해 주세요.' using errcode = '22023';
  end if;
  -- A repeated successful request is a no-op. Any other stale team choice must be reviewed again.
  if exists (
    select 1 from public.members m
    join jsonb_to_recordset(p_members) as item(id uuid, expected_team_id uuid) on item.id = m.id
    where m.team_id is distinct from p_team_id and m.team_id is distinct from item.expected_team_id
  ) then
    raise exception '선택한 참가자의 팀이 변경되었습니다. 새로고침 후 다시 선택해 주세요.' using errcode = '22023';
  end if;
  if exists (
    select 1 from public.teams
    where representative_id = any(member_ids) and id <> p_team_id
  ) then
    raise exception '다른 팀의 대표자는 이동할 수 없습니다. 기존 팀의 대표자를 먼저 재설정해 주세요.' using errcode = '22023';
  end if;
  if not coalesce(p_confirm_move, false) and exists (
    select 1 from public.members where id = any(member_ids) and team_id is not null and team_id <> p_team_id
  ) then
    raise exception '다른 팀에 소속된 참가자의 이동을 확인해 주세요.' using errcode = '22023';
  end if;

  with changed as (
    update public.members set team_id = p_team_id
    where id = any(member_ids) and team_id is distinct from p_team_id
    returning id
  ) select count(*)::integer, array_agg(id order by id) into changed_count, changed_ids from changed;
  if changed_count > 0 then
    insert into public.audit_logs (actor_id, action, target_id, details)
    values (actor_id, 'assign_team_members', p_team_id,
      jsonb_build_object('changed_members', changed_count, 'member_ids', changed_ids));
  end if;
  return changed_count;
exception
  when invalid_text_representation then
    raise exception '선택한 참가자 또는 팀을 확인해 주세요.' using errcode = '22023';
end;
$$;

create function public.assign_team_members(p_team_id uuid, p_members jsonb, p_confirm_move boolean default false) returns integer
language sql security invoker set search_path = '' as $$
  select private.assign_team_members(p_team_id, p_members, p_confirm_move);
$$;

revoke all on function private.assign_team_members(uuid, jsonb, boolean), public.assign_team_members(uuid, jsonb, boolean) from public, anon, authenticated, service_role;
grant execute on function private.assign_team_members(uuid, jsonb, boolean), public.assign_team_members(uuid, jsonb, boolean) to authenticated;

create function private.remove_team_members(
  p_team_id uuid, p_members jsonb, p_expected_representative_id uuid, p_confirm_representative boolean default false
) returns integer language plpgsql security definer set search_path = '' as $$
declare
  actor_id uuid;
  member_ids uuid[];
  representative_id uuid;
  clears_representative boolean;
begin
  perform private.require_staff();
  -- Serialize with imports, individual edits, assignments and role changes.
  perform id from public.event_settings where id for update;
  actor_id := private.require_staff();
  select t.representative_id into representative_id from public.teams t where t.id = p_team_id for update;
  if not found then raise exception '팀을 다시 선택해 주세요.' using errcode = '22023'; end if;
  if representative_id is distinct from p_expected_representative_id then
    raise exception '팀 대표자가 변경되었습니다. 새로고침 후 다시 확인해 주세요.' using errcode = '22023';
  end if;
  if jsonb_typeof(p_members) is distinct from 'array' then
    raise exception '제거할 팀원을 1~200명 선택해 주세요.' using errcode = '22023';
  end if;
  if jsonb_array_length(p_members) not between 1 and 200 then
    raise exception '제거할 팀원을 1~200명 선택해 주세요.' using errcode = '22023';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_members) item
    where jsonb_typeof(item) is distinct from 'object'
      or jsonb_typeof(item->'id') is distinct from 'string'
      or jsonb_typeof(item->'expected_team_id') is distinct from 'string'
  ) then
    raise exception '선택한 팀원과 현재 팀 정보를 다시 확인해 주세요.' using errcode = '22023';
  end if;
  select array_agg(item.id order by item.id) into member_ids
  from jsonb_to_recordset(p_members) as item(id uuid, expected_team_id uuid);
  if (select count(distinct id) from unnest(member_ids) id) <> cardinality(member_ids) then
    raise exception '같은 팀원을 중복 선택할 수 없습니다.' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_to_recordset(p_members) as item(id uuid, expected_team_id uuid)
    where item.expected_team_id is distinct from p_team_id) then
    raise exception '선택한 팀원의 소속이 다릅니다. 새로고침 후 다시 선택해 주세요.' using errcode = '22023';
  end if;
  perform id from public.members where id = any(member_ids) order by id for update;
  if (select count(*) from public.members where id = any(member_ids) and role = 'participant' and team_id = p_team_id) <> cardinality(member_ids) then
    raise exception '선택한 팀원의 소속이 변경되었습니다. 새로고침 후 다시 선택해 주세요.' using errcode = '22023';
  end if;
  clears_representative := coalesce(representative_id = any(member_ids), false);
  if clears_representative and not coalesce(p_confirm_representative, false) then
    raise exception '대표자 지정도 해제되는 것을 확인해 주세요.' using errcode = '22023';
  end if;

  if clears_representative then
    update public.teams set representative_id = null where id = p_team_id;
  end if;
  update public.members set team_id = null where id = any(member_ids);
  insert into public.audit_logs (actor_id, action, target_id, details)
  values (actor_id, 'remove_team_members', p_team_id,
    jsonb_build_object('changed_members', cardinality(member_ids), 'member_ids', member_ids, 'representative_cleared', clears_representative));
  return cardinality(member_ids);
exception when invalid_text_representation then
  raise exception '선택한 팀원 또는 팀을 확인해 주세요.' using errcode = '22023';
end;
$$;

create function public.remove_team_members(
  p_team_id uuid, p_members jsonb, p_expected_representative_id uuid, p_confirm_representative boolean default false
) returns integer language sql security invoker set search_path = '' as $$
  select private.remove_team_members(p_team_id, p_members, p_expected_representative_id, p_confirm_representative);
$$;

revoke all on function private.remove_team_members(uuid, jsonb, uuid, boolean), public.remove_team_members(uuid, jsonb, uuid, boolean) from public, anon, authenticated, service_role;
grant execute on function private.remove_team_members(uuid, jsonb, uuid, boolean), public.remove_team_members(uuid, jsonb, uuid, boolean) to authenticated;

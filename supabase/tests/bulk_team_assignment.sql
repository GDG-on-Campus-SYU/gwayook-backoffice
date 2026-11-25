begin;

insert into auth.users (id, email, email_confirmed_at) values
  ('31000000-0000-0000-0000-000000000001', 'owner@example.test', now()),
  ('31000000-0000-0000-0000-000000000002', 'staff@example.test', now()),
  ('31000000-0000-0000-0000-000000000003', 'participant@example.test', now()),
  ('31000000-0000-0000-0000-000000000004', 'inactive-staff@example.test', now()),
  ('31000000-0000-0000-0000-000000000005', 'outsider@example.test', now());
insert into public.teams (id, name) values
  ('32000000-0000-0000-0000-000000000001', 'Team A'),
  ('32000000-0000-0000-0000-000000000002', 'Team B');
insert into public.members (id, name, email, role, auth_user_id, active, team_id) values
  ('33000000-0000-0000-0000-000000000001', 'Owner', 'owner@example.test', 'owner', '31000000-0000-0000-0000-000000000001', true, null),
  ('33000000-0000-0000-0000-000000000002', 'Staff', 'staff@example.test', 'staff', '31000000-0000-0000-0000-000000000002', true, null),
  ('33000000-0000-0000-0000-000000000003', 'Participant', 'participant@example.test', 'participant', '31000000-0000-0000-0000-000000000003', true, null),
  ('33000000-0000-0000-0000-000000000004', 'Inactive staff', 'inactive-staff@example.test', 'staff', '31000000-0000-0000-0000-000000000004', false, null),
  ('33000000-0000-0000-0000-000000000011', 'Same name', 'first@example.test', 'participant', null, true, null),
  ('33000000-0000-0000-0000-000000000012', 'Same name', 'second@example.test', 'participant', null, true, null),
  ('33000000-0000-0000-0000-000000000013', 'Other team', 'other@example.test', 'participant', null, true, '32000000-0000-0000-0000-000000000002'),
  ('33000000-0000-0000-0000-000000000014', 'Representative', 'representative@example.test', 'participant', null, true, '32000000-0000-0000-0000-000000000002'),
  ('33000000-0000-0000-0000-000000000015', 'Inactive', 'inactive@example.test', 'participant', null, false, null),
  ('33000000-0000-0000-0000-000000000016', 'Already assigned', 'already@example.test', 'participant', null, true, '32000000-0000-0000-0000-000000000001');
update public.teams set representative_id = '33000000-0000-0000-0000-000000000014'
where id = '32000000-0000-0000-0000-000000000002';

\ir fixtures/consented-members.sql
select pg_temp.consent_fixture_members('{"team":false,"presentation":false,"bingo":false}');

set local role authenticated;
do $$
declare
  destination constant uuid := '32000000-0000-0000-0000-000000000001';
  source_team constant uuid := '32000000-0000-0000-0000-000000000002';
  original_settings jsonb;
  preview jsonb;
  selection jsonb := '[{"id":"33000000-0000-0000-0000-000000000011","expected_team_id":null},{"id":"33000000-0000-0000-0000-000000000012","expected_team_id":null},{"id":"33000000-0000-0000-0000-000000000016","expected_team_id":"32000000-0000-0000-0000-000000000001"}]';
  free_member jsonb := '[{"id":"33000000-0000-0000-0000-000000000003","expected_team_id":null}]';
  moving_member jsonb := '[{"id":"33000000-0000-0000-0000-000000000013","expected_team_id":"32000000-0000-0000-0000-000000000002"}]';
  invalid_selection jsonb;
  denied_user text;
begin
  if has_function_privilege('anon', 'public.assign_team_members(uuid,jsonb,boolean)', 'execute')
    or has_function_privilege('anon', 'private.assign_team_members(uuid,jsonb,boolean)', 'execute')
    or has_function_privilege('service_role', 'public.assign_team_members(uuid,jsonb,boolean)', 'execute')
    or has_function_privilege('service_role', 'private.assign_team_members(uuid,jsonb,boolean)', 'execute')
    or has_table_privilege('authenticated', 'public.members', 'update') then
    raise exception 'bulk assignment exposed anonymous or direct writes';
  end if;
  foreach denied_user in array array[
    '31000000-0000-0000-0000-000000000003',
    '31000000-0000-0000-0000-000000000004',
    '31000000-0000-0000-0000-000000000005'
  ] loop
    perform set_config('request.jwt.claim.sub', denied_user, true);
    begin
      perform public.assign_team_members(destination, selection);
      raise exception 'participant, inactive staff or outsider assigned members';
    exception when insufficient_privilege then null;
    end;
  end loop;

  perform set_config('request.jwt.claim.sub', '31000000-0000-0000-0000-000000000002', true);
  select to_jsonb(e) into original_settings from public.event_settings e;
  preview := public.roster_preview('[{"name":"Same name","email":"first@example.test"}]');
  if public.assign_team_members(destination, selection) <> 2 then
    raise exception 'two unassigned members and same-team no-op not handled';
  end if;
  if (select count(*) from jsonb_populate_recordset(null::public.members,public.get_staff_members('participants')) where team_id = destination) <> 3 then
    raise exception 'bulk assignment did not update selected participants';
  end if;
  if public.assign_team_members(destination, selection) <> 0 then raise exception 'repeated assignment was not a no-op'; end if;
  -- Inspect persisted audit state as the fixture owner; clients use logged RPCs.
  reset role;
  if (select count(*) from public.audit_logs where action = 'assign_team_members') <> 1 then
    raise exception 'repeated request was not an unaudited no-op';
  end if;
  set local role authenticated;
  preview := public.roster_apply('[{"name":"Same name","email":"first@example.test"}]', preview->>'revision');
  if preview->'errors' = '[]'::jsonb then raise exception 'bulk assignment did not invalidate prior import preview'; end if;

  begin
    perform public.assign_team_members(destination, free_member || moving_member);
    raise exception 'other-team move accepted without confirmation';
  exception when invalid_parameter_value then null;
  end;
  for invalid_selection in select value from jsonb_array_elements(jsonb_build_array(
    free_member || '[{"id":"33000000-0000-0000-0000-000000000014","expected_team_id":"32000000-0000-0000-0000-000000000002"}]'::jsonb,
    free_member || '[{"id":"33000000-0000-0000-0000-000000000015","expected_team_id":null}]'::jsonb,
    free_member || '[{"id":"33000000-0000-0000-0000-000000000002","expected_team_id":null}]'::jsonb,
    free_member || '[{"id":"33000000-0000-0000-0000-000000000099","expected_team_id":null}]'::jsonb,
    free_member || '[{"id":"33000000-0000-0000-0000-000000000013","expected_team_id":null}]'::jsonb,
    free_member || free_member,
    '[{"id":"not-a-uuid","expected_team_id":null}]'::jsonb,
    '[{"id":"33000000-0000-0000-0000-000000000003"}]'::jsonb,
    '[{"id":"33000000-0000-0000-0000-000000000003","expected_team_id":"not-a-uuid"}]'::jsonb,
    '[null]'::jsonb, '[]'::jsonb, 'null'::jsonb, '{}'::jsonb,
    (select jsonb_agg(free_member->0) from generate_series(1,201))
  )) loop
    begin
      perform public.assign_team_members(destination, invalid_selection, true);
      raise exception 'invalid bulk assignment accepted: %', invalid_selection;
    exception when invalid_parameter_value then null;
    end;
  end loop;
  begin
    perform public.assign_team_members('32000000-0000-0000-0000-000000000099', free_member);
    raise exception 'unknown destination accepted';
  exception when invalid_parameter_value then null;
  end;
  -- Inspect persisted audit state as the fixture owner; clients use logged RPCs.
  reset role;
  if (select team_id from jsonb_populate_recordset(null::public.members,public.get_staff_members('participants')) where id = '33000000-0000-0000-0000-000000000003') is not null
    or (select team_id from jsonb_populate_recordset(null::public.members,public.get_staff_members('participants')) where id = '33000000-0000-0000-0000-000000000013') is distinct from source_team
    or (select representative_id from public.teams where id = source_team) is distinct from '33000000-0000-0000-0000-000000000014'::uuid
    or (select count(*) from public.audit_logs where action = 'assign_team_members') <> 1 then
    raise exception 'failed batch partially changed members, representative or audit';
  end if;
  set local role authenticated;

  if public.assign_team_members(destination, free_member || moving_member, true) <> 2 then
    raise exception 'explicitly confirmed multi-member move failed';
  end if;
  perform set_config('request.jwt.claim.sub', '31000000-0000-0000-0000-000000000001', true);
  if public.assign_team_members(source_team, '[{"id":"33000000-0000-0000-0000-000000000014","expected_team_id":"32000000-0000-0000-0000-000000000002"}]') <> 0 then
    raise exception 'owner same-team representative no-op failed';
  end if;
  -- Inspect persisted audit state as the fixture owner; clients use logged RPCs.
  reset role;
  if not exists (select 1 from jsonb_populate_recordset(null::public.members,public.get_staff_members('participants')) where id = '33000000-0000-0000-0000-000000000003'
      and name = 'Participant' and email = 'participant@example.test' and active and role = 'participant'
      and auth_user_id = '31000000-0000-0000-0000-000000000003' and team_id = destination)
    or (select to_jsonb(e) from public.event_settings e) is distinct from original_settings
    or (select representative_id from public.teams where id = source_team) is distinct from '33000000-0000-0000-0000-000000000014'::uuid
    or exists (select 1 from public.audit_logs where action = 'assign_team_members' and details::text like '%@%') then
    raise exception 'assignment changed account, event or representative data or logged email';
  end if;
  set local role authenticated;
end;
$$;

select '1..1' as tap;
select 'ok 1 - atomic bulk team assignment, role guards, confirmation, stale selections and representative preservation' as tap;
rollback;

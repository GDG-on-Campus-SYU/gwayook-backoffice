begin;

insert into auth.users (id, email) values
  ('60000000-0000-0000-0000-000000000001', 'settings-owner@example.test'),
  ('60000000-0000-0000-0000-000000000002', 'settings-staff@example.test');
insert into public.teams (id, name) values
  ('60000000-0000-0000-0000-000000000003', 'Settings Team A'),
  ('60000000-0000-0000-0000-000000000004', 'Settings Team B');
insert into public.members (name, email, role, auth_user_id, team_id) values
  ('Settings Owner', 'settings-owner@example.test', 'owner', '60000000-0000-0000-0000-000000000001', null),
  ('Settings Staff', 'settings-staff@example.test', 'staff', '60000000-0000-0000-0000-000000000002', null),
  ('Settings Voter', 'settings-voter@example.test', 'participant', null, '60000000-0000-0000-0000-000000000003');
insert into private.participant_operations(member_id,attendance_status,checked_in_at)
select id,'present',now() from public.members where email='settings-voter@example.test';

\ir fixtures/consented-members.sql
select pg_temp.consent_fixture_members('{"team":false,"presentation":false,"bingo":false}');

set local role authenticated;
do $$
declare
  deadline constant timestamptz := clock_timestamp() + interval '1 hour';
  owner_id uuid;
  staff_id uuid;
  previous_submission_deadline timestamptz;
begin
  if has_function_privilege('anon', 'public.save_event_settings(jsonb)', 'execute')
    or has_table_privilege('authenticated', 'public.event_settings', 'update') then
    raise exception 'unexpected settings write grant';
  end if;

  perform set_config('request.jwt.claim.sub', '60000000-0000-0000-0000-000000000002', true);
  begin
    perform public.save_event_settings('{"name":"Unauthorized","event_date":"2026-11-25"}');
    raise exception 'staff changed settings';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.save_event_staff(null, 'Unauthorized', 'unauthorized@example.test', null);
    raise exception 'staff added a staff account';
  exception when insufficient_privilege then null;
  end;

  perform set_config('request.jwt.claim.sub', '60000000-0000-0000-0000-000000000001', true);
  select id into strict owner_id from jsonb_populate_recordset(null::public.members,public.get_staff_members('staff')) where email = 'settings-owner@example.test';
  select id into strict staff_id from jsonb_populate_recordset(null::public.members,public.get_staff_members('staff')) where email = 'settings-staff@example.test';
  select submission_deadline into previous_submission_deadline from public.event_settings;
  perform public.save_event_staff(null, 'New Staff', 'NEW-STAFF@example.test', null);
  if not exists (select 1 from jsonb_populate_recordset(null::public.members,public.get_staff_members('staff')) where email = 'new-staff@example.test' and role = 'staff' and active) then
    raise exception 'owner could not add staff';
  end if;
  begin
    perform public.save_event_staff(owner_id, null, null, false);
    raise exception 'owner account was deactivated through staff controls';
  exception when invalid_parameter_value then null;
  end;
  perform public.save_event_staff(staff_id, null, null, false);
  if (select active from jsonb_populate_recordset(null::public.members,public.get_staff_members('staff')) where id = staff_id) is distinct from false then
    raise exception 'owner could not deactivate staff';
  end if;
  perform public.save_event_staff(staff_id, null, null, true);
  if (select active from jsonb_populate_recordset(null::public.members,public.get_staff_members('staff')) where id = staff_id) is distinct from true then
    raise exception 'owner could not reactivate staff';
  end if;

  begin
    perform public.save_event_settings('{"event_starts_at":"2026-11-24T15:00:00+09:00","event_ends_at":"2026-11-24T14:00:00+09:00"}');
    raise exception 'invalid event date order was accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.save_event_settings('{"name":"Rejected","event_date":"2026-02-29"}');
    raise exception 'invalid calendar date was accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.save_event_settings('{"event_date":null}');
    raise exception 'null event date was accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.save_event_settings('{"name":"   "}');
    raise exception 'blank event name was accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.save_event_settings('{"submission_deadline":"infinity"}');
    raise exception 'unbounded schedule time was accepted';
  exception when invalid_parameter_value then null;
  end;
  perform public.save_event_settings('{"name":"  Settings Test Event  ","event_date":"2026-12-01"}');
  if not exists (select 1 from public.event_settings where name = 'Settings Test Event' and event_date = '2026-12-01' and submission_deadline is not distinct from previous_submission_deadline) then
    raise exception 'setting event name and date changed other fields or did not persist';
  end if;
  perform public.save_event_settings(jsonb_build_object('vote_closes_at', deadline, 'notice', ' Test notice '));
  if not exists (select 1 from public.event_settings where notice = 'Test notice' and vote_closes_at = deadline) then
    raise exception 'owner settings were not saved';
  end if;
  perform public.manage_vote('open', array[
    '60000000-0000-0000-0000-000000000003'::uuid,
    '60000000-0000-0000-0000-000000000004'::uuid
  ]);
  begin
    perform public.save_event_settings('{"vote_closes_at":null}');
    raise exception 'active vote deadline was changed';
  exception when invalid_parameter_value then null;
  end;
  perform public.save_event_settings('{"contact":"Test contact","event_date":"2026-12-02"}');
  if not exists (select 1 from public.event_settings where contact = 'Test contact' and event_date = '2026-12-02' and vote_closes_at = deadline) then
    raise exception 'partial settings update changed vote deadline';
  end if;
  -- Inspect persisted audit state as the fixture owner; clients use logged RPCs.
  reset role;
  if not exists (select 1 from public.audit_logs where actor_id = owner_id and action = 'staff_deactivate' and target_id = staff_id)
    or not exists (select 1 from public.audit_logs where actor_id = owner_id and action = 'event_settings') then
    raise exception 'owner settings change was not audited';
  end if;
  set local role authenticated;
end;
$$;

select '1..1' as tap;
select 'ok 1 - event settings, staff controls and active vote cutoff' as tap;
rollback;

begin;

insert into auth.users (id, email, email_confirmed_at) values
  ('21000000-0000-0000-0000-000000000001', 'owner@example.test', now()),
  ('21000000-0000-0000-0000-000000000002', 'staff@example.test', now()),
  ('21000000-0000-0000-0000-000000000003', 'original@example.test', now()),
  ('21000000-0000-0000-0000-000000000004', 'corrected@example.test', now());
insert into auth.identities (provider_id, user_id, provider, identity_data) values
  ('original', '21000000-0000-0000-0000-000000000003', 'google', '{"email":"original@example.test","email_verified":true}'),
  ('corrected', '21000000-0000-0000-0000-000000000004', 'google', '{"email":"corrected@example.test","email_verified":true}');
insert into public.members (name, email, role, auth_user_id) values
  ('Owner', 'owner@example.test', 'owner', '21000000-0000-0000-0000-000000000001'),
  ('Staff', 'staff@example.test', 'staff', '21000000-0000-0000-0000-000000000002');
insert into public.teams (id, name) values ('21000000-0000-0000-0000-000000000005', 'Team');

\ir fixtures/consented-members.sql
select pg_temp.consent_fixture_members('{"team":false,"presentation":false,"bingo":false}');

set local role authenticated;
do $$
<<member_registration>>
declare
  team_id constant uuid := '21000000-0000-0000-0000-000000000005';
  member_id uuid;
  roster jsonb := '[{"name":"Participant","email":"original@example.test","team":"Team"}]';
  preview jsonb;
  edit jsonb;
begin
  if has_function_privilege('anon', 'private.manage_participant_registration(text, jsonb)', 'execute')
    or has_function_privilege('anon', 'public.manage_roster(text, jsonb)', 'execute')
    or has_table_privilege('authenticated', 'public.members', 'update') then
    raise exception 'unexpected access to participant mutations';
  end if;

  perform set_config('request.jwt.claim.sub', '21000000-0000-0000-0000-000000000002', true);
  perform public.manage_roster('create_member', '{"name":" Unassigned ","email":" Unassigned@EXAMPLE.TEST " ,"role":"owner"}');
  if not exists (select 1 from jsonb_populate_recordset(null::public.members,public.get_staff_members('participants')) m where m.email = 'unassigned@example.test'
    and m.name = 'Unassigned' and m.role = 'participant' and m.team_id is null and m.active) then
    raise exception 'manual registration did not normalize values or guard the participant role';
  end if;

  begin
    perform public.manage_roster('create_member', '{"name":"Duplicate","email":"OWNER@EXAMPLE.TEST"}');
    raise exception 'duplicate staff email allowed in manual registration';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.manage_roster('create_member', '{"name":"Invalid","email":"invalid"}');
    raise exception 'invalid email allowed in manual registration';
  exception when invalid_parameter_value then null;
  end;

  perform public.manage_roster('create_member', jsonb_build_object('name', 'Participant', 'email', 'typo@example.test', 'team_id', team_id));
  select id into strict member_id from jsonb_populate_recordset(null::public.members,public.get_staff_members('participants')) where email = 'typo@example.test';
  perform public.manage_roster('set_representative', jsonb_build_object('id', team_id, 'representative_id', member_id));

  edit := jsonb_build_object('id', member_id, 'expected_email', 'typo@example.test', 'email', ' Original@Example.Test ', 'confirm_disconnect', false);
  perform public.manage_roster('update_member_email', edit);
  if not exists (select 1 from jsonb_populate_recordset(null::public.members,public.get_staff_members('participants')) m where m.id = member_id and m.email = 'original@example.test'
    and m.team_id = member_registration.team_id and m.active and m.auth_user_id is null) then
    raise exception 'staff could not correct an unlinked participant in place';
  end if;
  begin
    perform public.manage_roster('update_member_email', edit || '{"email":"stale@example.test"}');
    raise exception 'stale expected email did not prevent a write';
  exception when invalid_parameter_value then null;
  end;

  perform set_config('request.jwt.claim.sub', '21000000-0000-0000-0000-000000000003', true);
  if public.bind_member()->>'id' is distinct from member_id::text then
    raise exception 'corrected unlinked email did not bind on verified Google login';
  end if;
  perform public.save_my_consents('2026-11-16.1',true,'{"team":false,"presentation":false,"bingo":false}');
  begin
    perform public.manage_roster('create_member', '{"name":"Unauthorized","email":"unauthorized@example.test"}');
    raise exception 'participant can register another participant';
  exception when insufficient_privilege then null;
  end;

  edit := jsonb_build_object('id', member_id, 'expected_email', 'original@example.test', 'email', 'corrected@example.test', 'confirm_disconnect', false);
  perform set_config('request.jwt.claim.sub', '21000000-0000-0000-0000-000000000002', true);
  begin
    perform public.manage_roster('update_member_email', edit || '{"confirm_disconnect":true}');
    raise exception 'staff can disconnect a linked participant';
  exception when insufficient_privilege then null;
  end;

  perform set_config('request.jwt.claim.sub', '21000000-0000-0000-0000-000000000001', true);
  begin
    perform public.manage_roster('update_member_email', edit);
    raise exception 'owner disconnected a linked participant without confirmation';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.manage_roster('update_member_email', edit || '{"email":"staff@example.test","confirm_disconnect":true}');
    raise exception 'email correction can collide with another member';
  exception when invalid_parameter_value then null;
  end;
  if not exists (select 1 from jsonb_populate_recordset(null::public.members,public.get_staff_members('participants')) where id = member_id and email = 'original@example.test'
    and auth_user_id = '21000000-0000-0000-0000-000000000003') then
    raise exception 'failed corrections changed the previous binding';
  end if;

  preview := public.roster_preview(roster);
  perform public.manage_roster('update_member_email', edit || '{"confirm_disconnect":true}');
  preview := public.roster_apply(roster, preview->>'revision');
  if preview->'errors' = '[]'::jsonb or exists (select 1 from jsonb_populate_recordset(null::public.members,public.get_staff_members('participants')) where email = 'original@example.test') then
    raise exception 'an import preview predating an email correction could reinsert the old email';
  end if;
  if not exists (select 1 from jsonb_populate_recordset(null::public.members,public.get_staff_members('participants')) m where m.id = member_id and m.email = 'corrected@example.test'
    and m.team_id = member_registration.team_id and m.active and m.auth_user_id is null)
    or not exists (select 1 from public.teams where id = member_registration.team_id and representative_id = member_id) then
    raise exception 'correcting a linked representative changed their identity, status, team, or representative role';
  end if;
  if (select count(*) from jsonb_array_elements(public.get_audit_entries()) e where e->>'action'='update_member_email') <> 2
    or exists(select 1 from jsonb_array_elements(public.get_audit_entries()) e where e ? 'details' or e ? 'target_id') then
    raise exception 'logged owner audit projection changed';
  end if;
  -- Inspect persisted audit state as the fixture owner; clients use logged RPCs.
  reset role;
  if (select count(*) from public.audit_logs where target_id = member_id and action = 'update_member_email') <> 2
    or not exists (select 1 from public.audit_logs where target_id = member_id and action = 'update_member_email'
      and details = '{"disconnected":true}'::jsonb)
    or exists (select 1 from public.audit_logs where target_id = member_id and details::text like '%@%') then
    raise exception 'audit must track successful email corrections without email addresses';
  end if;
  set local role authenticated;

  perform set_config('request.jwt.claim.sub', '21000000-0000-0000-0000-000000000003', true);
  if public.bind_member() is not null or exists (select 1 from public.members) then
    raise exception 'previous Google account retained roster access';
  end if;
  perform set_config('request.jwt.claim.sub', '21000000-0000-0000-0000-000000000004', true);
  if public.bind_member()->>'id' is distinct from member_id::text then
    raise exception 'new verified Google account did not bind to the existing participant';
  end if;
  if (public.get_my_consents()->>'terms')::boolean or public.get_my_team() is not null then
    raise exception 'new account inherited the previous account consent';
  end if;
end;
$$;

select '1..1' as tap;
select 'ok 1 - manual registration, guarded email correction, account rebind and roster integrity' as tap;
rollback;

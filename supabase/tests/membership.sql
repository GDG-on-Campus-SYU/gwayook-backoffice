begin;

insert into auth.users (id, email, email_confirmed_at) values
  ('20000000-0000-0000-0000-000000000001', 'owner@example.test', now()),
  ('20000000-0000-0000-0000-000000000002', 'first@example.test', now()),
  ('20000000-0000-0000-0000-000000000003', 'outsider@example.test', now()),
  ('20000000-0000-0000-0000-000000000004', 'unverified@example.test', now());
insert into auth.identities (provider_id, user_id, provider, identity_data) values
  ('owner', '20000000-0000-0000-0000-000000000001', 'google', '{"email":"owner@example.test","email_verified":true}'),
  ('first', '20000000-0000-0000-0000-000000000002', 'google', '{"email":"first@example.test","email_verified":true}'),
  ('outsider', '20000000-0000-0000-0000-000000000003', 'google', '{"email":"outsider@example.test","email_verified":true}'),
  ('unverified', '20000000-0000-0000-0000-000000000004', 'google', '{"email":"unverified@example.test","email_verified":false}');
insert into public.members (name, email, role) values
  ('Owner', 'owner@example.test', 'owner'), ('Unverified', 'unverified@example.test', 'participant');

set local role authenticated;
do $$
declare
  first_rows jsonb := '[{"row":2,"name":"First","email":" First@Example.Test ","team":"One","representative":true},{"row":3,"name":"Second","email":"second@example.test","team":"One"}]';
  next_rows jsonb := '[{"name":"First Renamed","email":"first@example.test","team":"Two"}]';
  colliding_rows jsonb := '[{"name":"Third","email":"third@example.test","team":"One","representative":true}]';
  no_team_rows jsonb := '[
    {"name":"First","email":"first@example.test","team":" \t\n "},
    {"name":"Second Renamed","email":"second@example.test"},
    {"name":"New","email":"new@example.test","team":null}
  ]';
  preview jsonb;
  team_one uuid;
  team_two uuid;
  first_id uuid;
  second_id uuid;
begin
  if has_function_privilege('anon', 'public.bind_member()', 'execute')
    or has_table_privilege('authenticated', 'public.members', 'insert') then
    raise exception 'unexpected direct write or anonymous grant';
  end if;

  perform set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000003', true);
  if public.bind_member() is not null or exists (select 1 from public.event_settings) then
    raise exception 'verified Google outsider received membership or event access';
  end if;
  perform set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000004', true);
  if public.bind_member() is not null then raise exception 'unverified identity bound'; end if;

  perform set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000001', true);
  if public.bind_member()->>'role' is distinct from 'owner' then raise exception 'listed owner did not bind'; end if;
  perform public.save_my_consents('2026-11-16.1',true,'{"team":false,"presentation":false,"bingo":false}');
  preview := public.roster_preview(first_rows || first_rows);
  if jsonb_array_length(preview->'errors') <> 2 then raise exception 'duplicate email check failed'; end if;
  preview := public.roster_preview('[{"name":"Owner","email":"owner@example.test","team":"One"}]');
  if jsonb_array_length(preview->'errors') <> 1 then raise exception 'owner collision was allowed'; end if;
  preview := public.roster_preview(first_rows);
  if jsonb_array_length(preview->'errors') <> 0 or preview->'rows'->0->>'action' is distinct from 'insert' then
    raise exception 'initial preview failed: %', preview;
  end if;
  if exists (select 1 from public.teams) then raise exception 'preview wrote teams'; end if;
  preview := public.roster_apply(first_rows, preview->>'revision');
  if jsonb_array_length(preview->'errors') <> 0 then raise exception 'initial apply failed: %', preview; end if;

  select id, representative_id into team_one, first_id from public.teams where name = 'One';
  select id into second_id from jsonb_populate_recordset(null::public.members,public.get_staff_members('participants')) where email = 'second@example.test';
  if first_id is null or second_id is null or team_one is null then raise exception 'import did not create team, roster and representative'; end if;

  preview := public.roster_preview(first_rows);
  if exists (select 1 from jsonb_array_elements(preview->'rows') where value->>'action' <> 'unchanged') then
    raise exception 'same import is not idempotent';
  end if;
  preview := public.roster_preview(colliding_rows);
  if jsonb_array_length(preview->'errors') <> 1 then raise exception 'existing representative collision was allowed'; end if;

  preview := public.roster_preview('[{"name":"New","email":"new@example.test","representative":true}]');
  if jsonb_array_length(preview->'errors') <> 1 then raise exception 'unassigned representative was allowed'; end if;

  preview := public.roster_preview(no_team_rows);
  if preview->'errors' <> '[]'::jsonb or preview->'new_teams' <> '[]'::jsonb
    or preview->'rows'->0->>'action' is distinct from 'unchanged'
    or preview->'rows'->1->>'team' is distinct from 'One'
    or preview->'rows'->2->'team' is distinct from 'null'::jsonb then
    raise exception 'team-optional preview failed: %', preview;
  end if;
  preview := public.roster_apply(no_team_rows, preview->>'revision');
  if preview->'errors' <> '[]'::jsonb
    or not exists (select 1 from public.teams where id = team_one and representative_id = first_id)
    or not exists (select 1 from jsonb_populate_recordset(null::public.members,public.get_staff_members('participants')) where id = second_id and team_id = team_one and name = 'Second Renamed')
    or not exists (select 1 from jsonb_populate_recordset(null::public.members,public.get_staff_members('participants')) where email = 'new@example.test' and team_id is null)
    or (select count(*) from public.teams) <> 1 then
    raise exception 'team-optional apply failed: %', preview;
  end if;
  preview := public.roster_preview(no_team_rows);
  if exists (select 1 from jsonb_array_elements(preview->'rows') where value->>'action' <> 'unchanged') then
    raise exception 'team-optional re-import is not idempotent';
  end if;

  perform public.manage_roster('create_team', '{"name":"Two","presentation_order":2}');
  select id into team_two from public.teams where name = 'Two';
  begin
    perform public.manage_roster('set_representative', jsonb_build_object('id', team_two, 'representative_id', first_id));
    raise exception 'representative from another team allowed';
  exception when invalid_parameter_value then null;
  end;

  preview := public.roster_preview(next_rows);
  perform public.manage_roster('set_representative', jsonb_build_object('id', team_one, 'representative_id', second_id));
  preview := public.roster_apply(next_rows, preview->>'revision');
  if jsonb_array_length(preview->'errors') <> 1 or not exists (
    select 1 from jsonb_populate_recordset(null::public.members,public.get_staff_members('participants')) where id = first_id and name = 'First' and team_id = team_one
  ) then raise exception 'stale import was applied'; end if;
  perform public.manage_roster('set_representative', jsonb_build_object('id', team_one, 'representative_id', first_id));
  preview := public.roster_preview(next_rows);
  preview := public.roster_apply(next_rows, preview->>'revision');
  if jsonb_array_length(preview->'errors') <> 0 or exists (
    select 1 from public.teams where id = team_one and representative_id is not null
  ) or not exists (select 1 from jsonb_populate_recordset(null::public.members,public.get_staff_members('participants')) where id = second_id and team_id = team_one) then
    raise exception 'moving a representative did not clear their role or changed absent participants';
  end if;

  perform set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  if public.bind_member()->>'id' is distinct from first_id::text then raise exception 'participant bind failed'; end if;
  perform public.save_my_consents('2026-11-16.1',true,'{"team":false,"presentation":false,"bingo":false}');
  if public.get_my_team()->>'id' is distinct from team_two::text or (select count(*) from public.members) <> 1 then
    raise exception 'participant row access failed';
  end if;
  begin
    perform public.roster_preview(first_rows);
    raise exception 'participant can preview roster';
  exception when insufficient_privilege then null;
  end;

  perform set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000001', true);
  perform public.manage_roster('set_representative', jsonb_build_object('id', team_two, 'representative_id', first_id));
  perform public.manage_roster('update_member', jsonb_build_object('id', first_id, 'name', 'First', 'team_id', team_two, 'active', false));
  if exists (select 1 from public.teams where id = team_two and representative_id is not null) then
    raise exception 'deactivation left representative';
  end if;
  perform set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-000000000002', true);
  if public.bind_member() is not null or public.get_my_team() is not null or exists (select 1 from public.members) then
    raise exception 'deactivated participant retained access';
  end if;
end;
$$;

select '1..1' as tap;
select 'ok 1 - membership, representative, import and access invariants' as tap;
rollback;

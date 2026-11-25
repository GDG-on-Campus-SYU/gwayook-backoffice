begin;

insert into auth.users (id, email, email_confirmed_at) values
  ('61000000-0000-0000-0000-000000000001', 'remove-owner@example.test', now()),
  ('61000000-0000-0000-0000-000000000002', 'remove-staff@example.test', now()),
  ('61000000-0000-0000-0000-000000000003', 'remove-participant@example.test', now()),
  ('61000000-0000-0000-0000-000000000004', 'remove-inactive-staff@example.test', now()),
  ('61000000-0000-0000-0000-000000000005', 'remove-outsider@example.test', now());
insert into public.teams (id, name) values
  ('62000000-0000-0000-0000-000000000001', 'Removal A'),
  ('62000000-0000-0000-0000-000000000002', 'Removal B'),
  ('62000000-0000-0000-0000-000000000003', 'Removal C');
insert into public.members (id, name, email, role, auth_user_id, active, team_id) values
  ('63000000-0000-0000-0000-000000000001', 'Owner', 'remove-owner@example.test', 'owner', '61000000-0000-0000-0000-000000000001', true, null),
  ('63000000-0000-0000-0000-000000000002', 'Staff', 'remove-staff@example.test', 'staff', '61000000-0000-0000-0000-000000000002', true, null),
  ('63000000-0000-0000-0000-000000000003', 'Participant', 'remove-participant@example.test', 'participant', '61000000-0000-0000-0000-000000000003', true, '62000000-0000-0000-0000-000000000001'),
  ('63000000-0000-0000-0000-000000000004', 'Inactive staff', 'remove-inactive-staff@example.test', 'staff', '61000000-0000-0000-0000-000000000004', false, null),
  ('63000000-0000-0000-0000-000000000011', 'Representative A', 'remove-rep-a@example.test', 'participant', null, true, '62000000-0000-0000-0000-000000000001'),
  ('63000000-0000-0000-0000-000000000012', 'Inactive participant', 'remove-inactive@example.test', 'participant', null, false, '62000000-0000-0000-0000-000000000001'),
  ('63000000-0000-0000-0000-000000000013', 'Representative B', 'remove-rep-b@example.test', 'participant', null, true, '62000000-0000-0000-0000-000000000002');
update public.teams set representative_id = '63000000-0000-0000-0000-000000000011' where id = '62000000-0000-0000-0000-000000000001';
update public.teams set representative_id = '63000000-0000-0000-0000-000000000013' where id = '62000000-0000-0000-0000-000000000002';

-- Historical records remain valid when their member is no longer on that team.
insert into private.vote_candidates (team_id, name) select id, name from public.teams;
insert into private.vote_eligibility (member_id, team_id) values ('63000000-0000-0000-0000-000000000003', '62000000-0000-0000-0000-000000000001');
insert into private.votes (member_id, own_team_id, team_id) values ('63000000-0000-0000-0000-000000000003', '62000000-0000-0000-0000-000000000001', '62000000-0000-0000-0000-000000000002');
insert into private.vote_runoffs (id, main_vote_count, main_score, opens_at, closes_at, created_by) values ('64000000-0000-0000-0000-000000000001', 1, 1, now(), now() + interval '5 minutes', '63000000-0000-0000-0000-000000000001');
insert into private.runoff_candidates (runoff_id, team_id) values
  ('64000000-0000-0000-0000-000000000001', '62000000-0000-0000-0000-000000000002'),
  ('64000000-0000-0000-0000-000000000001', '62000000-0000-0000-0000-000000000003');
insert into private.runoff_eligibility (runoff_id, member_id) values ('64000000-0000-0000-0000-000000000001', '63000000-0000-0000-0000-000000000003');
insert into private.runoff_votes (runoff_id, member_id, team_id) values ('64000000-0000-0000-0000-000000000001', '63000000-0000-0000-0000-000000000003', '62000000-0000-0000-0000-000000000002');
insert into public.submissions (team_id, current_path, file_name, size_bytes, submitted_at, submitted_by, version) values ('62000000-0000-0000-0000-000000000001', 'removal-test/synthetic.pdf', 'synthetic.pdf', 1024, now(), '63000000-0000-0000-0000-000000000011', 1);
insert into private.bingo_boards (member_id, question_order) values ('63000000-0000-0000-0000-000000000003', array(select generate_series(0,24)));
insert into private.bingo_marks (member_id, cell, confirmed_by, confirmed_at) values ('63000000-0000-0000-0000-000000000003', 0, '63000000-0000-0000-0000-000000000011', now());

\ir fixtures/consented-members.sql
select pg_temp.consent_fixture_members('{"team":false,"presentation":false,"bingo":false}');

create temp table removal_preserved (name text primary key, data jsonb);
do $$
declare relation text;
begin
  foreach relation in array array['public.event_settings', 'auth.users', 'private.vote_candidates', 'private.vote_eligibility', 'private.votes', 'private.vote_runoffs', 'private.runoff_candidates', 'private.runoff_eligibility', 'private.runoff_votes', 'public.submissions', 'private.bingo_game', 'private.bingo_rounds', 'private.bingo_boards', 'private.bingo_marks'] loop
    execute format('insert into removal_preserved select %L, jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text) from %s t', relation, relation);
  end loop;
  insert into removal_preserved select 'accounts', jsonb_agg(to_jsonb(m) - 'team_id' - 'representative_team_id' order by id) from public.members m;
end;
$$;

set local role authenticated;
do $$
declare
  team constant uuid := '62000000-0000-0000-0000-000000000001';
  representative constant uuid := '63000000-0000-0000-0000-000000000011';
  selection jsonb := '[{"id":"63000000-0000-0000-0000-000000000003","expected_team_id":"62000000-0000-0000-0000-000000000001"}]';
  rep_selection jsonb := '[{"id":"63000000-0000-0000-0000-000000000011","expected_team_id":"62000000-0000-0000-0000-000000000001"}]';
  invalid_selection jsonb;
  denied_user text;
  preview jsonb;
begin
  if has_function_privilege('anon', 'public.remove_team_members(uuid,jsonb,uuid,boolean)', 'execute')
    or has_function_privilege('anon', 'private.remove_team_members(uuid,jsonb,uuid,boolean)', 'execute')
    or has_function_privilege('service_role', 'public.remove_team_members(uuid,jsonb,uuid,boolean)', 'execute')
    or has_function_privilege('service_role', 'private.remove_team_members(uuid,jsonb,uuid,boolean)', 'execute')
    or has_table_privilege('authenticated', 'public.members', 'update') then
    raise exception 'removal exposed anonymous, service or direct writes';
  end if;
  foreach denied_user in array array['', '61000000-0000-0000-0000-000000000003', '61000000-0000-0000-0000-000000000004', '61000000-0000-0000-0000-000000000005'] loop
    perform set_config('request.jwt.claim.sub', denied_user, true);
    begin
      perform public.remove_team_members(team, selection, representative);
      raise exception 'unauthorized actor removed members';
    exception when insufficient_privilege then null;
    end;
  end loop;
  perform set_config('request.jwt.claim.sub', '61000000-0000-0000-0000-000000000002', true);
  begin
    perform public.remove_team_members(team, selection || rep_selection, representative);
    raise exception 'representative removed without explicit confirmation';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.remove_team_members(team, selection, null, true);
    raise exception 'stale representative accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.remove_team_members('62000000-0000-0000-0000-000000000099', selection, null, true);
    raise exception 'missing team accepted';
  exception when invalid_parameter_value then null;
  end;
  for invalid_selection in select value from jsonb_array_elements(jsonb_build_array(
    selection || '[{"id":"63000000-0000-0000-0000-000000000013","expected_team_id":"62000000-0000-0000-0000-000000000001"}]'::jsonb,
    selection || '[{"id":"63000000-0000-0000-0000-000000000002","expected_team_id":"62000000-0000-0000-0000-000000000001"}]'::jsonb,
    selection || '[{"id":"63000000-0000-0000-0000-000000000099","expected_team_id":"62000000-0000-0000-0000-000000000001"}]'::jsonb,
    selection || selection,
    '[{"id":"63000000-0000-0000-0000-000000000003","expected_team_id":"62000000-0000-0000-0000-000000000002"}]'::jsonb,
    '[{"id":"bad","expected_team_id":"62000000-0000-0000-0000-000000000001"}]'::jsonb,
    '[{"id":"63000000-0000-0000-0000-000000000003","expected_team_id":"bad"}]'::jsonb,
    '[{"id":"63000000-0000-0000-0000-000000000003","expected_team_id":null}]'::jsonb,
    '[{"id":"63000000-0000-0000-0000-000000000003"}]'::jsonb,
    '[null]'::jsonb, '[]'::jsonb, 'null'::jsonb, '{}'::jsonb,
    (select jsonb_agg(selection->0) from generate_series(1,201))
  )) loop
    begin
      perform public.remove_team_members(team, invalid_selection, representative, true);
      raise exception 'invalid removal accepted: %', invalid_selection;
    exception when invalid_parameter_value then null;
    end;
  end loop;
  -- Inspect persisted audit state as the fixture owner; clients use logged RPCs.
  reset role;
  if (select count(*) from jsonb_populate_recordset(null::public.members,public.get_staff_members('participants')) where team_id = team) <> 3
    or (select representative_id from public.teams where id = team) is distinct from representative
    or exists (select 1 from public.audit_logs where action = 'remove_team_members') then
    raise exception 'rejected request partially changed members, representative or audit';
  end if;
  set local role authenticated;

  preview := public.roster_preview('[{"name":"Participant","email":"remove-participant@example.test"}]');
  if public.remove_team_members(team, selection || '[{"id":"63000000-0000-0000-0000-000000000012","expected_team_id":"62000000-0000-0000-0000-000000000001"}]'::jsonb, representative) <> 2 then
    raise exception 'staff could not remove active and inactive members';
  end if;
  if (select count(*) from jsonb_populate_recordset(null::public.members,public.get_staff_members('participants')) where team_id = team) <> 1
    or (select representative_id from public.teams where id = team) is distinct from representative then
    raise exception 'nonrepresentative removal changed unintended membership or representative';
  end if;
  preview := public.roster_apply('[{"name":"Participant","email":"remove-participant@example.test"}]', preview->>'revision');
  if preview->'errors' = '[]'::jsonb then raise exception 'removal did not invalidate stale import preview'; end if;
  begin
    perform public.remove_team_members(team, rep_selection || selection, representative, true);
    raise exception 'stale member accepted in representative-removal batch';
  exception when invalid_parameter_value then null;
  end;
  if (select representative_id from public.teams where id = team) is distinct from representative then
    raise exception 'stale batch partially cleared representative';
  end if;

  perform set_config('request.jwt.claim.sub', '61000000-0000-0000-0000-000000000001', true);
  if public.remove_team_members(team, rep_selection, representative, true) <> 1 then
    raise exception 'owner could not explicitly remove representative';
  end if;
  -- Inspect persisted audit state as the fixture owner; clients use logged RPCs.
  reset role;
  if exists (select 1 from jsonb_populate_recordset(null::public.members,public.get_staff_members('participants')) where team_id = team)
    or (select representative_id from public.teams where id = team) is not null
    or (select representative_id from public.teams where id = '62000000-0000-0000-0000-000000000002') is distinct from '63000000-0000-0000-0000-000000000013'::uuid
    or (select count(*) from public.audit_logs where action = 'remove_team_members') <> 2
    or exists (select 1 from public.audit_logs where action = 'remove_team_members' and details::text like '%@%') then
    raise exception 'removal affected unrelated representatives or audit';
  end if;
  set local role authenticated;
  if public.assign_team_members('62000000-0000-0000-0000-000000000002', '[{"id":"63000000-0000-0000-0000-000000000003","expected_team_id":null}]') <> 1 then
    raise exception 'removed member could not be reassigned';
  end if;
end;
$$;
reset role;

do $$
declare original record; actual jsonb;
begin
  for original in select * from removal_preserved where name <> 'accounts' loop
    execute format('select jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text) from %s t', original.name) into actual;
    if actual is distinct from original.data then raise exception 'removal changed protected history: %', original.name; end if;
  end loop;
  if (select jsonb_agg(to_jsonb(m) - 'team_id' - 'representative_team_id' order by id) from public.members m)
    is distinct from (select data from removal_preserved where name = 'accounts') then
    raise exception 'removal changed member identity, auth, active state or other account fields';
  end if;
end;
$$;
select '1..1' as tap;
select 'ok 1 - team removal role guards, atomic validation, representative confirmation, reassignment and immutable history' as tap;
rollback;

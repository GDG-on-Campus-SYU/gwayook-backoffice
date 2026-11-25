begin;
insert into auth.users (id, email, email_confirmed_at)
select ('41000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid, 'runoff' || i || '@example.test', now()
from generate_series(1,7) i;
insert into public.teams (id, name, presentation_order)
select ('51000000-0000-0000-0000-' || lpad(i::text,12,'0'))::uuid, 'Runoff team ' || i, i from generate_series(1,4) i;
insert into public.members (name, email, auth_user_id, role, team_id, active)
select 'Runoff member ' || i, 'runoff' || i || '@example.test',
  ('41000000-0000-0000-0000-' || lpad(i::text,12,'0'))::uuid,
  case i when 1 then 'owner' when 2 then 'staff' else 'participant' end,
  case when i > 2 then ('51000000-0000-0000-0000-' || lpad(least(i-2,4)::text,12,'0'))::uuid end,
  i <> 7 from generate_series(1,7) i;
insert into private.participant_operations(member_id,attendance_status,checked_in_at)
select id,'present',now() from public.members where email in ('runoff3@example.test','runoff4@example.test','runoff5@example.test','runoff6@example.test','runoff7@example.test');
update public.event_settings set vote_closes_at = clock_timestamp() + interval '1 hour' where id;
\ir fixtures/consented-members.sql
select pg_temp.consent_fixture_members('{"team":false,"presentation":false,"bingo":false}');

set local role authenticated;
do $$
declare
  a uuid := '51000000-0000-0000-0000-000000000001';
  b uuid := '51000000-0000-0000-0000-000000000002';
  c uuid := '51000000-0000-0000-0000-000000000003';
  d uuid := '51000000-0000-0000-0000-000000000004';
begin
  if has_table_privilege('authenticated', 'private.runoff_votes', 'select')
    or has_table_privilege('authenticated', 'private.runoff_votes', 'insert')
    or has_function_privilege('anon', 'public.manage_runoff(text,uuid[],timestamptz,uuid)', 'execute')
    or has_function_privilege('service_role', 'public.cast_runoff_vote(uuid,uuid)', 'execute')
    or has_function_privilege('authenticated', 'private.manage_main_vote(text,uuid[],jsonb)', 'execute')
    or has_function_privilege('authenticated', 'private.get_runoff(uuid)', 'execute') then
    raise exception 'runoff table or helper permissions exposed';
  end if;
  perform set_config('request.jwt.claim.sub', '41000000-0000-0000-0000-000000000001', true);
  begin
    perform public.manage_runoff('start', array[a,b], clock_timestamp() + interval '10 minutes');
    raise exception 'runoff opened before main voting';
  exception when invalid_parameter_value then null; end;
  perform public.manage_vote('open', array[a,b,c,d]);
  perform set_config('request.jwt.claim.sub', '41000000-0000-0000-0000-000000000003', true);
  perform public.cast_vote(b);
  perform set_config('request.jwt.claim.sub', '41000000-0000-0000-0000-000000000004', true);
  perform public.cast_vote(a);
  perform set_config('request.jwt.claim.sub', '41000000-0000-0000-0000-000000000005', true);
  perform public.cast_vote(a);
  perform set_config('request.jwt.claim.sub', '41000000-0000-0000-0000-000000000006', true);
  perform public.cast_vote(b);
  perform set_config('request.jwt.claim.sub', '41000000-0000-0000-0000-000000000001', true);
  perform public.manage_vote('close');
end;
$$;
reset role;
select set_config('test.main_hash', md5((select jsonb_agg(to_jsonb(v) order by member_id)::text from private.votes v)), true);
select set_config('test.event_hash', md5((select to_jsonb(e)::text from public.event_settings e where id)), true);
select set_config('test.main_eligibility_hash', md5((select jsonb_agg(to_jsonb(e) order by member_id)::text from private.vote_eligibility e)), true);
-- A current team change must not change the snapshotted runoff exclusion.
update public.members set team_id = '51000000-0000-0000-0000-000000000004' where email = 'runoff3@example.test';
update public.members set team_id = '51000000-0000-0000-0000-000000000001' where email = 'runoff5@example.test';
update public.members set active = true where email = 'runoff7@example.test';
set local role authenticated;
do $$
declare
  a uuid := '51000000-0000-0000-0000-000000000001';
  b uuid := '51000000-0000-0000-0000-000000000002';
  c uuid := '51000000-0000-0000-0000-000000000003';
  d uuid := '51000000-0000-0000-0000-000000000004';
  round_id uuid;
  details jsonb;
begin
  perform set_config('request.jwt.claim.sub', '41000000-0000-0000-0000-000000000002', true);
  begin
    perform public.manage_runoff('start', array[a,b], clock_timestamp() + interval '10 minutes');
    raise exception 'staff opened runoff';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub', '41000000-0000-0000-0000-000000000003', true);
  begin
    perform public.manage_runoff('start', array[a,b], clock_timestamp() + interval '10 minutes');
    raise exception 'participant opened runoff';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub', '41000000-0000-0000-0000-000000000001', true);
  begin
    perform public.manage_runoff('start', array[a,c], clock_timestamp() + interval '10 minutes');
    raise exception 'unrelated main scores accepted';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.manage_runoff('start', array[a,a], clock_timestamp() + interval '10 minutes');
    raise exception 'duplicate candidate accepted';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.manage_runoff('start', array[a,b], clock_timestamp() - interval '1 second');
    raise exception 'past runoff deadline accepted';
  exception when invalid_parameter_value then null; end;
  perform public.manage_runoff('start', array[a,b], clock_timestamp() + interval '10 minutes');
  details := public.get_vote_details();
  round_id := (details->'runoff'->>'id')::uuid;
  perform set_config('test.first_round', round_id::text, true);
  if details->>'status' <> 'closed' or details->'runoff'->>'status' <> 'open'
    or details->'runoff'->>'eligible_count' <> '2' or jsonb_array_length(details->'runoff_groups') <> 2
    or details->'runoff'->>'main_vote_count' is distinct from '2'
    or details->'runoff'->'results' <> '[]'::jsonb then raise exception 'wrong owner overview %', details; end if;
  begin
    perform public.manage_runoff('start', array[c,d], clock_timestamp() + interval '10 minutes');
    raise exception 'concurrent runoff opened';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.manage_vote('publish', null, jsonb_build_array(jsonb_build_object('team_id', a, 'award_name', 'Winner', 'tie_reason', 'Manual')));
    raise exception 'published before runoff close';
  exception when invalid_parameter_value then null; end;
  perform set_config('request.jwt.claim.sub', '41000000-0000-0000-0000-000000000003', true);
  begin
    perform public.cast_runoff_vote(round_id,b);
    raise exception 'candidate original-team member voted after moving team';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub', '41000000-0000-0000-0000-000000000007', true);
  perform public.save_my_consents('2026-11-16.1',true,'{"team":false,"presentation":false,"bingo":false}');
  begin
    perform public.cast_runoff_vote(round_id,b);
    raise exception 'newly active member outside main electorate voted';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub', '41000000-0000-0000-0000-000000000005', true);
  begin
    perform public.cast_runoff_vote(round_id,c);
    raise exception 'non-runoff candidate received vote';
  exception when invalid_parameter_value then null; end;
  perform public.cast_runoff_vote(round_id,a);
  perform public.cast_runoff_vote(round_id,b);
  perform public.cast_runoff_vote(round_id,b);
  details := public.get_vote_details();
  if details->'runoff'->>'main_vote_count' is not null
    or public.get_vote_overview()->'runoff'->>'main_vote_count' is not null then
    raise exception 'unpublished main vote count leaked to participant during runoff';
  end if;
  if details->'runoff'->>'choice_id' <> b::text or details->'runoff'->>'voted' <> 'true'
    or details->'runoff'->>'eligible_count' is not null or details->'results' <> '[]'::jsonb then
    raise exception 'wrong participant scope';
  end if;
  perform set_config('request.jwt.claim.sub', '41000000-0000-0000-0000-000000000006', true);
  if public.get_vote_details()->'runoff'->>'choice_id' is not null then raise exception 'another participant choice leaked'; end if;
  perform public.cast_runoff_vote(round_id,b);
  perform set_config('request.jwt.claim.sub', '41000000-0000-0000-0000-000000000002', true);
  details := public.get_vote_details();
  if details->'runoff'->>'choice_id' is not null or details->'runoff'->>'voted_count' <> '2'
    or details->'runoff'->>'main_vote_count' is distinct from '2'
    or details->'runoff'->'results' <> '[]'::jsonb then raise exception 'staff scope incorrect'; end if;
  begin
    perform public.manage_runoff('close', null, null, round_id);
    raise exception 'staff closed runoff';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub', '41000000-0000-0000-0000-000000000001', true);
  perform public.manage_runoff('close', null, null, round_id);
  details := public.get_vote_details();
  if details->'results'->0->>'team_id' <> b::text or details->'results'->0->>'vote_count' <> '2'
    or details->'results'->0->>'runoff_vote_count' <> '2' or details->'results'->0->>'tied_count' <> '1'
    or details->'results'->0->>'main_tied_count' <> '2' then raise exception 'runoff ranking not integrated %', details; end if;
  begin
    perform public.manage_runoff('start', array[a,b], clock_timestamp() + interval '10 minutes');
    raise exception 'second runoff in same group accepted';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.manage_vote('publish', null, jsonb_build_array(jsonb_build_object('team_id', a, 'award_name', 'Winner', 'tie_reason', 'Override')));
    raise exception 'main tied team bypassed completed runoff ranking';
  exception when invalid_parameter_value then null; end;
  perform set_config('request.jwt.claim.sub', '41000000-0000-0000-0000-000000000005', true);
  if public.get_vote_details()->'runoff'->'results' <> '[]'::jsonb or public.get_vote_details()->'runoff_history' <> '[]'::jsonb then
    raise exception 'unpublished runoff result leaked';
  end if;
  if public.get_vote_details()->'runoff'->>'main_vote_count' is not null
    or public.get_vote_overview()->'runoff'->>'main_vote_count' is not null then
    raise exception 'unpublished main vote count leaked after runoff close';
  end if;
  begin
    perform public.cast_runoff_vote(round_id,a);
    raise exception 'vote changed after close';
  exception when invalid_parameter_value then null; end;
  perform set_config('request.jwt.claim.sub', '41000000-0000-0000-0000-000000000001', true);
  perform public.manage_runoff('start', array[c,d], clock_timestamp() + interval '10 minutes');
  round_id := (public.get_vote_details()->'runoff'->>'id')::uuid;
  perform set_config('test.second_round', round_id::text, true);
  perform set_config('request.jwt.claim.sub', '41000000-0000-0000-0000-000000000003', true);
  perform public.cast_runoff_vote(round_id,c);
  perform set_config('request.jwt.claim.sub', '41000000-0000-0000-0000-000000000004', true);
  perform public.cast_runoff_vote(round_id,d);
end;
$$;
reset role;
update private.vote_runoffs set closes_at = opens_at + interval '1 microsecond'
where id = current_setting('test.second_round')::uuid;
do $$
begin
  if md5((select jsonb_agg(to_jsonb(v) order by member_id)::text from private.votes v)) <> current_setting('test.main_hash')
    or md5((select to_jsonb(e)::text from public.event_settings e where id)) <> current_setting('test.event_hash')
    or md5((select jsonb_agg(to_jsonb(e) order by member_id)::text from private.vote_eligibility e)) <> current_setting('test.main_eligibility_hash') then
    raise exception 'runoff changed original ballots, deadlines or electorate';
  end if;
end;
$$;
set local role authenticated;
do $$
declare
  round_id uuid := current_setting('test.second_round')::uuid;
  a uuid := '51000000-0000-0000-0000-000000000001';
  b uuid := '51000000-0000-0000-0000-000000000002';
  c uuid := '51000000-0000-0000-0000-000000000003';
  d uuid := '51000000-0000-0000-0000-000000000004';
  awards jsonb;
begin
  perform set_config('request.jwt.claim.sub', '41000000-0000-0000-0000-000000000003', true);
  if public.get_vote_overview()->'runoff'->>'status' <> 'expired' then raise exception 'runoff expiry not exposed'; end if;
  if public.get_vote_details()->'runoff'->>'main_vote_count' is not null
    or public.get_vote_overview()->'runoff'->>'main_vote_count' is not null then
    raise exception 'unpublished main vote count leaked after runoff expiry';
  end if;
  begin
    perform public.cast_runoff_vote(round_id,d);
    raise exception 'vote changed after deadline';
  exception when invalid_parameter_value then null; end;
  perform set_config('request.jwt.claim.sub', '41000000-0000-0000-0000-000000000001', true);
  perform public.manage_runoff('close', null, null, round_id);
  awards := jsonb_build_array(jsonb_build_object('team_id', b, 'award_name', 'First'),
    jsonb_build_object('team_id', a, 'award_name', 'Second'), jsonb_build_object('team_id', c, 'award_name', 'Third'));
  begin
    perform public.manage_vote('publish', null, awards);
    raise exception 'repeated tie lacked decision reason';
  exception when invalid_parameter_value then null; end;
  awards := jsonb_set(awards, '{2,tie_reason}', '"Discussion"');
  perform public.manage_vote('publish', null, awards);
  perform set_config('request.jwt.claim.sub', '41000000-0000-0000-0000-000000000003', true);
  if jsonb_array_length(public.get_vote_details()->'runoff_history') <> 2
    or public.get_vote_details()->'runoff_history'->0->>'main_vote_count' is distinct from '2'
    or public.get_vote_details()->'runoff_history'->1->>'main_vote_count' is distinct from '0'
    or public.get_vote_overview()->'runoff'->>'main_vote_count' is distinct from '0'
    or public.get_vote_details()->'results'->0->>'team_id' <> b::text
    or public.get_vote_details()->'results'->2->>'tie_reason' is not null then
    raise exception 'published runoff result wrong';
  end if;
end;
$$;
rollback;

begin;
insert into auth.users (id, email, email_confirmed_at)
select ('42000000-0000-0000-0000-' || lpad(i::text,12,'0'))::uuid, 'emptyrunoff' || i || '@example.test', now()
from generate_series(1,4) i;
insert into public.teams (id, name)
select ('52000000-0000-0000-0000-' || lpad(i::text,12,'0'))::uuid, 'Empty runoff ' || i from generate_series(1,3) i;
insert into public.members (name, email, auth_user_id, role, team_id)
select 'Empty runoff member ' || i, 'emptyrunoff' || i || '@example.test',
  ('42000000-0000-0000-0000-' || lpad(i::text,12,'0'))::uuid,
  case when i=1 then 'owner' else 'participant' end,
  case when i>1 then ('52000000-0000-0000-0000-' || lpad((i-1)::text,12,'0'))::uuid end from generate_series(1,4) i;
insert into private.participant_operations(member_id,attendance_status,checked_in_at)
select id,'present',now() from public.members where email in ('emptyrunoff2@example.test','emptyrunoff3@example.test','emptyrunoff4@example.test');
update public.event_settings set vote_closes_at=clock_timestamp()+interval '1 hour' where id;
\ir fixtures/consented-members.sql
select pg_temp.consent_fixture_members('{"team":false,"presentation":false,"bingo":false}');

set local role authenticated;
do $$
declare
  a uuid := '52000000-0000-0000-0000-000000000001';
  b uuid := '52000000-0000-0000-0000-000000000002';
  c uuid := '52000000-0000-0000-0000-000000000003';
begin
  perform set_config('request.jwt.claim.sub','42000000-0000-0000-0000-000000000001',true);
  perform public.manage_vote('open',array[a,b,c]);
  perform public.manage_vote('close');
  begin
    perform public.manage_runoff('start',array[a,b],clock_timestamp()+interval '10 minutes');
    raise exception 'three-way tie was narrowed to two teams';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.manage_runoff('start',array[a,b,c],clock_timestamp()+interval '10 minutes');
    raise exception 'empty electorate permitted';
  exception when invalid_parameter_value then null; end;
  if public.get_vote_details()->>'runoff' is not null then raise exception 'rejected runoff left a partial round'; end if;
end;
$$;
rollback;
select '1..1';
select 'ok 1 - runoff roles, full ties, snapshot electorate, privacy, original preservation, expiry, ranking and repeated ties';

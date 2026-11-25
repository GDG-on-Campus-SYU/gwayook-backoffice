begin;

insert into auth.users (id, email, email_confirmed_at) values
  ('e8000000-0000-0000-0000-000000000001', 'schedule-owner@example.test', now()),
  ('e8000000-0000-0000-0000-000000000002', 'schedule-staff@example.test', now()),
  ('e8000000-0000-0000-0000-000000000003', 'schedule-alice@example.test', now()),
  ('e8000000-0000-0000-0000-000000000004', 'schedule-bob@example.test', now()),
  ('e8000000-0000-0000-0000-000000000005', 'schedule-late@example.test', now());
insert into public.teams (id, name, presentation_order) values
  ('e9000000-0000-0000-0000-000000000001', 'Schedule Alpha', 1),
  ('e9000000-0000-0000-0000-000000000002', 'Schedule Beta', 2),
  ('e9000000-0000-0000-0000-000000000003', 'Schedule Gamma', 3);
insert into public.members (name, email, auth_user_id, role, team_id, active) values
  ('Owner', 'schedule-owner@example.test', 'e8000000-0000-0000-0000-000000000001', 'owner', null, true),
  ('Staff', 'schedule-staff@example.test', 'e8000000-0000-0000-0000-000000000002', 'staff', null, true),
  ('Alice', 'schedule-alice@example.test', 'e8000000-0000-0000-0000-000000000003', 'participant', 'e9000000-0000-0000-0000-000000000001', true),
  ('Bob', 'schedule-bob@example.test', 'e8000000-0000-0000-0000-000000000004', 'participant', 'e9000000-0000-0000-0000-000000000002', true),
  ('Late', 'schedule-late@example.test', 'e8000000-0000-0000-0000-000000000005', 'participant', 'e9000000-0000-0000-0000-000000000003', false);
insert into private.participant_operations(member_id,attendance_status,checked_in_at)
select id,'present',now() from public.members where email in ('schedule-alice@example.test','schedule-bob@example.test','schedule-late@example.test');
update public.teams set representative_id = (select id from public.members where email = 'schedule-bob@example.test')
  where id = 'e9000000-0000-0000-0000-000000000002';
update public.event_settings set vote_closes_at = clock_timestamp() + interval '2 hours',
  submission_deadline = clock_timestamp() + interval '3 hours' where id;
create temporary table schedule_original_settings as select vote_closes_at, submission_deadline from public.event_settings;

\ir fixtures/consented-members.sql
select pg_temp.consent_fixture_members('{"team":false,"presentation":false,"bingo":false}');

set local role authenticated;
do $$
declare
  alpha uuid := 'e9000000-0000-0000-0000-000000000001';
  beta uuid := 'e9000000-0000-0000-0000-000000000002';
  actor_id text;
  opens timestamptz;
  closing timestamptz;
begin
  if has_function_privilege('anon', 'public.schedule_vote(timestamptz, uuid[])', 'execute')
    or has_function_privilege('anon', 'public.cancel_vote_schedule()', 'execute')
    or has_function_privilege('anon', 'private.schedule_vote(timestamptz, uuid[])', 'execute')
    or has_function_privilege('service_role', 'public.schedule_vote(timestamptz, uuid[])', 'execute')
    or has_table_privilege('authenticated', 'private.vote_eligibility', 'select')
    or has_table_privilege('authenticated', 'public.event_settings', 'update') then
    raise exception 'scheduled vote RPCs or private ballot data exposed';
  end if;

  foreach actor_id in array array[
    'e8000000-0000-0000-0000-000000000002', -- staff
    'e8000000-0000-0000-0000-000000000003', -- participant
    'e8000000-0000-0000-0000-000000000005', -- inactive participant
    'e8000000-0000-0000-0000-000000000099'  -- account outside roster
  ] loop
    perform set_config('request.jwt.claim.sub', actor_id, true);
    begin
      perform public.schedule_vote(clock_timestamp() + interval '1 hour', array[alpha, beta]);
      raise exception 'non-owner scheduled voting';
    exception when insufficient_privilege then null;
    end;
    begin
      perform public.cancel_vote_schedule();
      raise exception 'non-owner cancelled voting';
    exception when insufficient_privilege then null;
    end;
  end loop;

  perform set_config('request.jwt.claim.sub', 'e8000000-0000-0000-0000-000000000001', true);
  select vote_closes_at into closing from public.event_settings where id;
  foreach opens in array array[null::timestamptz, '-infinity'::timestamptz, 'infinity'::timestamptz,
    clock_timestamp(), clock_timestamp() - interval '1 second', closing, closing + interval '1 minute'] loop
    begin
      perform public.schedule_vote(opens, array[alpha, beta]);
      raise exception 'invalid scheduled start accepted: %', opens;
    exception when invalid_parameter_value then null;
    end;
  end loop;
  begin
    perform public.schedule_vote(clock_timestamp() + interval '1 hour', array[alpha]);
    raise exception 'single-candidate schedule accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.schedule_vote(clock_timestamp() + interval '1 hour', array[alpha, alpha]);
    raise exception 'duplicate candidates accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.schedule_vote(clock_timestamp() + interval '1 hour', array[alpha, null]::uuid[]);
    raise exception 'null candidate accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.schedule_vote(clock_timestamp() + interval '1 hour', array[alpha, 'e9000000-0000-0000-0000-000000000099'::uuid]);
    raise exception 'unknown candidate accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.cancel_vote_schedule();
    raise exception 'draft ballot cancelled as a schedule';
  exception when invalid_parameter_value then null;
  end;
end;
$$;
reset role;

-- A missing/indefinite closing time cannot produce an unbounded schedule.
do $$
declare closing timestamptz;
begin
  foreach closing in array array[null::timestamptz, 'infinity'::timestamptz] loop
    update public.event_settings set vote_closes_at = closing where id;
    begin
      perform public.schedule_vote(clock_timestamp() + interval '1 hour',
        array['e9000000-0000-0000-0000-000000000001', 'e9000000-0000-0000-0000-000000000002']::uuid[]);
      raise exception 'schedule with missing/non-finite deadline accepted';
    exception when invalid_parameter_value then null;
    end;
  end loop;
  update public.event_settings set vote_closes_at = (select vote_closes_at from schedule_original_settings) where id;
  if (select vote_status from public.event_settings where id) <> 'draft'
    or exists (select 1 from private.vote_candidates) or exists (select 1 from private.vote_eligibility) then
    raise exception 'invalid schedules left partial state';
  end if;
end;
$$;

-- Failed scheduling must roll back candidate creation when there are no voters.
savepoint no_voters;
update public.teams set representative_id = null;
update public.members set active = false where role = 'participant';
set local role authenticated;
do $$
begin
  begin
    perform public.schedule_vote(clock_timestamp() + interval '1 hour',
      array['e9000000-0000-0000-0000-000000000001', 'e9000000-0000-0000-0000-000000000002']::uuid[]);
    raise exception 'schedule without eligible voters accepted';
  exception when invalid_parameter_value then null;
  end;
end;
$$;
reset role;
do $$
begin
  if exists (select 1 from private.vote_candidates) or exists (select 1 from private.vote_eligibility) then
    raise exception 'failed schedule left candidate/voter snapshots';
  end if;
end;
$$;
rollback to savepoint no_voters;

set local role authenticated;
do $$
declare
  alpha uuid := 'e9000000-0000-0000-0000-000000000001';
  beta uuid := 'e9000000-0000-0000-0000-000000000002';
  result jsonb;
  starts timestamptz := clock_timestamp() + interval '1 hour';
begin
  perform public.schedule_vote(starts, array[alpha, beta]);
  result := public.get_vote_details();
  if result->>'status' is distinct from 'scheduled' or (result->>'opens_at')::timestamptz is distinct from starts
    or result->>'eligible_count' is distinct from '2' or result->>'voted_count' is distinct from '0'
    or jsonb_array_length(result->'candidates') <> 2 or jsonb_array_length(result->'results') <> 0 then
    raise exception 'wrong scheduled overview: %', result;
  end if;
  begin
    perform public.manage_vote('open', array[alpha, beta]);
    raise exception 'manual opening bypassed scheduled start';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.manage_vote('close');
    raise exception 'manual closing bypassed scheduled start';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.schedule_vote(starts + interval '1 minute', array[alpha, beta]);
    raise exception 'active schedule overwritten';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.save_event_settings(jsonb_build_object('vote_closes_at', starts + interval '3 hours'));
    raise exception 'scheduled deadline changed without cancellation';
  exception when invalid_parameter_value then null;
  end;

  perform set_config('request.jwt.claim.sub', 'e8000000-0000-0000-0000-000000000003', true);
  result := public.get_vote_details();
  if result->>'status' is distinct from 'scheduled' or result->>'eligible' is distinct from 'true'
    or result->>'choice_id' is not null or result->>'eligible_count' is not null
    or jsonb_array_length(result->'results') <> 0 then raise exception 'scheduled participant privacy failed: %', result; end if;
  begin
    perform public.cast_vote(beta);
    raise exception 'direct vote RPC accepted a vote before the scheduled start';
  exception when invalid_parameter_value then null;
  end;
  perform set_config('request.jwt.claim.sub', 'e8000000-0000-0000-0000-000000000002', true);
  begin
    perform public.cancel_vote_schedule();
    raise exception 'staff cancelled an active schedule';
  exception when insufficient_privilege then null;
  end;
  perform set_config('request.jwt.claim.sub', 'e8000000-0000-0000-0000-000000000001', true);
  perform public.cancel_vote_schedule();
  if public.get_vote_overview()->>'status' is distinct from 'draft'
    or public.get_vote_overview()->>'opens_at' is not null then raise exception 'cancel did not return to draft'; end if;
end;
$$;
reset role;
do $$
begin
  if exists (select 1 from private.vote_candidates) or exists (select 1 from private.vote_eligibility)
    or exists (select 1 from private.votes) or exists (select 1 from private.award_decisions) then
    raise exception 'cancelled schedule left ballot snapshots';
  end if;
  if (select row(vote_closes_at, submission_deadline) from public.event_settings where id)
    is distinct from (select row(vote_closes_at, submission_deadline) from schedule_original_settings)
    or (select representative_id from public.teams where id = 'e9000000-0000-0000-0000-000000000002')
      is distinct from (select id from public.members where email = 'schedule-bob@example.test') then
    raise exception 'schedule/cancellation changed a deadline or representative';
  end if;
  if (select count(*) from public.audit_logs where action = 'vote_schedule') <> 1
    or (select count(*) from public.audit_logs where action = 'vote_schedule_cancel') <> 1 then
    raise exception 'schedule/cancellation audit missing or failed operations audited';
  end if;
end;
$$;

-- A new reservation rebuilds snapshots. Later roster edits cannot change them.
set local role authenticated;
do $$
declare
  alpha uuid := 'e9000000-0000-0000-0000-000000000001';
  beta uuid := 'e9000000-0000-0000-0000-000000000002';
  alice uuid;
  late uuid;
begin
  perform public.schedule_vote(clock_timestamp() + interval '1 hour', array[alpha, beta]);
  select id into alice from jsonb_populate_recordset(null::public.members,public.get_staff_members('participants')) where email = 'schedule-alice@example.test';
  select id into late from jsonb_populate_recordset(null::public.members,public.get_staff_members('participants')) where email = 'schedule-late@example.test';
  perform public.manage_roster('update_member', jsonb_build_object('id', alice, 'name', 'Alice', 'team_id', beta, 'active', true));
  perform public.manage_roster('update_member', jsonb_build_object('id', late, 'name', 'Late', 'team_id', beta, 'active', true));
  perform public.manage_roster('update_team', jsonb_build_object('id', alpha, 'name', 'Renamed Alpha', 'presentation_order', 3));
  if public.get_vote_details()->'candidates'->0->>'name' is distinct from 'Schedule Alpha'
    or public.get_vote_overview()->>'eligible_count' is distinct from '2' then
    raise exception 'scheduled ballot changed with live roster';
  end if;
end;
$$;
reset role;

-- Move only this isolated fixture's start near the DB clock, then let time pass.
-- No status transition, cron job or API call is needed to activate the ballot.
update public.event_settings set vote_opens_at = clock_timestamp() + interval '250 milliseconds' where id;
select pg_sleep(0.3);
set local role authenticated;
do $$
declare
  alpha uuid := 'e9000000-0000-0000-0000-000000000001';
  beta uuid := 'e9000000-0000-0000-0000-000000000002';
  result jsonb;
begin
  if public.get_vote_overview()->>'status' is distinct from 'open' then
    raise exception 'scheduled vote failed to open automatically using database time';
  end if;
  begin
    perform public.cancel_vote_schedule();
    raise exception 'schedule cancelled after voting began';
  exception when invalid_parameter_value then null;
  end;
  perform set_config('request.jwt.claim.sub', 'e8000000-0000-0000-0000-000000000003', true);
  begin
    perform public.cast_vote(alpha);
    raise exception 'scheduled snapshot own-team restriction lost';
  exception when invalid_parameter_value then null;
  end;
  perform public.cast_vote(beta);
  perform public.cast_vote(beta);
  result := public.get_vote_details();
  if result->>'choice_id' is distinct from beta::text or result->>'own_team_id' is distinct from alpha::text then
    raise exception 'wrong scheduled voter snapshot: %', result;
  end if;
  perform set_config('request.jwt.claim.sub', 'e8000000-0000-0000-0000-000000000005', true);
  perform public.save_my_consents('2026-11-16.1',true,'{"team":false,"presentation":false,"bingo":false}');
  begin
    perform public.cast_vote(alpha);
    raise exception 'late activation altered frozen scheduled electorate';
  exception when insufficient_privilege then null;
  end;
  perform set_config('request.jwt.claim.sub', 'e8000000-0000-0000-0000-000000000004', true);
  if public.get_vote_details()->>'choice_id' is not null then raise exception 'another voter choice exposed'; end if;
  perform public.cast_vote(alpha);
  perform set_config('request.jwt.claim.sub', 'e8000000-0000-0000-0000-000000000002', true);
  result := public.get_vote_details();
  if result->>'voted_count' is distinct from '2' or result->>'choice_id' is not null
    or jsonb_array_length(result->'results') <> 0 then raise exception 'live schedule tally leaked or duplicated: %', result; end if;
end;
$$;
reset role;

-- Expiration and closing still obey the server clock; a tied result still needs
-- an explicit owner decision, and participant-facing results hide that reason.
update public.event_settings set vote_opens_at = clock_timestamp() - interval '2 minutes',
  vote_closes_at = clock_timestamp() - interval '1 minute' where id;
set local role authenticated;
do $$
declare
  alpha uuid := 'e9000000-0000-0000-0000-000000000001';
  beta uuid := 'e9000000-0000-0000-0000-000000000002';
begin
  perform set_config('request.jwt.claim.sub', 'e8000000-0000-0000-0000-000000000003', true);
  if public.get_vote_overview()->>'status' is distinct from 'expired' then raise exception 'scheduled deadline not reflected'; end if;
  begin
    perform public.cast_vote(beta);
    raise exception 'scheduled vote accepted after deadline';
  exception when invalid_parameter_value then null;
  end;
  perform set_config('request.jwt.claim.sub', 'e8000000-0000-0000-0000-000000000001', true);
  perform public.manage_vote('close');
  begin
    perform public.manage_vote('publish', null, jsonb_build_array(jsonb_build_object('team_id', beta, 'award_name', '대상')));
    raise exception 'scheduled vote published an unexplained tie';
  exception when invalid_parameter_value then null;
  end;
  perform public.manage_vote('publish', null,
    jsonb_build_array(jsonb_build_object('team_id', beta, 'award_name', '대상', 'tie_reason', '테스트 동점 결정')));
  begin
    perform public.cancel_vote_schedule();
    raise exception 'published ballot cancelled';
  exception when invalid_parameter_value then null;
  end;
  perform set_config('request.jwt.claim.sub', 'e8000000-0000-0000-0000-000000000003', true);
  if public.get_vote_details()->>'status' is distinct from 'published'
    or public.get_vote_details()->>'choice_id' is not null
    or public.get_vote_details()->'results'->1->>'tie_reason' is not null then
    raise exception 'published scheduled vote privacy changed';
  end if;
end;
$$;

select '1..1' as tap;
select 'ok 1 - scheduled vote authorization, validation, snapshots, cancellation, automatic start, privacy and expiry' as tap;
rollback;

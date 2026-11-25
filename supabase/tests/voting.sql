begin;

insert into auth.users (id, email, email_confirmed_at) values
  ('40000000-0000-0000-0000-000000000001', 'owner@example.test', now()),
  ('40000000-0000-0000-0000-000000000002', 'staff@example.test', now()),
  ('40000000-0000-0000-0000-000000000003', 'alpha@example.test', now()),
  ('40000000-0000-0000-0000-000000000004', 'beta@example.test', now()),
  ('40000000-0000-0000-0000-000000000005', 'gamma@example.test', now()),
  ('40000000-0000-0000-0000-000000000006', 'delta@example.test', now()),
  ('40000000-0000-0000-0000-000000000007', 'late@example.test', now());

insert into public.teams (id, name, presentation_order) values
  ('50000000-0000-0000-0000-000000000001', 'Alpha', 1),
  ('50000000-0000-0000-0000-000000000002', 'Beta', 2),
  ('50000000-0000-0000-0000-000000000003', 'Gamma', 3),
  ('50000000-0000-0000-0000-000000000004', 'Delta', 4);

insert into public.members (name, email, auth_user_id, role, team_id, active) values
  ('Owner', 'owner@example.test', '40000000-0000-0000-0000-000000000001', 'owner', null, true),
  ('Staff', 'staff@example.test', '40000000-0000-0000-0000-000000000002', 'staff', null, true),
  ('Alice', 'alpha@example.test', '40000000-0000-0000-0000-000000000003', 'participant', '50000000-0000-0000-0000-000000000001', true),
  ('Bob', 'beta@example.test', '40000000-0000-0000-0000-000000000004', 'participant', '50000000-0000-0000-0000-000000000002', true),
  ('Carol', 'gamma@example.test', '40000000-0000-0000-0000-000000000005', 'participant', '50000000-0000-0000-0000-000000000003', true),
  ('Dan', 'delta@example.test', '40000000-0000-0000-0000-000000000006', 'participant', '50000000-0000-0000-0000-000000000004', true),
  ('Late', 'late@example.test', '40000000-0000-0000-0000-000000000007', 'participant', '50000000-0000-0000-0000-000000000004', false);
insert into private.participant_operations(member_id,attendance_status,checked_in_at)
select id,'present',now() from public.members where email in ('alpha@example.test','beta@example.test','gamma@example.test','delta@example.test','late@example.test');

update public.event_settings set vote_closes_at = clock_timestamp() + interval '10 minutes' where id;
\ir fixtures/consented-members.sql
select pg_temp.consent_fixture_members('{"team":false,"presentation":false,"bingo":false}');

set local role authenticated;
do $$
declare
  alpha uuid := '50000000-0000-0000-0000-000000000001';
  beta uuid := '50000000-0000-0000-0000-000000000002';
  gamma uuid := '50000000-0000-0000-0000-000000000003';
  delta uuid := '50000000-0000-0000-0000-000000000004';
  alice uuid;
  late uuid;
  result jsonb;
begin
  if has_table_privilege('authenticated', 'private.votes', 'select')
    or has_function_privilege('anon', 'public.get_vote_details()', 'execute') then
    raise exception 'vote table or anonymous endpoint is exposed';
  end if;
  perform set_config('request.jwt.claim.sub', '40000000-0000-0000-0000-000000000002', true);
  begin
    perform public.manage_vote('open', array[alpha, beta, gamma]);
    raise exception 'staff opened a vote';
  exception when insufficient_privilege then null;
  end;

  perform set_config('request.jwt.claim.sub', '40000000-0000-0000-0000-000000000001', true);
  if public.get_vote_details()->'candidates'->0->>'active_member_count' is distinct from '1' then
    raise exception 'draft candidates lack active roster count';
  end if;
  perform public.manage_vote('open', array[alpha, beta, gamma]);
  select id into alice from jsonb_populate_recordset(null::public.members,public.get_staff_members('participants')) where email = 'alpha@example.test';
  select id into late from jsonb_populate_recordset(null::public.members,public.get_staff_members('participants')) where email = 'late@example.test';
  perform public.manage_roster('update_member', jsonb_build_object('id', alice, 'name', 'Alice', 'team_id', beta, 'active', true));
  perform public.manage_roster('update_member', jsonb_build_object('id', late, 'name', 'Late', 'team_id', delta, 'active', true));
  perform public.manage_roster('update_team', jsonb_build_object('id', alpha, 'name', 'New Alpha', 'presentation_order', 1));

  perform set_config('request.jwt.claim.sub', '40000000-0000-0000-0000-000000000003', true);
  begin
    perform public.cast_vote(alpha);
    raise exception 'snapshot own-team vote allowed';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.cast_vote(delta);
    raise exception 'non-candidate accepted';
  exception when invalid_parameter_value then null;
  end;
  perform public.cast_vote(gamma);
  perform public.cast_vote(beta);
  perform public.cast_vote(beta);
  result := public.get_vote_details();
  if result->>'choice_id' is distinct from beta::text or result->>'own_team_id' is distinct from alpha::text
    or result->>'eligible_count' is not null or result->'candidates'->0->>'name' is distinct from 'Alpha' then
    raise exception 'wrong participant scope or changed candidate snapshot: %', result;
  end if;

  perform set_config('request.jwt.claim.sub', '40000000-0000-0000-0000-000000000007', true);
  perform public.save_my_consents('2026-11-16.1',true,'{"team":false,"presentation":false,"bingo":false}');
  begin
    perform public.cast_vote(beta);
    raise exception 'participant activated after opening received a vote';
  exception when insufficient_privilege then null;
  end;
  perform set_config('request.jwt.claim.sub', '40000000-0000-0000-0000-000000000004', true);
  if public.get_vote_details()->>'choice_id' is not null then raise exception 'another participant sees a vote'; end if;
  perform public.cast_vote(alpha);
  perform set_config('request.jwt.claim.sub', '40000000-0000-0000-0000-000000000005', true);
  perform public.cast_vote(beta);
  perform set_config('request.jwt.claim.sub', '40000000-0000-0000-0000-000000000006', true);
  perform public.cast_vote(gamma);

  perform set_config('request.jwt.claim.sub', '40000000-0000-0000-0000-000000000002', true);
  result := public.get_vote_details();
  if result->>'voted_count' is distinct from '4' or result->>'eligible_count' is distinct from '4'
    or result->>'choice_id' is not null or jsonb_array_length(result->'results') <> 0 then
    raise exception 'duplicate votes or staff sees pre-close vote detail: %', result;
  end if;
end;
$$;

reset role;
update public.event_settings set vote_opens_at = clock_timestamp() - interval '2 minutes',
  vote_closes_at = clock_timestamp() - interval '1 minute' where id;
set local role authenticated;

do $$
declare
  alpha uuid := '50000000-0000-0000-0000-000000000001';
  beta uuid := '50000000-0000-0000-0000-000000000002';
  gamma uuid := '50000000-0000-0000-0000-000000000003';
  winner jsonb := jsonb_build_object('team_id', beta, 'award_name', '대상');
  result jsonb;
begin
  perform set_config('request.jwt.claim.sub', '40000000-0000-0000-0000-000000000003', true);
  if public.get_vote_overview()->>'status' is distinct from 'expired' then raise exception 'deadline not reflected'; end if;
  begin
    perform public.cast_vote(gamma);
    raise exception 'vote change after deadline accepted';
  exception when invalid_parameter_value then null;
  end;

  perform set_config('request.jwt.claim.sub', '40000000-0000-0000-0000-000000000001', true);
  perform public.manage_vote('close');
  result := public.get_vote_details();
  if result->'results'->0->>'vote_count' is distinct from '2' or result->'results'->0->>'team_id' is distinct from beta::text
    or result->'results'->2->>'raw_rank' is distinct from '2' then
    raise exception 'wrong raw tally after closing: %', result;
  end if;
  begin
    perform public.manage_vote('publish', null, jsonb_build_array(jsonb_build_object('team_id', alpha, 'award_name', '대상', 'tie_reason', '사유')));
    raise exception 'different vote counts reordered';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.manage_vote('publish', null, jsonb_build_array(winner, jsonb_build_object('team_id', gamma, 'award_name', '우수상')));
    raise exception 'unexplained tie decision accepted';
  exception when invalid_parameter_value then null;
  end;

  perform set_config('request.jwt.claim.sub', '40000000-0000-0000-0000-000000000003', true);
  if jsonb_array_length(public.get_vote_details()->'results') <> 0 then raise exception 'unpublished tally exposed'; end if;
  perform set_config('request.jwt.claim.sub', '40000000-0000-0000-0000-000000000001', true);
  perform public.manage_vote('publish', null, jsonb_build_array(winner,
    jsonb_build_object('team_id', gamma, 'award_name', '우수상', 'tie_reason', '운영진 동점 기준 적용')));
  if public.get_vote_details()->'results'->2->>'tie_reason' is distinct from '운영진 동점 기준 적용' then
    raise exception 'tie reason not recorded';
  end if;
  perform set_config('request.jwt.claim.sub', '40000000-0000-0000-0000-000000000003', true);
  result := public.get_vote_details();
  if result->>'status' is distinct from 'published' or result->>'choice_id' is not null
    or result->'results'->2->>'final_rank' is distinct from '2' or result->'results'->2->>'vote_count' is distinct from '1'
    or result->'results'->2->>'tie_reason' is not null then raise exception 'public results leaked or malformed: %', result; end if;
end;
$$;

select '1..1' as tap;
select 'ok 1 - vote privacy, snapshots, deadlines, tally and tie decisions' as tap;
rollback;

begin;

insert into auth.users(id, email) select ('71000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid,
  'vote-delegate-' || i || '@example.test' from generate_series(1,8) i;
insert into public.teams(id, name) select ('72000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid,
  'Delegation team ' || i from generate_series(1,3) i;
insert into public.members(id, name, email, auth_user_id, role, active, team_id)
select ('73000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid, 'Delegation member ' || i,
  'vote-delegate-' || i || '@example.test', ('71000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid,
  case when i=1 then 'owner' when i in (2,3,7) then 'staff' else 'participant' end,
  i  is distinct from  7, case when i between 4 and 6 then ('72000000-0000-0000-0000-' || lpad((i-3)::text,12,'0'))::uuid end
from generate_series(1,7) i;
insert into private.participant_operations(member_id,attendance_status,checked_in_at)
select id,'present',now() from public.members where email in ('vote-delegate-4@example.test','vote-delegate-5@example.test','vote-delegate-6@example.test');
update public.event_settings set vote_closes_at = clock_timestamp() + interval '1 hour' where id;

\ir fixtures/consented-members.sql
select pg_temp.consent_fixture_members('{"team":false,"presentation":false,"bingo":false}');

set local role authenticated;
do $$
declare
  owner_auth constant text := '71000000-0000-0000-0000-000000000001';
  delegate_auth constant text := '71000000-0000-0000-0000-000000000002';
  delegate_id constant uuid := '73000000-0000-0000-0000-000000000002';
  a constant uuid := '72000000-0000-0000-0000-000000000001';
  b constant uuid := '72000000-0000-0000-0000-000000000002';
  c constant uuid := '72000000-0000-0000-0000-000000000003';
  denied_auth text;
  statement text;
  invalid_id uuid;
  round_id uuid;
begin
  if has_table_privilege('authenticated','private.vote_delegation','select,insert,update,delete')
    or has_table_privilege('anon','private.vote_delegation','select,insert,update,delete')
    or has_table_privilege('service_role','private.vote_delegation','select,insert,update,delete')
    or has_function_privilege('anon','public.can_manage_vote()','execute')
    or has_function_privilege('service_role','public.set_vote_delegate(uuid)','execute')
    or has_function_privilege('authenticated','private.require_vote_manager()','execute')
    or has_function_privilege('authenticated','private.manage_main_vote(text,uuid[],jsonb)','execute') then
    raise exception 'delegation exposed a table, anonymous endpoint or internal bypass';
  end if;
  perform set_config('request.jwt.claim.sub', owner_auth, true);
  if not public.can_manage_vote() or public.get_vote_delegation()->>'member_id' is not null then
    raise exception 'owner access or default unassigned delegation incorrect';
  end if;
  foreach invalid_id in array array[
    '73000000-0000-0000-0000-000000000001'::uuid,
    '73000000-0000-0000-0000-000000000004'::uuid,
    '73000000-0000-0000-0000-000000000007'::uuid,
    '73000000-0000-0000-0000-000000000099'::uuid
  ] loop
    begin
      perform public.set_vote_delegate(invalid_id);
      raise exception 'invalid delegate accepted';
    exception when invalid_parameter_value then null; end;
  end loop;

  foreach denied_auth in array array['', delegate_auth, '71000000-0000-0000-0000-000000000003',
    '71000000-0000-0000-0000-000000000004', '71000000-0000-0000-0000-000000000007', '71000000-0000-0000-0000-000000000008'] loop
    perform set_config('request.jwt.claim.sub', denied_auth, true);
    if public.can_manage_vote() then raise exception 'undesignated actor is a manager'; end if;
    foreach statement in array array[
      'select public.schedule_vote(now(),null)', 'select public.cancel_vote_schedule()',
      'select public.manage_vote(''open'')', 'select public.manage_vote(''close'')', 'select public.manage_vote(''publish'')',
      'select public.manage_runoff(''start'')', 'select public.manage_runoff(''close'')',
      'select public.get_vote_delegation()', 'select public.set_vote_delegate(null)'
    ] loop
      begin execute statement; raise exception 'unauthorized delegation operation: %', statement;
      exception when insufficient_privilege then null; end;
    end loop;
  end loop;

  perform set_config('request.jwt.claim.sub', owner_auth, true);
  perform public.set_vote_delegate(delegate_id);
  perform public.set_vote_delegate(delegate_id);
  -- Inspect persisted audit state as the fixture owner; clients use logged RPCs.
  reset role;
  if public.get_vote_delegation()->>'member_id' is distinct from delegate_id::text
    or public.get_vote_delegation()->>'updated_at' is null
    or (select count(*) from public.audit_logs where action='vote_delegate_changed')  is distinct from  1 then
    raise exception 'assignment is missing, not audited, or not idempotent';
  end if;
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', delegate_auth, true);
  if not public.can_manage_vote() then raise exception 'designated staff not recognized'; end if;
  foreach statement in array array[
    'select public.get_vote_delegation()', 'select public.set_vote_delegate(null)',
    'select public.save_event_settings(''{}'')', 'select public.save_event_staff(null,''Unauthorized'',''no@example.test'',true)',
    'select public.manage_bingo_round(''open'',1)', 'select public.manage_bingo_round(''close'',1)',
    'select public.manage_bingo_round(''restart'',1)',
    'select private.require_owner()'
  ] loop
    begin execute statement; raise exception 'delegation granted unrelated owner power: %', statement;
    exception when insufficient_privilege then null; end;
  end loop;
  perform public.schedule_vote(clock_timestamp()+interval '10 minutes',array[a,b,c]);
  perform public.cancel_vote_schedule();
  perform public.manage_vote('open',array[a,b,c]);
  perform set_config('request.jwt.claim.sub','71000000-0000-0000-0000-000000000004',true);
  perform public.cast_vote(b);
  perform set_config('request.jwt.claim.sub','71000000-0000-0000-0000-000000000005',true);
  perform public.cast_vote(a);
  perform set_config('request.jwt.claim.sub',delegate_auth,true);
  perform public.manage_vote('close');
  perform public.manage_runoff('start',array[a,b],clock_timestamp()+interval '5 minutes');
  round_id := (public.get_vote_details()->'runoff'->>'id')::uuid;
  perform set_config('request.jwt.claim.sub','71000000-0000-0000-0000-000000000006',true);
  perform public.cast_runoff_vote(round_id,b);
  perform set_config('request.jwt.claim.sub',delegate_auth,true);
  perform public.manage_runoff('close',null,null,round_id);
  perform public.manage_vote('publish',null,jsonb_build_array(
    jsonb_build_object('team_id',b,'award_name','First'), jsonb_build_object('team_id',a,'award_name','Second'),
    jsonb_build_object('team_id',c,'award_name','Third')));
  -- Inspect persisted audit state as the fixture owner; clients use logged RPCs.
  reset role;
  if public.get_vote_details()->>'status'  is distinct from  'published'
    or exists(select 1 from public.audit_logs where action in ('vote_schedule','vote_schedule_cancel','vote_open','vote_close','vote_publish','runoff_start','runoff_close') and actor_id  is distinct from  delegate_id)
    or (select count(*) from public.audit_logs where action in ('vote_schedule','vote_schedule_cancel','vote_open','vote_close','vote_publish','runoff_start','runoff_close'))  is distinct from  7 then
    raise exception 'one of seven delegate operations failed or used the wrong audit actor';
  end if;
  set local role authenticated;

  perform set_config('request.jwt.claim.sub',owner_auth,true);
  perform public.save_event_staff(delegate_id,null,null,false);
  perform set_config('request.jwt.claim.sub',delegate_auth,true);
  if public.can_manage_vote() then raise exception 'inactive delegate retained authority'; end if;
  begin perform public.manage_vote('close'); raise exception 'inactive delegate operated vote';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub',owner_auth,true);
  perform public.save_event_staff(delegate_id,null,null,true);
  perform public.set_vote_delegate(null);
  perform set_config('request.jwt.claim.sub',delegate_auth,true);
  if public.can_manage_vote() then raise exception 'revoked delegate retained authority'; end if;
  foreach statement in array array[
    'select public.schedule_vote(now(),null)', 'select public.cancel_vote_schedule()',
    'select public.manage_vote(''open'')', 'select public.manage_vote(''close'')', 'select public.manage_vote(''publish'')',
    'select public.manage_runoff(''start'')', 'select public.manage_runoff(''close'')'
  ] loop
    begin execute statement; raise exception 'revoked actor retained operation: %', statement;
    exception when insufficient_privilege then null; end;
  end loop;
  perform set_config('request.jwt.claim.sub',owner_auth,true);
  perform public.set_vote_delegate(delegate_id);
end;
$$;
reset role;
update public.members set role='participant' where id='73000000-0000-0000-0000-000000000002';
set local role authenticated;
select set_config('request.jwt.claim.sub','71000000-0000-0000-0000-000000000002',true);
do $$ begin
  if public.can_manage_vote() then raise exception 'former staff retained delegation'; end if;
  begin perform public.manage_vote('close'); raise exception 'former staff operated vote';
  exception when insufficient_privilege then null; end;
end; $$;
reset role;
do $$ begin
  if not (select relrowsecurity from pg_class where oid='private.vote_delegation'::regclass) then
    raise exception 'delegation lacks RLS';
  end if;
end; $$;
select '1..1' as tap;
select 'ok 1 - vote-only delegation, seven operations, owner-only assignment, revocation, inactive and role changes' as tap;
rollback;

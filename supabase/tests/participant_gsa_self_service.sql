begin;
insert into auth.users(id,email) select ('91000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  'self-gsa-'||i||'@example.test' from generate_series(1,7) i;
insert into public.teams(id,name) values('92000000-0000-0000-0000-000000000001','Self GSA team');
insert into public.members(id,name,email,auth_user_id,role,active,team_id)
select ('93000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,'Self GSA member '||i,
  'self-gsa-'||i||'@example.test',('91000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  case when i=1 then 'owner' when i in(2,6) then 'staff' else 'participant' end,i not in(5,6),
  case when i in(3,4) then '92000000-0000-0000-0000-000000000001'::uuid end
from generate_series(1,6) i;
update public.teams set representative_id='93000000-0000-0000-0000-000000000003'
  where id='92000000-0000-0000-0000-000000000001';

\ir fixtures/consented-members.sql
select pg_temp.consent_fixture_members('{"team":false,"presentation":false,"bingo":false}');

create temp table self_gsa_preserved(name text primary key,data jsonb);
do $$ declare relation record; begin
  for relation in select schemaname,tablename from pg_tables where schemaname in('public','private','auth','storage')
    and tablename not in('participant_operations','audit_logs') and not (schemaname='private' and tablename='operator_access_logs') loop
    execute format('insert into self_gsa_preserved select %L,jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text) from %I.%I t',
      relation.schemaname||'.'||relation.tablename,relation.schemaname,relation.tablename);
  end loop;
end; $$;

set local role authenticated;
do $$
declare
  participant_auth constant text:='91000000-0000-0000-0000-000000000003';
  staff_auth constant text:='91000000-0000-0000-0000-000000000002';
  target constant uuid:='93000000-0000-0000-0000-000000000003';
  other constant uuid:='93000000-0000-0000-0000-000000000004';
  denied_auth text;
  invalid_email text;
  record jsonb;
  own_record jsonb;
  confirmed jsonb;
  after_change jsonb;
  gsa_time timestamptz;
  attendance_time timestamptz;
  checked_at timestamptz;
  check_pair boolean[];
begin
  if to_regprocedure('public.set_participant_gsa(uuid,text,text,text,timestamptz)') is not null
    or to_regprocedure('private.set_participant_gsa(uuid,text,text,text,timestamptz)') is not null
    or has_function_privilege('anon','public.get_my_gsa()','execute')
    or has_function_privilege('service_role','public.submit_my_gsa_email(text,timestamptz)','execute')
    or has_function_privilege('anon','private.submit_my_gsa_email(text,timestamptz)','execute')
    or has_table_privilege('authenticated','private.participant_operations','select,insert,update,delete') then
    raise exception 'old verification bypass or direct access retained';
  end if;
  foreach denied_auth in array array['','91000000-0000-0000-0000-000000000001',staff_auth,
    '91000000-0000-0000-0000-000000000005','91000000-0000-0000-0000-000000000006','91000000-0000-0000-0000-000000000007'] loop
    perform set_config('request.jwt.claim.sub',denied_auth,true);
    begin perform public.get_my_gsa(); raise exception 'nonparticipant read self GSA'; exception when insufficient_privilege then null; end;
    begin perform public.submit_my_gsa_email('injected@example.test',null); raise exception 'nonparticipant submitted self GSA'; exception when insufficient_privilege then null; end;
  end loop;
  perform set_config('request.jwt.claim.sub',participant_auth,true);
  if public.get_my_gsa() is distinct from jsonb_build_object('gsa_email',null,'gsa_status','pending','gsa_updated_at',null) then
    raise exception 'self default leaks fields or invents input';
  end if;
  begin perform public.get_participant_operations(); raise exception 'participant read others GSA'; exception when insufficient_privilege then null; end;
  begin perform public.get_event_export('gsa'); raise exception 'participant exported GSA'; exception when insufficient_privilege then null; end;
  begin perform public.set_participant_gsa(other,'verified','other@example.test',null,null,true,true);
    raise exception 'participant wrote other GSA'; exception when insufficient_privilege then null; end;
  begin perform public.submit_my_gsa_email(p_email=>'other@example.test',p_expected_updated_at=>null,p_member_id=>other);
    raise exception 'self endpoint accepted another member id'; exception when undefined_function then null; end;
  foreach invalid_email in array array[null::text,'',E'\t\n','not-email','a b@example.test',repeat('a',247)||'@ex.test'] loop
    begin perform public.submit_my_gsa_email(invalid_email,null); raise exception 'invalid self email accepted';
    exception when invalid_parameter_value then null; end;
  end loop;
  perform public.submit_my_gsa_email(' FIRST-GSA@EXAMPLE.TEST ',null);
  own_record:=public.get_my_gsa();
  gsa_time:=(own_record->>'gsa_updated_at')::timestamptz;
  if own_record->>'gsa_email' is distinct from 'first-gsa@example.test' or own_record->>'gsa_status' is distinct from 'pending'
    or gsa_time is null or (select count(*) from jsonb_object_keys(own_record)) is distinct from 3 then
    raise exception 'self submission or minimized payload incorrect';
  end if;
  perform public.submit_my_gsa_email('first-gsa@example.test',null);
  if public.get_my_gsa() is distinct from own_record then raise exception 'identical participant retry changed stamp'; end if;

  perform set_config('request.jwt.claim.sub',staff_auth,true);
  perform public.set_participant_attendance(target,'present','Private attendance note',null);
  select value into record from jsonb_array_elements(public.get_participant_operations()) where value->>'member_id'=target::text;
  attendance_time:=(record->>'attendance_updated_at')::timestamptz;
  checked_at:=(record->>'checked_in_at')::timestamptz;
  if record->>'gsa_plus_active' is distinct from 'false' or record->>'gsa_email_matched' is distinct from 'false'
    or (record->>'gsa_updated_at')::timestamptz is distinct from gsa_time then raise exception 'self checks initialized incorrectly or attendance changed GSA'; end if;
  perform public.set_participant_gsa(target,'pending','first-gsa@example.test','INTERNAL ONLY NOTE',gsa_time,false,false);
  select value into record from jsonb_array_elements(public.get_participant_operations()) where value->>'member_id'=target::text;
  gsa_time:=(record->>'gsa_updated_at')::timestamptz;
  begin perform public.set_participant_gsa(target,'pending','first-gsa@example.test','INTERNAL ONLY NOTE',gsa_time,true,true);
    raise exception 'pending status retained completed evidence'; exception when invalid_parameter_value then null; end;
  begin perform public.set_participant_gsa(target,'failed','first-gsa@example.test','INTERNAL ONLY NOTE',gsa_time,true,false);
    raise exception 'failed status retained partial evidence'; exception when invalid_parameter_value then null; end;
  foreach check_pair slice 1 in array array[array[false,false],array[true,false],array[false,true],array[null::boolean,true]] loop
    begin perform public.set_participant_gsa(target,'verified','first-gsa@example.test','INTERNAL ONLY NOTE',gsa_time,check_pair[1],check_pair[2]);
      raise exception 'incomplete evidence accepted'; exception when invalid_parameter_value then null; end;
  end loop;
  begin perform public.set_participant_gsa(target,'verified',null,'INTERNAL ONLY NOTE',gsa_time,true,true);
    raise exception 'verified without saved email'; exception when invalid_parameter_value then null; end;
  begin perform public.set_participant_gsa(target,'verified','replacement@example.test','INTERNAL ONLY NOTE',gsa_time,true,true);
    raise exception 'corrected email verified in same operation'; exception when invalid_parameter_value then null; end;
  perform public.set_participant_gsa(target,'verified','first-gsa@example.test','INTERNAL ONLY NOTE',gsa_time,true,true);
  select value into confirmed from jsonb_array_elements(public.get_participant_operations()) where value->>'member_id'=target::text;
  if confirmed->>'gsa_status' is distinct from 'verified' or confirmed->>'gsa_plus_active' is distinct from 'true'
    or confirmed->>'gsa_email_matched' is distinct from 'true' then raise exception 'two-check completion failed'; end if;
  perform set_config('request.jwt.claim.sub',participant_auth,true);
  own_record:=public.get_my_gsa();
  if own_record->>'gsa_status' is distinct from 'verified' or (select count(*) from jsonb_object_keys(own_record)) is distinct from 3
    or own_record::text like '%INTERNAL%' or own_record::text like '%Self GSA member 2%' then raise exception 'verification status missing or private context exposed'; end if;
  perform public.submit_my_gsa_email(' FIRST-GSA@example.test ',null);
  if public.get_my_gsa() is distinct from own_record then raise exception 'same email reset completed verification'; end if;
  begin perform public.submit_my_gsa_email('next-gsa@example.test',gsa_time); raise exception 'stale self email update accepted';
  exception when invalid_parameter_value then null; end;
  perform public.submit_my_gsa_email('next-gsa@example.test',(own_record->>'gsa_updated_at')::timestamptz);
  after_change:=public.get_my_gsa();
  if after_change->>'gsa_email' is distinct from 'next-gsa@example.test' or after_change->>'gsa_status' is distinct from 'pending'
    or (after_change->>'gsa_updated_at')::timestamptz <= (own_record->>'gsa_updated_at')::timestamptz then
    raise exception 'email change did not create fresh pending revision';
  end if;
  perform set_config('request.jwt.claim.sub',staff_auth,true);
  select value into record from jsonb_array_elements(public.get_participant_operations()) where value->>'member_id'=target::text;
  if record->>'gsa_plus_active' is distinct from 'false' or record->>'gsa_email_matched' is distinct from 'false'
    or record->>'gsa_note' is distinct from 'INTERNAL ONLY NOTE' or record->>'attendance_note' is distinct from 'Private attendance note'
    or (record->>'attendance_updated_at')::timestamptz is distinct from attendance_time
    or (record->>'checked_in_at')::timestamptz is distinct from checked_at then raise exception 'self edit lost internal notes, attendance or old checks'; end if;
  begin perform public.set_participant_gsa(target,'verified','next-gsa@example.test','INTERNAL ONLY NOTE',(own_record->>'gsa_updated_at')::timestamptz,true,true);
    raise exception 'stale staff verification accepted'; exception when invalid_parameter_value then null; end;
  begin perform public.set_participant_gsa(target,'failed','staff-corrected@example.test','INTERNAL ONLY NOTE',(record->>'gsa_updated_at')::timestamptz,false,false);
    raise exception 'email correction avoided pending'; exception when invalid_parameter_value then null; end;
  perform public.set_participant_gsa(target,'pending','staff-corrected@example.test','INTERNAL ONLY NOTE',(record->>'gsa_updated_at')::timestamptz,false,false);
  select value into record from jsonb_array_elements(public.get_participant_operations()) where value->>'member_id'=target::text;
  perform public.set_participant_gsa(target,'verified','staff-corrected@example.test','INTERNAL ONLY NOTE',(record->>'gsa_updated_at')::timestamptz,true,true);
  select value into record from jsonb_array_elements(public.get_participant_operations()) where value->>'member_id'=target::text;
  gsa_time:=(record->>'gsa_updated_at')::timestamptz;
  perform public.set_participant_attendance(target,'late','Private attendance note',attendance_time);
  perform set_config('request.jwt.claim.sub',participant_auth,true);
  perform public.submit_my_gsa_email('domain-independent@example.test',gsa_time);
  if public.get_my_gsa()->>'gsa_status' is distinct from 'pending' then raise exception 'attendance revision interfered with GSA email domain'; end if;
  perform set_config('request.jwt.claim.sub','91000000-0000-0000-0000-000000000004',true);
  if public.get_my_gsa()->>'gsa_email' is not null then raise exception 'second participant read first participant email'; end if;
  perform public.submit_my_gsa_email(repeat('a',246)||'@ex.test',null);
  if char_length(public.get_my_gsa()->>'gsa_email') is distinct from 254 then raise exception '254-char email rejected'; end if;
end;
$$;
reset role;

-- Preserve microseconds exactly. A millisecond-truncated client revision must fail.
update private.participant_operations set gsa_updated_at='2030-01-01 00:00:00.123456+00'
  where member_id='93000000-0000-0000-0000-000000000003';
set local role authenticated;
select set_config('request.jwt.claim.sub','91000000-0000-0000-0000-000000000003',true);
do $$ declare stamp timestamptz; begin
  stamp:=(public.get_my_gsa()->>'gsa_updated_at')::timestamptz;
  begin perform public.submit_my_gsa_email('precision@example.test',date_trunc('milliseconds',stamp)); raise exception 'rounded revision accepted';
  exception when invalid_parameter_value then null; end;
  perform public.submit_my_gsa_email('precision@example.test',stamp);
  if (public.get_my_gsa()->>'gsa_updated_at')::timestamptz is distinct from stamp+interval '1 microsecond' then
    raise exception 'server revision lost precision or monotonicity';
  end if;
end; $$;
reset role;
do $$ declare saved record; actual jsonb; begin
  for saved in select * from self_gsa_preserved loop
    execute format('select jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text) from %s t',saved.name) into actual;
    if actual is distinct from saved.data then raise exception 'self GSA changed protected table %',saved.name; end if;
  end loop;
  if not exists(select 1 from public.audit_logs where action='participant_gsa_email_submitted'
    and actor_id=target_id and details->'before'->>'status'='verified' and details->'before'->>'plus_active'='true'
    and details->'after'->>'status'='pending' and details->'after'->>'plus_active'='false'
    and details->'after'->>'email_matched'='false') then raise exception 'old completed verification missing from audit'; end if;
  if exists(select 1 from public.audit_logs where action='participant_gsa_email_submitted' and actor_id is distinct from target_id) then
    raise exception 'self write targeted another participant'; end if;
  if (select attendance_status from private.participant_operations where member_id='93000000-0000-0000-0000-000000000003') is distinct from 'late'
    or (select gsa_note from private.participant_operations where member_id='93000000-0000-0000-0000-000000000003') is distinct from 'INTERNAL ONLY NOTE' then
    raise exception 'self writes changed private notes or attendance';
  end if;
end; $$;
do $$ begin
  if not exists(select 1 from private.operator_access_logs where operation='read' and resource='get_participant_operations'
    and actor_login='self-gsa-2@example.test' and '93000000-0000-0000-0000-000000000003'::uuid=any(subject_ids))
    or exists(select 1 from private.operator_access_logs l left join public.members m on m.id=l.actor_id
      where m.id is null or m.role not in('owner','staff') or l.actor_login is distinct from m.email
        or l.retain_until<l.created_at+interval '1 year') then raise exception 'operator read audit missing or invalid'; end if;
end; $$;
select '1..1' as tap;
select 'ok 1 - participant self email, two staff evidence checks, old RPC removal, privacy, exact revisions and protected data' as tap;
rollback;

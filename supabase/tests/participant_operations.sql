begin;
insert into auth.users(id,email) select ('81000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  'operations-'||i||'@example.test' from generate_series(1,7) i;
insert into public.teams(id,name) values('82000000-0000-0000-0000-000000000001','Operations A'),('82000000-0000-0000-0000-000000000002','Operations B');
insert into public.members(id,name,email,auth_user_id,role,active,team_id)
select ('83000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,'Operations member '||i,'operations-'||i||'@example.test',
  ('81000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  case when i=1 then 'owner' when i in(2,5) then 'staff' else 'participant' end,i not in(5,7),
  case when i in(3,4) then ('82000000-0000-0000-0000-'||lpad((i-2)::text,12,'0'))::uuid end
from generate_series(1,7) i where i<>6;
update public.teams set representative_id='83000000-0000-0000-0000-000000000003' where id='82000000-0000-0000-0000-000000000001';

\ir fixtures/consented-members.sql
select pg_temp.consent_fixture_members('{"team":false,"presentation":false,"bingo":false}');

set local role authenticated;
do $$
declare denied_auth text; export_kind text; rows jsonb;
begin
  if has_table_privilege('authenticated','private.participant_operations','select,insert,update,delete')
    or has_table_privilege('anon','private.participant_operations','select,insert,update,delete')
    or has_table_privilege('service_role','private.participant_operations','select,insert,update,delete')
    or has_function_privilege('anon','public.get_participant_operations()','execute')
    or has_function_privilege('anon','public.get_event_export(text)','execute')
    or has_function_privilege('service_role','public.set_participant_gsa(uuid,text,text,text,timestamptz,boolean,boolean)','execute') then
    raise exception 'operational data is directly exposed';
  end if;
  foreach denied_auth in array array['','81000000-0000-0000-0000-000000000003',
    '81000000-0000-0000-0000-000000000005','81000000-0000-0000-0000-000000000006'] loop
    perform set_config('request.jwt.claim.sub',denied_auth,true);
    begin perform public.get_participant_operations(); raise exception 'unauthorized operations read'; exception when insufficient_privilege then null; end;
    begin perform public.set_participant_gsa('83000000-0000-0000-0000-000000000003','verified',null,null,null,true,true);
      raise exception 'unauthorized GSA write'; exception when insufficient_privilege then null; end;
    begin perform public.set_participant_attendance('83000000-0000-0000-0000-000000000003','present',null,null);
      raise exception 'unauthorized attendance write'; exception when insufficient_privilege then null; end;
    foreach export_kind in array array['teams','attendance','gsa','bingo','voting','awards'] loop
      begin perform public.get_event_export(export_kind); raise exception 'unauthorized export: %',export_kind;
      exception when insufficient_privilege then null; end;
    end loop;
  end loop;
  perform set_config('request.jwt.claim.sub','81000000-0000-0000-0000-000000000002',true);
  rows:=public.get_participant_operations();
  if jsonb_array_length(rows) is distinct from 3 or exists(select 1 from jsonb_array_elements(rows) p
    where p->>'gsa_status' is distinct from 'pending' or p->>'attendance_status' is distinct from 'pending'
      or p->>'gsa_updated_at' is not null or p->>'attendance_updated_at' is not null or p ? 'auth_user_id') then
    raise exception 'default participant operations projection incorrect';
  end if;
  perform public.set_participant_gsa('83000000-0000-0000-0000-000000000003','pending','',E'\n\t',null,false,false);
  perform public.set_participant_attendance('83000000-0000-0000-0000-000000000003','pending','',null);
  perform public.get_event_export('teams'); perform public.get_event_export('attendance');
  perform public.get_event_export('gsa'); perform public.get_event_export('bingo');
end;
$$;
reset role;
do $$ begin
  if exists(select 1 from private.participant_operations) or exists(select 1 from public.audit_logs where action like 'participant_%_changed') then
    raise exception 'reads or initial no-op created operations/audit records';
  end if;
end; $$;

create temp table operations_preserved(name text primary key,data jsonb);
do $$ declare relation record; begin
  for relation in select schemaname,tablename from pg_tables where schemaname in('public','private','auth','storage')
    and tablename not in('participant_operations','audit_logs') and not (schemaname='private' and tablename='operator_access_logs') loop
    execute format('insert into operations_preserved select %L,jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text) from %I.%I t',
      relation.schemaname||'.'||relation.tablename,relation.schemaname,relation.tablename);
  end loop;
end; $$;

set local role authenticated;
do $$
declare
  target constant uuid:='83000000-0000-0000-0000-000000000003';
  other constant uuid:='83000000-0000-0000-0000-000000000004';
  record jsonb;
  previous_record jsonb;
  gsa_time timestamptz;
  attendance_time timestamptz;
  first_checkin timestamptz;
  audit_count integer;
  invalid_status text;
begin
  perform set_config('request.jwt.claim.sub','81000000-0000-0000-0000-000000000002',true);
  foreach invalid_status in array array[null::text,'accepted','present'] loop
    begin perform public.set_participant_gsa(target,invalid_status,null,null,null,false,false); raise exception 'invalid GSA status accepted';
    exception when invalid_parameter_value then null; end;
  end loop;
  foreach invalid_status in array array[null::text,'checked','verified'] loop
    begin perform public.set_participant_attendance(target,invalid_status,null,null); raise exception 'invalid attendance status accepted';
    exception when invalid_parameter_value then null; end;
  end loop;
  begin perform public.set_participant_gsa(target,'verified','invalid-email',null,null,true,true); raise exception 'invalid GSA email accepted'; exception when invalid_parameter_value then null; end;
  begin perform public.set_participant_gsa(target,'verified',null,repeat('x',501),null,true,true); raise exception 'oversized GSA note accepted'; exception when invalid_parameter_value then null; end;
  begin perform public.set_participant_attendance(target,'present',repeat('x',501),null); raise exception 'oversized attendance note accepted'; exception when invalid_parameter_value then null; end;
  begin perform public.set_participant_gsa('83000000-0000-0000-0000-000000000001','verified',null,null,null,true,true); raise exception 'owner target accepted'; exception when invalid_parameter_value then null; end;
  begin perform public.set_participant_attendance('83000000-0000-0000-0000-000000000099','present',null,null); raise exception 'missing target accepted'; exception when invalid_parameter_value then null; end;
  perform public.set_participant_gsa(target,'pending',' GSA-OTHER@EXAMPLE.TEST ','Observed registration',null,false,false);
  select (value->>'gsa_updated_at')::timestamptz into gsa_time from jsonb_array_elements(public.get_participant_operations()) where value->>'member_id'=target::text;
  perform public.set_participant_gsa(target,'verified',' GSA-OTHER@EXAMPLE.TEST ','Observed registration',gsa_time,true,true);
  select value into record from jsonb_array_elements(public.get_participant_operations()) where value->>'member_id'=target::text;
  gsa_time:=(record->>'gsa_updated_at')::timestamptz;
  if record->>'gsa_status' is distinct from 'verified' or record->>'gsa_email' is distinct from 'gsa-other@example.test'
    or record->>'email' is distinct from 'operations-3@example.test' or gsa_time is null
    or record->>'gsa_updated_by_name' is distinct from 'Operations member 2' then raise exception 'GSA state or separate identity incorrect'; end if;
  reset role;
  select count(*) into audit_count from public.audit_logs where action='participant_gsa_changed';
  set local role authenticated;
  perform public.set_participant_gsa(target,'verified','gsa-other@example.test','Observed registration',null,true,true);
  select value into previous_record from jsonb_array_elements(public.get_participant_operations()) where value->>'member_id'=target::text;
  -- Inspect persisted audit state as the fixture owner; clients use logged RPCs.
  reset role;
  if record is distinct from previous_record or audit_count is distinct from (select count(*) from public.audit_logs where action='participant_gsa_changed') then
    raise exception 'identical GSA retry changed record/audit';
  end if;
  set local role authenticated;
  perform public.set_participant_attendance(target,'present','Desk check-in',null);
  select value into record from jsonb_array_elements(public.get_participant_operations()) where value->>'member_id'=target::text;
  attendance_time:=(record->>'attendance_updated_at')::timestamptz;
  first_checkin:=(record->>'checked_in_at')::timestamptz;
  if first_checkin is null or attendance_time is null or (record->>'gsa_updated_at')::timestamptz is distinct from gsa_time
    or record->>'gsa_email' is distinct from 'gsa-other@example.test' then raise exception 'attendance clobbered GSA or missed check-in'; end if;
  previous_record:=record;
  reset role;
  select count(*) into audit_count from public.audit_logs where action='participant_attendance_changed';
  set local role authenticated;
  perform public.set_participant_attendance(target,'present','Desk check-in',null);
  select value into record from jsonb_array_elements(public.get_participant_operations()) where value->>'member_id'=target::text;
  -- Inspect persisted audit state as the fixture owner; clients use logged RPCs.
  reset role;
  if record is distinct from previous_record or audit_count is distinct from (select count(*) from public.audit_logs where action='participant_attendance_changed') then
    raise exception 'identical attendance retry changed record/audit';
  end if;
  set local role authenticated;
  perform set_config('request.jwt.claim.sub','81000000-0000-0000-0000-000000000001',true);
  perform public.set_participant_gsa(target,'failed','gsa-other@example.test','Needs another check',gsa_time,false,false);
  select value into record from jsonb_array_elements(public.get_participant_operations()) where value->>'member_id'=target::text;
  if record->>'gsa_status' is distinct from 'failed' or record->>'gsa_updated_by_name' is distinct from 'Operations member 1'
    or (record->>'attendance_updated_at')::timestamptz is distinct from attendance_time
    or (record->>'checked_in_at')::timestamptz is distinct from first_checkin then raise exception 'GSA write clobbered attendance'; end if;
  previous_record:=record;
  begin perform public.set_participant_gsa(target,'verified','gsa-other@example.test','Stale overwrite',gsa_time,true,true); raise exception 'stale GSA update accepted'; exception when invalid_parameter_value then null; end;
  begin perform public.set_participant_attendance(target,'late','Stale overwrite',null); raise exception 'stale attendance update accepted'; exception when invalid_parameter_value then null; end;
  select value into record from jsonb_array_elements(public.get_participant_operations()) where value->>'member_id'=target::text;
  if record is distinct from previous_record then raise exception 'stale request partially changed data'; end if;
  perform public.set_participant_attendance(target,'late','Delayed arrival',attendance_time);
  select value into record from jsonb_array_elements(public.get_participant_operations()) where value->>'member_id'=target::text;
  if (record->>'checked_in_at')::timestamptz is distinct from first_checkin then raise exception 'late correction reset original check-in'; end if;
  perform public.set_participant_attendance(target,'absent','Mistaken check-in',(record->>'attendance_updated_at')::timestamptz);
  select value into record from jsonb_array_elements(public.get_participant_operations()) where value->>'member_id'=target::text;
  if record->>'checked_in_at' is not null then raise exception 'absent correction retained a current check-in'; end if;
  perform public.set_participant_attendance(target,'present',null,(record->>'attendance_updated_at')::timestamptz);
  select value into record from jsonb_array_elements(public.get_participant_operations()) where value->>'member_id'=target::text;
  if record->>'checked_in_at' is null or (record->>'checked_in_at')::timestamptz<=first_checkin then raise exception 'new check-in time missing'; end if;
  perform public.set_participant_attendance(target,'pending',null,(record->>'attendance_updated_at')::timestamptz);
  perform public.set_participant_gsa(other,'pending',repeat('a',246)||'@ex.test',repeat('n',500),null,false,false);
  perform public.set_participant_attendance(other,'late',repeat('n',500),null);
  select value into record from jsonb_array_elements(public.get_participant_operations()) where value->>'member_id'=other::text;
  if char_length(record->>'gsa_email') is distinct from 254 or char_length(record->>'gsa_note') is distinct from 500
    or char_length(record->>'attendance_note') is distinct from 500 then raise exception 'exact input bounds rejected'; end if;
  begin perform public.set_participant_gsa(other,'verified',repeat('a',247)||'@ex.test',null,(record->>'gsa_updated_at')::timestamptz,true,true);
    raise exception 'email beyond bound accepted'; exception when invalid_parameter_value then null; end;
  perform public.set_participant_gsa('83000000-0000-0000-0000-000000000007','pending','inactive-gsa@example.test',null,null,false,false);
  select (value->>'gsa_updated_at')::timestamptz into gsa_time from jsonb_array_elements(public.get_participant_operations()) where value->>'member_id'='83000000-0000-0000-0000-000000000007';
  perform public.set_participant_gsa('83000000-0000-0000-0000-000000000007','verified','inactive-gsa@example.test',null,gsa_time,true,true);
  perform public.set_participant_attendance('83000000-0000-0000-0000-000000000007','absent',null,null);
end;
$$;
reset role;
do $$
declare saved record; actual jsonb;
begin
  for saved in select * from operations_preserved loop
    execute format('select jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text) from %s t',saved.name) into actual;
    if actual is distinct from saved.data then raise exception 'operations changed protected table %',saved.name; end if;
  end loop;
  if not (select relrowsecurity from pg_class where oid='private.participant_operations'::regclass)
    or exists(select 1 from public.audit_logs where action in('participant_gsa_changed','participant_attendance_changed')
      and (not(details ? 'before') or not(details ? 'after') or actor_id is null)) then raise exception 'RLS or audit transitions missing'; end if;
  if not exists(select 1 from public.audit_logs where action='participant_attendance_changed'
    and details->'before'->>'checked_in_at' is not null and details->'after'->>'status'='absent'
    and details->'after'->>'checked_in_at' is null) then raise exception 'corrected check-in history was not retained'; end if;
end;
$$;
do $$ begin
  if not exists(select 1 from private.operator_access_logs where operation='read' and resource='get_participant_operations'
    and actor_login='operations-2@example.test' and '83000000-0000-0000-0000-000000000003'::uuid=any(subject_ids))
    or exists(select 1 from private.operator_access_logs l left join public.members m on m.id=l.actor_id
      where m.id is null or m.role not in('owner','staff') or l.actor_login is distinct from m.email
        or l.retain_until<l.created_at+interval '1 year') then raise exception 'operator read audit missing or invalid'; end if;
end; $$;
select '1..1' as tap;
select 'ok 1 - staff-only operational checks, independent stale guards, idempotent saves, check-in corrections and protected data preservation' as tap;
rollback;

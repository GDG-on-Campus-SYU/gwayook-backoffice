begin;
insert into auth.users(id,email) select ('84000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  'export-'||i||'@example.test' from generate_series(1,7) i;
insert into public.teams(id,name) select ('85000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  'Export team '||i from generate_series(1,4) i;
insert into public.members(id,name,email,auth_user_id,role,active,team_id)
select ('86000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,'Export member '||i,'export-'||i||'@example.test',
  ('84000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  case when i=1 then 'owner' when i=2 then 'staff' else 'participant' end,i<>7,
  case when i between 3 and 6 then ('85000000-0000-0000-0000-'||lpad(least(i-2,3)::text,12,'0'))::uuid end
from generate_series(1,7) i;
insert into public.members(id,name,email,role,team_id)
select ('86000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,'Bingo confirmer '||i,'export-confirmer-'||i||'@example.test',
  'participant','85000000-0000-0000-0000-000000000003' from generate_series(10,24) i;
update public.teams set representative_id='86000000-0000-0000-0000-000000000003' where id='85000000-0000-0000-0000-000000000001';
update public.event_settings set vote_closes_at=now()+interval '1 hour' where id;
update private.bingo_rounds set questions=array(select 'Question '||i from generate_series(1,25)i),
  opens_at=now()-interval '50 minutes',closes_at=now()-interval '20 minutes',closed_at=now()-interval '25 minutes' where round_no=1;
insert into private.bingo_rounds(round_no,questions,prize,opens_at,closes_at)
  select 2,questions,prize,now()-interval '10 minutes',now()+interval '20 minutes' from private.bingo_rounds where round_no=1;
update private.bingo_game set round_no=2,questions=array(select 'Question '||i from generate_series(1,25)i),
  opens_at=now()-interval '10 minutes',closes_at=now()+interval '20 minutes',closed_at=null where id;
insert into private.bingo_boards(round_no,member_id,question_order,completed_at,completed_team_id,completed_team_name)
select 1,('86000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,array(select generate_series(1,25)),
  now()-interval '47 minutes'+case when i=5 then interval '1 minute' else interval '0 minutes' end,
  ('85000000-0000-0000-0000-'||lpad((i-2)::text,12,'0'))::uuid,'Recorded team '||(i-2) from generate_series(3,5)i;
insert into private.bingo_boards(round_no,member_id,question_order)
  values(2,'86000000-0000-0000-0000-000000000003',array(select generate_series(1,25)));
insert into private.bingo_marks(round_no,member_id,cell,confirmed_by,confirmed_at,suspicious)
select 1,b.member_id,n,('86000000-0000-0000-0000-'||lpad((n+10)::text,12,'0'))::uuid,
  b.completed_at-(14-n)*interval '1 second',n>=2 from private.bingo_boards b cross join generate_series(0,14)n where b.round_no=1;
insert into private.bingo_requests(token,code,round_no,member_id,cell,expires_at)
  values('87000000-0000-0000-0000-000000000001','ABCDEF012345',2,'86000000-0000-0000-0000-000000000003',0,now()+interval '1 minute');

\ir fixtures/consented-members.sql
select pg_temp.consent_fixture_members('{"team":false,"presentation":false,"bingo":false}');

create temp table exports_preserved(name text primary key,data jsonb);
create temp table export_access_before as select * from private.operator_access_logs with no data;
create function pg_temp.capture_export_state() returns void language plpgsql as $$ declare relation record; begin
  truncate exports_preserved,export_access_before;
  insert into export_access_before select * from private.operator_access_logs;
  for relation in select schemaname,tablename from pg_tables where schemaname in('public','private','auth','storage') and not (schemaname='private' and tablename='operator_access_logs') loop
    execute format('insert into exports_preserved select %L,jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text) from %I.%I t',
      relation.schemaname||'.'||relation.tablename,relation.schemaname,relation.tablename);
  end loop;
end; $$;
create function pg_temp.assert_export_state(expected_exports integer,expected_reads integer) returns void language plpgsql as $$ declare saved record; actual jsonb; begin
  for saved in select * from exports_preserved loop
    execute format('select jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text) from %s t',saved.name) into actual;
    if actual is distinct from saved.data then raise exception 'export mutated %',saved.name; end if;
  end loop;
  if exists(select * from export_access_before except select * from private.operator_access_logs)
    or (select count(*) from private.operator_access_logs where id>(select coalesce(max(id),0) from export_access_before))
      <> expected_exports+expected_reads
    or (select count(*) from private.operator_access_logs where id>(select coalesce(max(id),0) from export_access_before)
      and operation='export' and resource='get_event_export') <> expected_exports
    or exists(select 1 from private.operator_access_logs l where id>(select coalesce(max(id),0) from export_access_before)
      and (actor_login not in('export-1@example.test','export-2@example.test') or permission_change or operation not in('read','export')
        or retain_until<created_at+interval '1 year'
        or (operation='read' and resource not in('get_participant_operations','get_bingo_round','get_vote_details')))) then
    raise exception 'export access audit changed, missing or logged a rejected export';
  end if;
end; $$;
create function pg_temp.assert_export_shape(payload jsonb,kind text,width integer) returns void language plpgsql as $$ begin
  if payload->>'kind' is distinct from kind or jsonb_typeof(payload->'headers') is distinct from 'array'
    or jsonb_array_length(payload->'headers') is distinct from width or jsonb_typeof(payload->'rows') is distinct from 'array'
    or exists(select 1 from jsonb_array_elements(payload->'rows') r where jsonb_typeof(r) is distinct from 'array' or jsonb_array_length(r) is distinct from width)
    or exists(select 1 from jsonb_array_elements(payload->'rows') r cross join lateral jsonb_array_elements(r) c
      where jsonb_typeof(c) not in('string','number','null')) then raise exception 'invalid CSV shape: %',kind; end if;
  if payload::text ~ '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    or payload::text like '%ABCDEF012345%' or payload::text like '%auth_user_id%' or payload::text like '%choice_id%' then
    raise exception 'internal identity, ballot choice or QR secret exported: %',kind;
  end if;
end; $$;

set local role authenticated;
select set_config('request.jwt.claim.sub','84000000-0000-0000-0000-000000000002',true);
select public.set_participant_gsa('86000000-0000-0000-0000-000000000003','pending','distinct-gsa@example.test','=GSA evidence',null,false,false);
select public.set_participant_gsa('86000000-0000-0000-0000-000000000003','verified','distinct-gsa@example.test','=GSA evidence',
  (select (value->>'gsa_updated_at')::timestamptz from jsonb_array_elements(public.get_participant_operations()) where value->>'member_id'='86000000-0000-0000-0000-000000000003'),true,true);
select public.set_participant_attendance('86000000-0000-0000-0000-000000000003','present','Desk, note "quoted"',null);
select public.set_participant_attendance('86000000-0000-0000-0000-000000000004','absent',null,null);
reset role;
select pg_temp.capture_export_state();
set local role authenticated;
do $$ declare payload jsonb; row_data jsonb; begin
  payload:=public.get_event_export('teams'); perform pg_temp.assert_export_shape(payload,'teams',7);
  if jsonb_array_length(payload->'rows') is distinct from 21
    or not exists(select 1 from jsonb_array_elements(payload->'rows') r where r->>0='Export team 4' and r->>3 is null)
    or not exists(select 1 from jsonb_array_elements(payload->'rows') r where r->>0='미배정' and r->>4='export-7@example.test') then
    raise exception 'empty or unassigned team roster missing'; end if;
  payload:=public.get_event_export('attendance'); perform pg_temp.assert_export_shape(payload,'attendance',10);
  select r into row_data from jsonb_array_elements(payload->'rows') r where r->>1='export-4@example.test';
  if row_data->>4 is distinct from '불참' or row_data->>5 is not null then raise exception 'attendance status/check-in export incorrect'; end if;
  payload:=public.get_event_export('gsa'); perform pg_temp.assert_export_shape(payload,'gsa',11);
  select r into row_data from jsonb_array_elements(payload->'rows') r where r->>1='export-3@example.test';
  if row_data->>4 is distinct from 'distinct-gsa@example.test' or row_data->>5 is distinct from '확인 완료'
    or row_data->>6 is distinct from '확인' or row_data->>7 is distinct from '확인'
    or row_data->>8 is distinct from '=GSA evidence' then raise exception 'separate GSA email, verification checks or raw CSV cell changed'; end if;
  payload:=public.get_event_export('bingo'); perform pg_temp.assert_export_shape(payload,'bingo',11);
  if jsonb_array_length(payload->'rows') is distinct from 4 then raise exception 'bingo rounds not exported'; end if;
  select r into row_data from jsonb_array_elements(payload->'rows') r where r->>0='1' and r->>2='export-3@example.test';
  if row_data->>3 is distinct from '15' or row_data->>4 is distinct from '3' or row_data->>5 is distinct from '1'
    or row_data->>6 is distinct from '2' or row_data->>9 is distinct from 'Recorded team 1' or row_data->>10 is distinct from '13' then
    raise exception 'bingo rank, tie, historic team or flags incorrect: %',row_data; end if;
  select r into row_data from jsonb_array_elements(payload->'rows') r where r->>0='2';
  if row_data->>3 is distinct from '0' or row_data->>5 is not null or row_data->>9 is not null then raise exception 'unfinished new round fabricated completion'; end if;
  begin perform public.get_event_export('voting'); raise exception 'draft voting exported'; exception when invalid_parameter_value then null; end;
  begin perform public.get_event_export('awards'); raise exception 'draft awards exported'; exception when invalid_parameter_value then null; end;
  begin perform public.get_event_export('votes_private'); raise exception 'unknown export accepted'; exception when invalid_parameter_value then null; end;
end; $$;
reset role;
select pg_temp.assert_export_state(4,4);

set local role authenticated;
select set_config('request.jwt.claim.sub','84000000-0000-0000-0000-000000000001',true);
-- The attendee previously marked absent arrives late before voting starts.
select public.set_participant_attendance('86000000-0000-0000-0000-000000000004','late',null,
  (select (value->>'attendance_updated_at')::timestamptz from jsonb_array_elements(public.get_participant_operations())
    where value->>'member_id'='86000000-0000-0000-0000-000000000004'));
select public.set_participant_attendance('86000000-0000-0000-0000-000000000005','present',null,null);
select public.set_participant_attendance('86000000-0000-0000-0000-000000000006','present',null,null);
select public.manage_vote('open',array['85000000-0000-0000-0000-000000000001'::uuid,'85000000-0000-0000-0000-000000000002'::uuid,'85000000-0000-0000-0000-000000000003'::uuid]);
select public.set_gemini_bonus('85000000-0000-0000-0000-000000000002',true,'Visual artifact checked');
select set_config('request.jwt.claim.sub','84000000-0000-0000-0000-000000000003',true);
select public.cast_vote('85000000-0000-0000-0000-000000000002');
select set_config('request.jwt.claim.sub','84000000-0000-0000-0000-000000000004',true);
select public.cast_vote('85000000-0000-0000-0000-000000000001');
select set_config('request.jwt.claim.sub','84000000-0000-0000-0000-000000000005',true);
select public.cast_vote('85000000-0000-0000-0000-000000000001');
select set_config('request.jwt.claim.sub','84000000-0000-0000-0000-000000000006',true);
select public.cast_vote('85000000-0000-0000-0000-000000000002');
select set_config('request.jwt.claim.sub','84000000-0000-0000-0000-000000000002',true);
-- Both teams have 2 votes. Only the combined Gemini and bingo scores tie them at 4.
select public.set_bingo_bonus('85000000-0000-0000-0000-000000000001',2,0);
select public.set_bingo_bonus('85000000-0000-0000-0000-000000000002',1,0);
reset role;
select pg_temp.capture_export_state();
set local role authenticated;
do $$ begin
  begin perform public.get_event_export('voting'); raise exception 'live voting exported'; exception when invalid_parameter_value then null; end;
  begin perform public.get_event_export('awards'); raise exception 'live awards exported'; exception when invalid_parameter_value then null; end;
end; $$;
reset role;
select pg_temp.assert_export_state(0,0);
update public.event_settings set vote_opens_at=now()-interval '2 minutes',vote_closes_at=now()-interval '1 minute' where id;
select pg_temp.capture_export_state();
set local role authenticated;
do $$ begin
  begin perform public.get_event_export('voting'); raise exception 'expired unclosed voting exported'; exception when invalid_parameter_value then null; end;
end; $$;
reset role;
select pg_temp.assert_export_state(0,0);
set local role authenticated;
select set_config('request.jwt.claim.sub','84000000-0000-0000-0000-000000000001',true);
select public.manage_vote('close');
select public.manage_runoff('start',array['85000000-0000-0000-0000-000000000001'::uuid,'85000000-0000-0000-0000-000000000002'::uuid],clock_timestamp()+interval '5 minutes');
do $$ begin
  if public.get_bingo_bonuses()->>'locked' is distinct from 'true'
    or public.get_vote_details()->'runoff'->>'main_score' is distinct from '4' then
    raise exception 'first runoff did not retain the combined score or lock bingo bonuses';
  end if;
  begin perform public.set_bingo_bonus('85000000-0000-0000-0000-000000000002',0,1);
    raise exception 'bingo points changed after runoff started';
  exception when invalid_parameter_value then null; end;
end; $$;
select set_config('test.export_runoff',(public.get_vote_details()->'runoff'->>'id'),true);
select set_config('request.jwt.claim.sub','84000000-0000-0000-0000-000000000005',true);
select public.cast_runoff_vote(current_setting('test.export_runoff')::uuid,'85000000-0000-0000-0000-000000000002');
select set_config('request.jwt.claim.sub','84000000-0000-0000-0000-000000000002',true);
reset role;
select pg_temp.capture_export_state();
set local role authenticated;
do $$ declare payload jsonb; row_data jsonb; begin
  payload:=public.get_event_export('voting'); perform pg_temp.assert_export_shape(payload,'voting',9);
  if jsonb_array_length(payload->'rows') is distinct from 3 or payload::text like '%export-%@example.test%' then raise exception 'aggregate export exposed voter identities'; end if;
  select r into row_data from jsonb_array_elements(payload->'rows') r where r->>0='Export team 2';
  if row_data->>1 is distinct from '2' or row_data->>2 is distinct from '1' or row_data->>3 is distinct from '4'
    or row_data->>4 is not null or payload->'headers'->>8 is distinct from '빙고 가산점' or row_data->>8 is distinct from '1'
    then raise exception 'raw/bonus totals wrong or live runoff votes exposed'; end if;
  begin perform public.get_event_export('awards'); raise exception 'unpublished awards exported'; exception when invalid_parameter_value then null; end;
end; $$;
reset role;
select pg_temp.assert_export_state(1,1);
set local role authenticated;
select set_config('request.jwt.claim.sub','84000000-0000-0000-0000-000000000001',true);
select public.manage_runoff('close',null,null,current_setting('test.export_runoff')::uuid);
select public.manage_vote('publish',null,'[{"team_id":"85000000-0000-0000-0000-000000000002","award_name":"First"},{"team_id":"85000000-0000-0000-0000-000000000001","award_name":"Second"},{"team_id":"85000000-0000-0000-0000-000000000003","award_name":"Third"}]');
reset role;
select pg_temp.capture_export_state();
set local role authenticated;
do $$ declare payload jsonb; begin
  payload:=public.get_event_export('awards'); perform pg_temp.assert_export_shape(payload,'awards',9);
  if jsonb_array_length(payload->'rows') is distinct from 3 or payload->'rows'->0->>0 is distinct from '1'
    or payload->'rows'->0->>1 is distinct from 'First' or payload->'rows'->0->>2 is distinct from 'Export team 2'
    or payload->'rows'->0->>3 is distinct from '2' or payload->'rows'->0->>4 is distinct from '1'
    or payload->'rows'->0->>5 is distinct from '4' or payload->'rows'->0->>6 is distinct from '1'
    or payload->'headers'->>8 is distinct from '빙고 가산점' or payload->'rows'->0->>8 is distinct from '1' then
    raise exception 'published awards export incorrect'; end if;
  perform set_config('request.jwt.claim.sub','84000000-0000-0000-0000-000000000003',true);
  begin perform public.get_event_export('awards'); raise exception 'participant exported private admin CSV'; exception when insufficient_privilege then null; end;
end; $$;
reset role;
select pg_temp.assert_export_state(1,1);
do $$ begin
  if not exists(select 1 from private.operator_access_logs where operation='export' and resource='get_event_export'
    and actor_login='export-2@example.test' and cardinality(subject_ids)=20
    and '86000000-0000-0000-0000-000000000003'::uuid=any(subject_ids))
    or exists(select 1 from private.operator_access_logs where operation='export' and actor_login='export-3@example.test') then
    raise exception 'export subjects missing or denied participant recorded as exporter';
  end if;
end; $$;
select '1..1' as tap;
select 'ok 1 - six scalar CSV projections, historical bingo ranks, separate GSA identity, aggregate-only vote privacy, state guards and read-only exports' as tap;
rollback;

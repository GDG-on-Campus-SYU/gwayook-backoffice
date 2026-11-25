begin;
insert into auth.users(id,email) select ('74000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  'gemini-'||i||'@example.test' from generate_series(1,7) i;
insert into public.teams(id,name) select ('75000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  'Gemini team '||i from generate_series(1,3) i;
insert into public.members(id,name,email,auth_user_id,role,team_id)
select ('76000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,'Gemini member '||i,'gemini-'||i||'@example.test',
  ('74000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  case when i=1 then 'owner' when i in (2,3) then 'staff' else 'participant' end,
  case when i>=4 then ('75000000-0000-0000-0000-'||lpad(least(i-3,3)::text,12,'0'))::uuid end
from generate_series(1,7) i;
insert into private.participant_operations(member_id,attendance_status,checked_in_at)
select id,'present',now() from public.members where email in ('gemini-4@example.test','gemini-5@example.test','gemini-6@example.test','gemini-7@example.test');
update public.event_settings set vote_closes_at=clock_timestamp()+interval '1 hour' where id;

\ir fixtures/consented-members.sql
select pg_temp.consent_fixture_members('{"team":false,"presentation":false,"bingo":false}');

set local role authenticated;
do $$
declare
  a constant uuid := '75000000-0000-0000-0000-000000000001';
  b constant uuid := '75000000-0000-0000-0000-000000000002';
  c constant uuid := '75000000-0000-0000-0000-000000000003';
  owner_auth constant text := '74000000-0000-0000-0000-000000000001';
  denied_auth text;
  invalid_note text;
  settings jsonb;
  details jsonb;
begin
  if has_table_privilege('authenticated','private.team_bonus','select,insert,update,delete')
    or has_table_privilege('anon','private.team_bonus','select,insert,update,delete')
    or has_table_privilege('service_role','private.team_bonus','select,insert,update,delete')
    or has_function_privilege('authenticated','private.main_score_tally()','execute')
    or has_function_privilege('anon','public.get_gemini_bonuses()','execute')
    or has_function_privilege('service_role','public.set_gemini_bonus(uuid,boolean,text)','execute') then
    raise exception 'bonus table, evidence or internal tally exposed';
  end if;
  perform set_config('request.jwt.claim.sub',owner_auth,true);
  settings:=public.get_gemini_bonuses();
  if settings->>'locked' is distinct from 'false' or exists(select 1 from jsonb_array_elements(settings->'teams') t where t->>'approved' is distinct from 'false') then
    raise exception 'bonus default is not unapproved/unlocked';
  end if;
  perform public.set_vote_delegate('76000000-0000-0000-0000-000000000002');
  foreach denied_auth in array array['','74000000-0000-0000-0000-000000000002',
    '74000000-0000-0000-0000-000000000003','74000000-0000-0000-0000-000000000004'] loop
    perform set_config('request.jwt.claim.sub',denied_auth,true);
    begin perform public.get_gemini_bonuses(); raise exception 'nonowner accessed owner bonus configuration';
    exception when insufficient_privilege then null; end;
    begin perform public.set_gemini_bonus(b,true,'Unauthorized evidence'); raise exception 'nonowner changed bonus';
    exception when insufficient_privilege then null; end;
  end loop;
  perform set_config('request.jwt.claim.sub',owner_auth,true);
  foreach invalid_note in array array[null::text,'   ',E'\n\t',repeat('x',501)] loop
    begin perform public.set_gemini_bonus(b,true,invalid_note); raise exception 'invalid evidence accepted';
    exception when invalid_parameter_value then null; end;
  end loop;
  begin perform public.set_gemini_bonus(null,true,'Evidence'); raise exception 'missing team accepted';
  exception when invalid_parameter_value then null; end;
  begin perform public.set_gemini_bonus(b,null,'Evidence'); raise exception 'missing decision accepted';
  exception when invalid_parameter_value then null; end;
  perform public.set_gemini_bonus(c,true,'Prototype checked');
  perform public.set_gemini_bonus(c,true,'Prototype checked');
  -- Inspect persisted audit state as the fixture owner; clients use logged RPCs.
  reset role;
  if (select count(*) from public.audit_logs where action='gemini_bonus_changed') is distinct from 1 then
    raise exception 'identical approval did not remain idempotent';
  end if;
  set local role authenticated;
  perform public.set_gemini_bonus(c,false,null);
  perform public.schedule_vote(clock_timestamp()+interval '10 minutes',array[a,b,c]);
  perform public.set_gemini_bonus(c,true,'Scheduled visual checked');
  perform public.cancel_vote_schedule();
  perform public.set_gemini_bonus(c,false,null);
  perform public.manage_vote('open',array[a,b,c]);
  perform public.set_gemini_bonus(b,true,'Gemini application prototype checked');
  perform set_config('request.jwt.claim.sub','74000000-0000-0000-0000-000000000004',true);
  perform public.cast_vote(b);
  perform set_config('request.jwt.claim.sub','74000000-0000-0000-0000-000000000005',true);
  perform public.cast_vote(a);
  perform set_config('request.jwt.claim.sub','74000000-0000-0000-0000-000000000006',true);
  perform public.cast_vote(a);
  if public.get_vote_details()->'results' is distinct from '[]'::jsonb then raise exception 'preclose participant tally exposed'; end if;
  perform set_config('request.jwt.claim.sub',owner_auth,true);
  perform public.manage_vote('close');
end;
$$;
reset role;
create temp table gemini_preserved as select
  (select jsonb_agg(to_jsonb(v) order by member_id) from private.votes v) as ballots,
  (select jsonb_agg(to_jsonb(e) order by member_id) from private.vote_eligibility e) as electorate,
  (select jsonb_agg(to_jsonb(m) order by id) from public.members m) as members,
  (select jsonb_agg(to_jsonb(t) order by id) from public.teams t) as teams,
  (select jsonb_build_object('submission_deadline',submission_deadline,'vote_closes_at',vote_closes_at) from public.event_settings where id) as deadlines,
  (select to_jsonb(g) from private.bingo_game g where id) as bingo;

set local role authenticated;
do $$
declare
  a constant uuid := '75000000-0000-0000-0000-000000000001';
  b constant uuid := '75000000-0000-0000-0000-000000000002';
  c constant uuid := '75000000-0000-0000-0000-000000000003';
  details jsonb;
  team_result jsonb;
  round_id uuid;
begin
  perform set_config('request.jwt.claim.sub','74000000-0000-0000-0000-000000000001',true);
  details:=public.get_vote_details();
  select value into team_result from jsonb_array_elements(details->'results') where value->>'team_id'=b::text;
  if team_result->>'vote_count' is distinct from '1' or team_result->>'gemini_bonus' is distinct from '1' or team_result->>'total_score' is distinct from '2'
    or team_result->>'raw_rank' is distinct from '1' or team_result->>'tied_count' is distinct from '2'
    or details->'runoff_groups'->0->>'main_score' is distinct from '2' or details->'runoff_groups'->0->>'vote_count' is not null then
    raise exception 'raw ballots and mixed-raw score tie incorrect: %',details;
  end if;
  perform public.set_gemini_bonus(b,false,'Approval corrected');
  select value into team_result from jsonb_array_elements(public.get_vote_details()->'results') where value->>'team_id'=b::text;
  if team_result->>'total_score' is distinct from '1' or team_result->>'raw_rank' is distinct from '2' then raise exception 'closed correction did not restore raw ranking'; end if;
  perform public.set_gemini_bonus(b,true,'Gemini application prototype checked');
  perform public.set_gemini_bonus(a,true,'Gemini visual checked');
  select value into team_result from jsonb_array_elements(public.get_vote_details()->'results') where value->>'team_id'=a::text;
  if team_result->>'total_score' is distinct from '3' or team_result->>'tied_count' is distinct from '1' then raise exception 'bonus failed to separate previously tied teams'; end if;
  perform public.set_gemini_bonus(a,false,null);
  begin perform public.manage_runoff('start',array[a,c],clock_timestamp()+interval '5 minutes'); raise exception 'different total scores entered runoff';
  exception when invalid_parameter_value then null; end;
  perform set_config('request.jwt.claim.sub','74000000-0000-0000-0000-000000000002',true);
  perform public.manage_runoff('start',array[a,b],clock_timestamp()+interval '5 minutes');
  details:=public.get_vote_details();
  round_id:=(details->'runoff'->>'id')::uuid;
  if details->'runoff'->>'main_score' is distinct from '2' or details->'runoff'->>'main_vote_count' is not null then
    raise exception 'mixed raw count was fabricated or score missing';
  end if;
  perform set_config('request.jwt.claim.sub','74000000-0000-0000-0000-000000000001',true);
  if public.get_gemini_bonuses()->>'locked' is distinct from 'true' then raise exception 'first runoff did not lock bonuses'; end if;
  begin perform public.set_gemini_bonus(c,true,'Late score change'); raise exception 'bonus changed after first runoff';
  exception when invalid_parameter_value then null; end;
  perform set_config('request.jwt.claim.sub','74000000-0000-0000-0000-000000000006',true);
  details:=public.get_vote_details();
  if details->'results' is distinct from '[]'::jsonb or details->'runoff'->>'main_score' is not null
    or public.get_vote_overview()->'runoff'->>'main_score' is not null then raise exception 'unpublished score leaked'; end if;
  perform public.cast_runoff_vote(round_id,b);
  perform set_config('request.jwt.claim.sub','74000000-0000-0000-0000-000000000007',true);
  perform public.cast_runoff_vote(round_id,b);
  perform set_config('request.jwt.claim.sub','74000000-0000-0000-0000-000000000002',true);
  perform public.manage_runoff('close',null,null,round_id);
  details:=public.get_vote_details();
  if details->'results'->0->>'team_id' is distinct from b::text or details->'results'->0->>'vote_count' is distinct from '1'
    or details->'results'->0->>'total_score' is distinct from '2' or details->'results'->0->>'runoff_vote_count' is distinct from '2' then
    raise exception 'score tie runoff did not integrate without changing raw votes';
  end if;
  begin perform public.manage_vote('publish',null,jsonb_build_array(jsonb_build_object('team_id',a,'award_name','Wrong first')));
    raise exception 'raw higher team bypassed total-score runoff outcome'; exception when invalid_parameter_value then null; end;
  perform public.manage_vote('publish',null,jsonb_build_array(jsonb_build_object('team_id',b,'award_name','First'),
    jsonb_build_object('team_id',a,'award_name','Second'),jsonb_build_object('team_id',c,'award_name','Third')));
  perform set_config('request.jwt.claim.sub','74000000-0000-0000-0000-000000000006',true);
  details:=public.get_vote_details();
  if details->>'status' is distinct from 'published' or details->'results'->0->>'final_rank' is distinct from '1'
    or details->'results'->0->>'gemini_bonus' is distinct from '1' or details->'runoff_history'->0->>'main_score' is distinct from '2'
    or details::text like '%prototype checked%' then raise exception 'public score result missing or private evidence leaked'; end if;
end;
$$;
reset role;
do $$
declare original gemini_preserved;
begin
  select * into strict original from gemini_preserved;
  if original.ballots is distinct from (select jsonb_agg(to_jsonb(v) order by member_id) from private.votes v)
    or original.electorate is distinct from (select jsonb_agg(to_jsonb(e) order by member_id) from private.vote_eligibility e)
    or original.members is distinct from (select jsonb_agg(to_jsonb(m) order by id) from public.members m)
    or original.teams is distinct from (select jsonb_agg(to_jsonb(t) order by id) from public.teams t)
    or original.deadlines is distinct from (select jsonb_build_object('submission_deadline',submission_deadline,'vote_closes_at',vote_closes_at) from public.event_settings where id)
    or original.bingo is distinct from (select to_jsonb(g) from private.bingo_game g where id) then
    raise exception 'bonus or runoff altered protected source data';
  end if;
  if (select count(*) from private.team_bonus where team_id='75000000-0000-0000-0000-000000000002') is distinct from 1
    or exists(select 1 from public.audit_logs where action='gemini_bonus_changed' and (not(details ? 'before') or not(details ? 'after')))
    or not (select relrowsecurity from pg_class where oid='private.team_bonus'::regclass) then
    raise exception 'bonus uniqueness, audit transition or RLS missing';
  end if;
end;
$$;
rollback;

-- Publishing without a runoff also freezes the scoring rule.
begin;
insert into auth.users(id,email) values('77000000-0000-0000-0000-000000000001','gemini-publish@example.test');
insert into public.members(name,email,role,auth_user_id) values('Publish owner','gemini-publish@example.test','owner','77000000-0000-0000-0000-000000000001');
insert into public.teams(id,name) values('78000000-0000-0000-0000-000000000001','Publish A'),('78000000-0000-0000-0000-000000000002','Publish B');
insert into public.members(name,email,role,team_id) values('Voter','gemini-publish-voter@example.test','participant','78000000-0000-0000-0000-000000000001');
insert into private.participant_operations(member_id,attendance_status,checked_in_at)
select id,'present',now() from public.members where email='gemini-publish-voter@example.test';
update public.event_settings set vote_closes_at=clock_timestamp()+interval '1 hour' where id;
\ir fixtures/consented-members.sql
select pg_temp.consent_fixture_members('{"team":false,"presentation":false,"bingo":false}');

set local role authenticated;
select set_config('request.jwt.claim.sub','77000000-0000-0000-0000-000000000001',true);
do $$
declare a constant uuid:='78000000-0000-0000-0000-000000000001'; b constant uuid:='78000000-0000-0000-0000-000000000002';
begin
  perform public.set_gemini_bonus(b,true,'Gemini visual checked');
  perform public.manage_vote('open',array[a,b]);
  perform public.manage_vote('close');
  perform public.manage_vote('publish',null,jsonb_build_array(jsonb_build_object('team_id',b,'award_name','First'),jsonb_build_object('team_id',a,'award_name','Second')));
  if public.get_gemini_bonuses()->>'locked' is distinct from 'true' then raise exception 'publication did not lock bonuses'; end if;
  begin perform public.set_gemini_bonus(b,false,null); raise exception 'published bonus removed'; exception when invalid_parameter_value then null; end;
end;
$$;
select '1..1' as tap;
select 'ok 1 - owner-only Gemini evidence, one point, raw-ballot preservation, score ties/runoffs, privacy and score freeze' as tap;
rollback;

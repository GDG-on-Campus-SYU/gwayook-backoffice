begin;
insert into public.teams(id,name) values
  ('b1000000-0000-0000-0000-000000000001','Bingo A'),
  ('b1000000-0000-0000-0000-000000000002','Bingo B');
insert into auth.users(id,email) select ('b2000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  'bingo-bonus-'||i||'@example.test' from generate_series(1,4) i;
insert into public.members(name,email,auth_user_id,role,active,team_id)
select 'Bonus member '||i,'bingo-bonus-'||i||'@example.test',('b2000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  case when i=1 then 'owner' when i in (2,4) then 'staff' else 'participant' end,i<>4,
  case when i=3 then 'b1000000-0000-0000-0000-000000000001'::uuid end from generate_series(1,4) i;
update public.event_settings set vote_closes_at=clock_timestamp()+interval '1 hour' where id;
insert into private.participant_operations(member_id,attendance_status,checked_in_at)
select id,'present',now() from public.members where email='bingo-bonus-3@example.test';
\ir fixtures/consented-members.sql
select pg_temp.consent_fixture_members('{"team":false,"presentation":false,"bingo":false}');

set local role authenticated;
do $$
declare
  a constant uuid := 'b1000000-0000-0000-0000-000000000001';
  b constant uuid := 'b1000000-0000-0000-0000-000000000002';
  owner_auth constant text := 'b2000000-0000-0000-0000-000000000001';
  staff_auth constant text := 'b2000000-0000-0000-0000-000000000002';
  participant_auth constant text := 'b2000000-0000-0000-0000-000000000003';
  denied_auth text;
  invalid_points integer;
  settings jsonb;
  winner jsonb;
begin
  if has_function_privilege('anon','public.set_bingo_bonus(uuid,integer,integer)','execute')
    or has_function_privilege('anon','public.get_bingo_bonuses()','execute')
    or has_table_privilege('authenticated','private.bingo_team_bonus','select,insert,update,delete') then
    raise exception 'bingo score permissions allow direct access';
  end if;
  foreach denied_auth in array array['',participant_auth,'b2000000-0000-0000-0000-000000000004'] loop
    perform set_config('request.jwt.claim.sub',denied_auth,true);
    begin perform public.get_bingo_bonuses(); raise exception 'nonstaff read bonus configuration';
    exception when insufficient_privilege then null; end;
    begin perform public.set_bingo_bonus(a,1,0); raise exception 'nonstaff changed bonus';
    exception when insufficient_privilege then null; end;
  end loop;

  perform set_config('request.jwt.claim.sub',staff_auth,true);
  settings := public.get_bingo_bonuses();
  if settings->>'locked' is distinct from 'false' or jsonb_array_length(settings->'teams') is distinct from 2
    or exists(select 1 from jsonb_array_elements(settings->'teams') t where t->>'bingo_bonus' is distinct from '0') then
    raise exception 'existing teams did not default to zero';
  end if;
  foreach invalid_points in array array[-1,32768,null::integer] loop
    begin perform public.set_bingo_bonus(a,invalid_points,0); raise exception 'out-of-range points accepted';
    exception when invalid_parameter_value then null; end;
  end loop;
  begin perform public.set_bingo_bonus(a,1,null); raise exception 'missing previous score accepted';
  exception when invalid_parameter_value then null; end;
  begin perform public.set_bingo_bonus('b1000000-0000-0000-0000-000000000099',1,0); raise exception 'unknown team scored';
  exception when invalid_parameter_value then null; end;
  perform public.set_bingo_bonus(a,32767,0);
  perform public.set_bingo_bonus(a,32767,0);
  perform set_config('request.jwt.claim.sub',owner_auth,true);
  begin perform public.set_bingo_bonus(a,3,0); raise exception 'stale correction overwrote another operator';
  exception when serialization_failure then null; end;
  perform public.set_bingo_bonus(a,0,32767);
  perform public.set_gemini_bonus(b,true,'Demo checked');
  perform public.manage_vote('open',array[a,b]);
  perform set_config('request.jwt.claim.sub',participant_auth,true);
  perform public.cast_vote(b);
  perform set_config('request.jwt.claim.sub',owner_auth,true);
  perform public.manage_vote('close');
  perform set_config('request.jwt.claim.sub',staff_auth,true);
  perform public.set_bingo_bonus(a,3,0);
  select value into strict winner from jsonb_array_elements(public.get_vote_details()->'results') where value->>'raw_rank'='1';
  if winner->>'team_id' is distinct from a::text or winner->>'bingo_bonus' is distinct from '3'
    or winner->>'vote_count' is distinct from '0' or winner->>'gemini_bonus' is distinct from '0'
    or winner->>'total_score' is distinct from '3' then raise exception 'manually entered bonus did not determine rank'; end if;
  perform set_config('request.jwt.claim.sub',participant_auth,true);
  if public.get_vote_details()->'results' is distinct from '[]'::jsonb then raise exception 'unpublished scores leaked'; end if;
  perform set_config('request.jwt.claim.sub',owner_auth,true);
  begin perform public.manage_vote('publish',null,jsonb_build_array(jsonb_build_object('team_id',b,'award_name','First')));
    raise exception 'awards ignored bingo score';
  exception when invalid_parameter_value then null; end;
  perform public.manage_vote('publish',null,jsonb_build_array(jsonb_build_object('team_id',a,'award_name','First')));
  if public.get_bingo_bonuses()->>'locked' is distinct from 'true' then raise exception 'publication did not lock scores'; end if;
  begin perform public.set_bingo_bonus(a,0,3); raise exception 'published score changed';
  exception when invalid_parameter_value then null; end;
  perform set_config('request.jwt.claim.sub',participant_auth,true);
  winner := public.get_vote_details()->'results'->0;
  if winner->>'team_id' is distinct from a::text or winner->>'bingo_bonus' is distinct from '3'
    or winner->>'final_rank' is distinct from '1' or winner->>'total_score' is distinct from '3' then
    raise exception 'public result lost its bingo score';
  end if;
end;
$$;
reset role;
do $$ begin
  if (select count(*) from public.audit_logs where action='bingo_bonus_changed') <> 3
    or not exists(select 1 from public.audit_logs l join public.members m on m.id=l.actor_id
      where l.action='bingo_bonus_changed' and l.target_id='b1000000-0000-0000-0000-000000000001'
        and m.role='staff' and l.details @> '{"before":0,"after":3}'::jsonb)
    or not exists(select 1 from public.audit_logs where action='bingo_bonus_changed'
      and details @> '{"before":32767,"after":0}'::jsonb) then raise exception 'bingo score audit incorrect'; end if;
end; $$;
select '1..1' as tap;
select 'ok 1 - staff scoring, idempotency, stale corrections, bonus-adjusted awards and publication lock' as tap;
rollback;

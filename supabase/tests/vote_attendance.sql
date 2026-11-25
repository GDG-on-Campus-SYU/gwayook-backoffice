begin;
insert into public.teams(id,name)
select ('a4000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,'Attendance team '||i from generate_series(1,3) i;
insert into auth.users(id,email)
select ('a5000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,'vote-attendance-'||i||'@example.test' from generate_series(1,9) i;
insert into public.members(id,name,email,auth_user_id,role,active,team_id)
select u.id,'Attendance member '||i,u.email,u.id,case i when 1 then 'owner' when 2 then 'staff' else 'participant' end,i<>8,
  case when i between 3 and 8 then ('a4000000-0000-0000-0000-'||lpad((case when i in (3,8) then 1 when i=4 then 3 else 2 end)::text,12,'0'))::uuid end
from generate_series(1,9) i join auth.users u on u.email='vote-attendance-'||i||'@example.test';
update public.event_settings set vote_closes_at=clock_timestamp()+interval '2 hours' where id;
\ir fixtures/consented-members.sql
select pg_temp.consent_fixture_members('{"team":false,"presentation":false,"bingo":false}');

set local role authenticated;
select set_config('request.jwt.claim.sub','a5000000-0000-0000-0000-000000000001',true);
do $$
declare
  candidates uuid[] := array['a4000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000002']::uuid[];
  starts timestamptz;
begin
  if has_function_privilege('anon','public.confirm_vote_start(uuid[],integer,timestamptz)','execute') then
    raise exception 'anonymous caller may confirm a vote'; end if;
  if public.get_vote_details()->>'eligible_count' is distinct from '0' then raise exception 'missing check-ins counted'; end if;
  foreach starts in array array[null::timestamptz,now()+interval '1 hour'] loop
    begin perform public.confirm_vote_start(candidates,0,starts); raise exception 'empty electorate accepted';
    exception when invalid_parameter_value then null; end;
    begin perform public.confirm_vote_start(candidates,1,starts); raise exception 'stale count accepted after drop to zero';
    exception when serialization_failure then null; end;
  end loop;
  begin perform public.schedule_vote(now()+interval '1 hour',candidates); raise exception 'legacy schedule ignored check-in';
  exception when invalid_parameter_value then null; end;
  begin perform public.manage_vote('open',candidates); raise exception 'legacy open ignored check-in';
  exception when invalid_parameter_value then null; end;
end; $$;
reset role;
do $$ begin
  if (select vote_status from public.event_settings where id) is distinct from 'draft'
    or exists(select 1 from private.vote_candidates) or exists(select 1 from private.vote_eligibility)
    or exists(select 1 from public.audit_logs where action in ('vote_open','vote_schedule')) then
    raise exception 'rejected empty confirmations left partial state'; end if;
end; $$;

-- 3 is present, 4 is late (on a noncandidate team). 7 has no operations record.
insert into private.participant_operations(member_id,attendance_status,checked_in_at)
select ('a5000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,status,
  case when status in ('present','late') then now() end
from (values (2,'present'),(3,'present'),(4,'late'),(5,'absent'),(6,'pending'),(8,'present'),(9,'present')) as attendance(i,status);
set local role authenticated;
do $$
declare
  candidates uuid[] := array['a4000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000002']::uuid[];
  starts timestamptz;
begin
  if public.get_vote_overview()->>'eligible_count' is distinct from '2' or public.get_vote_details()->>'eligible_count' is distinct from '2' then
    raise exception 'draft did not count only assigned, active, present/late participants'; end if;
  foreach starts in array array[null::timestamptz,now()+interval '1 hour'] loop
    begin perform public.confirm_vote_start(candidates,1,starts); raise exception 'confirmation ignored changed attendance';
    exception when serialization_failure then null; end;
  end loop;
  perform set_config('request.jwt.claim.sub','a5000000-0000-0000-0000-000000000002',true);
  begin perform public.confirm_vote_start(candidates,2); raise exception 'regular staff confirmed a vote';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub','a5000000-0000-0000-0000-000000000001',true);
  perform public.set_vote_delegate('a5000000-0000-0000-0000-000000000002');
  perform set_config('request.jwt.claim.sub','a5000000-0000-0000-0000-000000000002',true);
  perform public.confirm_vote_start(candidates,2,now()+interval '1 hour');
end; $$;
reset role;
do $$ begin
  if (select array_agg(m.email order by m.email) from private.vote_eligibility e join public.members m on m.id=e.member_id)
    is distinct from array['vote-attendance-3@example.test','vote-attendance-4@example.test']
    or (select count(*) from private.vote_candidates)<>2 then raise exception 'reservation snapshot wrong'; end if;
end; $$;

set local role authenticated;
-- Correct one check-in and two arrivals while scheduled. The new count applies only after cancel.
select public.set_participant_attendance('a5000000-0000-0000-0000-000000000003','absent',null,null);
select public.set_participant_attendance('a5000000-0000-0000-0000-000000000005','late',null,null);
select public.set_participant_attendance('a5000000-0000-0000-0000-000000000007','present',null,null);
do $$ begin
  if public.get_vote_details()->>'eligible_count' is distinct from '2' then raise exception 'reservation changed with attendance'; end if;
  perform public.cancel_vote_schedule();
  if public.get_vote_overview()->>'eligible_count' is distinct from '3' then raise exception 'cancellation failed to refresh attendance'; end if;
  perform public.confirm_vote_start(array['a4000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000002']::uuid[],3);
end; $$;
select public.set_participant_attendance('a5000000-0000-0000-0000-000000000006','present',null,null);
do $$
declare
  voter integer;
  denied integer;
  team_a uuid := 'a4000000-0000-0000-0000-000000000001';
begin
  if public.get_vote_details()->>'eligible_count' is distinct from '3' then raise exception 'open vote changed with later check-in'; end if;
  foreach voter in array array[4,5,7] loop
    perform set_config('request.jwt.claim.sub','a5000000-0000-0000-0000-'||lpad(voter::text,12,'0'),true);
    perform public.cast_vote(team_a);
  end loop;
  foreach denied in array array[2,3,6,8,9] loop
    perform set_config('request.jwt.claim.sub','a5000000-0000-0000-0000-'||lpad(denied::text,12,'0'),true);
    begin perform public.cast_vote(team_a); raise exception 'noneligible member % voted',denied;
    exception when insufficient_privilege then null; end;
  end loop;
end; $$;
select '1..1';
select 'ok 1 - confirmed attendees only, stable snapshots, stale and empty confirmation, cancel and refresh';
rollback;

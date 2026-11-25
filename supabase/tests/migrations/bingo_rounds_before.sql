-- Run only on a disposable database after the original QR bingo migration.
create schema migration_verification;
create table migration_verification.bingo_before(data jsonb not null);
insert into auth.users(id,email)
select ('b3000000-0000-0000-0000-' || lpad(n::text,12,'0'))::uuid, 'migration' || n || '@example.test' from generate_series(1,20) n;
insert into public.members(id,name,email,auth_user_id,role)
select id,'Migration person ' || row_number() over(order by email),email,id,
  case when email='migration1@example.test' then 'owner' else 'participant' end
from auth.users where email like 'migration%@example.test';
do $$
declare
  owner_id uuid := 'b3000000-0000-0000-0000-000000000001';
  person_id uuid := 'b3000000-0000-0000-0000-000000000003';
begin
  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  perform public.save_bingo_config(array(select 'Preserved question ' || n from generate_series(1,25) n),'Preserved prize');
  perform public.manage_bingo('open');
  perform set_config('request.jwt.claim.sub',person_id::text,true);
  perform public.get_bingo();
  insert into private.bingo_marks(member_id,cell,confirmed_by,confirmed_at,suspicious)
    select person_id,n,('b3000000-0000-0000-0000-' || lpad((n+4)::text,12,'0'))::uuid,clock_timestamp(),n>=2 from generate_series(0,14) n;
  update private.bingo_boards set completed_at=clock_timestamp() where member_id=person_id;
  perform public.request_bingo_confirmation(15);
  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  perform public.manage_bingo('close');
end;
$$;
insert into migration_verification.bingo_before(data)
select jsonb_build_object(
  'game',(select to_jsonb(g) from private.bingo_game g where id),
  'boards',(select jsonb_agg(to_jsonb(b) order by member_id) from private.bingo_boards b),
  'marks',(select jsonb_agg(to_jsonb(m) order by member_id,cell) from private.bingo_marks m),
  'requests',(select jsonb_agg(to_jsonb(q) order by token) from private.bingo_requests q),
  'event',(select to_jsonb(e) from public.event_settings e where id),
  'representatives',(select coalesce(jsonb_agg(jsonb_build_array(id,representative_id) order by id),'[]'::jsonb) from public.teams),
  'audit',(select jsonb_agg(to_jsonb(a) order by id) from public.audit_logs a)
);

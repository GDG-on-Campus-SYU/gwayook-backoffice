-- Disposable upgrade fixture: run after the last pre-duration migration and before
-- 20261115105127_bingo_twenty_five_minutes.sql. Never run against production.
create schema if not exists migration_verification;
create table migration_verification.bingo_duration_before(name text primary key, data jsonb);
create table migration_verification.bingo_duration_functions_before(data jsonb not null);
insert into auth.users(id, email)
select ('b5000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid,
  'duration-upgrade' || n || '@example.test' from generate_series(1, 20) n;
insert into public.teams(id, name) values ('b5100000-0000-0000-0000-000000000001', 'Preserved duration team');
insert into public.members(id, name, email, auth_user_id, role, team_id)
select id, 'Duration upgrade ' || split_part(email, '@', 1), email, id,
  case when email = 'duration-upgrade1@example.test' then 'owner' else 'participant' end,
  case when email = 'duration-upgrade3@example.test' then 'b5100000-0000-0000-0000-000000000001'::uuid end
from auth.users where email like 'duration-upgrade%@example.test';
update public.teams set representative_id = 'b5000000-0000-0000-0000-000000000003' where id = 'b5100000-0000-0000-0000-000000000001';

do $$
declare
  owner_id uuid := 'b5000000-0000-0000-0000-000000000001';
  person_id uuid := 'b5000000-0000-0000-0000-000000000003';
  request jsonb;
begin
  perform set_config('request.jwt.claim.sub', owner_id::text, true);
  perform public.save_bingo_config(array(select 'Preserved duration question ' || n from generate_series(1, 25) n), 'Preserved duration prize');
  perform public.manage_bingo_round('open', 1);
  if not exists(select 1 from private.bingo_game where closes_at = opens_at + interval '30 minutes') then
    raise exception 'upgrade fixture must run before the 25-minute migration';
  end if;
  perform set_config('request.jwt.claim.sub', person_id::text, true);
  perform public.get_bingo();
  insert into private.bingo_marks(round_no, member_id, cell, confirmed_by, confirmed_at, suspicious)
    select 1, person_id, n, ('b5000000-0000-0000-0000-' || lpad((n + 4)::text, 12, '0'))::uuid,
      clock_timestamp() - interval '20 seconds', n >= 2 from generate_series(0, 13) n;
  request := public.request_bingo_confirmation_round(1, 14);
  perform set_config('request.jwt.claim.sub', 'b5000000-0000-0000-0000-000000000018', true);
  if public.confirm_bingo(request->>'token')->>'confirmed' is distinct from 'true' then raise exception 'upgrade completion fixture failed'; end if;
  perform set_config('request.jwt.claim.sub', person_id::text, true);
  update private.bingo_requests set created_at = created_at - interval '3 seconds' where round_no = 1 and member_id = person_id;
  perform public.request_bingo_confirmation_round(1, 15);
  perform set_config('request.jwt.claim.sub', owner_id::text, true);
  perform public.manage_bingo_round('close', 1);
  perform public.manage_bingo_round('restart', 1);
  perform set_config('request.jwt.claim.sub', person_id::text, true);
  perform public.get_bingo();
  perform public.request_bingo_confirmation_round(2, 0);
end;
$$;

do $$ declare relation record; begin
  for relation in select schemaname, tablename from pg_tables where schemaname in ('public', 'private', 'auth', 'storage') loop
    execute format('insert into migration_verification.bingo_duration_before select %L, jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text) from %I.%I t',
      relation.schemaname || '.' || relation.tablename, relation.schemaname, relation.tablename);
  end loop;
end; $$;
insert into migration_verification.bingo_duration_functions_before(data)
select jsonb_object_agg(p.oid::text, jsonb_build_object(
  'definition', case when n.nspname = 'private' and p.proname = 'manage_bingo_round' then null else pg_get_functiondef(p.oid) end,
  'acl', p.proacl, 'security_definer', p.prosecdef, 'config', p.proconfig))
from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname in ('private', 'public') and p.prokind = 'f';

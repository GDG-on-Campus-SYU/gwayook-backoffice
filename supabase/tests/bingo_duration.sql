begin;

insert into auth.users(id, email)
select ('b4000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid,
  'duration' || n || '@example.test' from generate_series(1, 6) n;
insert into public.teams(id, name) values ('b4100000-0000-0000-0000-000000000001', 'Duration team');
insert into public.members(id, name, email, auth_user_id, role, team_id)
select id, 'Duration ' || split_part(email, '@', 1), email, id,
  case when email = 'duration1@example.test' then 'owner' when email = 'duration2@example.test' then 'staff' else 'participant' end,
  case when email = 'duration3@example.test' then 'b4100000-0000-0000-0000-000000000001'::uuid end
from auth.users where email like 'duration%@example.test';
update public.teams set representative_id = 'b4000000-0000-0000-0000-000000000003' where id = 'b4100000-0000-0000-0000-000000000001';

\ir fixtures/consented-members.sql
select pg_temp.consent_fixture_members('{"team":false,"presentation":false,"bingo":true}');

create temp table duration_preserved(name text primary key, data jsonb);
do $$ declare relation record; begin
  for relation in select schemaname, tablename from pg_tables where schemaname in ('public', 'private', 'auth', 'storage')
    and tablename not like 'bingo_%' and tablename <> 'audit_logs' and not (schemaname='private' and tablename='operator_access_logs') loop
    execute format('insert into duration_preserved select %L, jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text) from %I.%I t',
      relation.schemaname || '.' || relation.tablename, relation.schemaname, relation.tablename);
  end loop;
end; $$;

do $$
declare
  owner_id uuid := 'b4000000-0000-0000-0000-000000000001';
  staff_id uuid := 'b4000000-0000-0000-0000-000000000002';
  person_id uuid := 'b4000000-0000-0000-0000-000000000003';
  confirmer_id uuid := 'b4000000-0000-0000-0000-000000000004';
  denied_id uuid;
  operation text;
  request jsonb;
  legacy_round jsonb;
  legacy_records jsonb;
  stamp timestamptz;
begin
  if has_function_privilege('anon', 'public.manage_bingo_round(text,integer)', 'execute')
    or has_function_privilege('service_role', 'public.manage_bingo_round(text,integer)', 'execute')
    or has_function_privilege('anon', 'private.manage_bingo_round(text,integer)', 'execute')
    or has_function_privilege('service_role', 'private.manage_bingo_round(text,integer)', 'execute')
    or not has_function_privilege('authenticated', 'public.manage_bingo_round(text,integer)', 'execute')
    or has_table_privilege('authenticated', 'private.bingo_game', 'insert,update,delete')
    or has_table_privilege('authenticated', 'private.bingo_rounds', 'insert,update,delete') then
    raise exception 'bingo duration migration changed permission boundaries';
  end if;
  foreach denied_id in array array[staff_id, person_id] loop
    perform set_config('request.jwt.claim.sub', denied_id::text, true);
    foreach operation in array array['open', 'close', 'restart'] loop
      begin
        perform public.manage_bingo_round(operation, 1);
        raise exception 'non-owner performed %', operation;
      exception when insufficient_privilege then null; end;
    end loop;
  end loop;
  perform set_config('request.jwt.claim.sub', person_id::text, true);
  if public.get_bingo_status() is distinct from '{"status":"hidden"}'::jsonb then
    raise exception 'duration migration exposed unopened bingo';
  end if;
  perform set_config('request.jwt.claim.sub', owner_id::text, true);
  perform public.save_bingo_config(array(select 'Duration question ' || n from generate_series(1, 25) n), 'Preserved duration prize');
  perform public.manage_bingo('open');
  if not exists(select 1 from private.bingo_game where opens_at is not null and closes_at = opens_at + interval '25 minutes')
    or not exists(select 1 from private.bingo_rounds where round_no = 1 and closes_at = opens_at + interval '25 minutes') then
    raise exception 'new first round is not exactly 25 minutes';
  end if;
  begin
    update private.bingo_game set closes_at = opens_at + interval '26 minutes' where id;
    raise exception 'invalid current duration accepted';
  exception when check_violation then null; end;
  begin
    update private.bingo_rounds set closes_at = opens_at + interval '26 minutes' where round_no = 1;
    raise exception 'invalid archived duration accepted';
  exception when check_violation then null; end;
  begin
    update private.bingo_game set closes_at = null where id;
    raise exception 'unpaired current timestamp accepted';
  exception when check_violation then null; end;

  -- A 25-minute game caps a late QR at its own deadline, not the old 30-minute limit.
  stamp := clock_timestamp();
  update private.bingo_game set opens_at = stamp - interval '24 minutes', closes_at = stamp + interval '1 minute' where id;
  perform set_config('request.jwt.claim.sub', person_id::text, true);
  perform public.get_bingo();
  request := public.request_bingo_confirmation_round(1, 0);
  if (request->>'expires_at')::timestamptz is distinct from (select closes_at from private.bingo_game where id) then
    raise exception 'QR was not capped at the 25-minute deadline';
  end if;
  perform set_config('request.jwt.claim.sub', confirmer_id::text, true);
  if public.confirm_bingo(request->>'token')->>'confirmed' is distinct from 'true' then raise exception '25-minute round confirmation failed'; end if;
  perform set_config('request.jwt.claim.sub', person_id::text, true);
  update private.bingo_requests set created_at = created_at - interval '3 seconds' where round_no = 1 and member_id = person_id;
  request := public.request_bingo_confirmation_round(1, 1);
  stamp := clock_timestamp();
  update private.bingo_game set opens_at = stamp - interval '25 minutes', closes_at = stamp where id;
  if public.get_bingo_status()->>'status' is distinct from 'closed' then raise exception '25-minute expiry not reflected'; end if;
  begin
    perform public.request_bingo_confirmation_round(1, 2);
    raise exception 'QR issued after 25-minute deadline';
  exception when invalid_parameter_value then null; end;
  perform set_config('request.jwt.claim.sub', 'b4000000-0000-0000-0000-000000000005', true);
  if public.confirm_bingo(request->>'token')->>'error' is null then raise exception 'QR confirmed after 25-minute deadline'; end if;
  perform set_config('request.jwt.claim.sub', owner_id::text, true);
  perform public.manage_bingo_round('restart', 1);
  if not exists(select 1 from private.bingo_game where round_no = 2 and closes_at = opens_at + interval '25 minutes' and closed_at is null) then
    raise exception 'automatic expiry did not allow a fresh 25-minute round';
  end if;

  -- Emulate a round opened before the upgrade. Its full 30 minutes remain valid.
  stamp := clock_timestamp();
  update private.bingo_game set opens_at = stamp - interval '26 minutes', closes_at = stamp + interval '4 minutes' where id;
  update private.bingo_rounds set opens_at = stamp - interval '26 minutes', closes_at = stamp + interval '4 minutes' where round_no = 2;
  perform set_config('request.jwt.claim.sub', person_id::text, true);
  if public.get_bingo_status()->>'status' is distinct from 'open' then raise exception 'existing 30-minute round was shortened'; end if;
  perform public.get_bingo();
  request := public.request_bingo_confirmation_round(2, 0);
  perform set_config('request.jwt.claim.sub', confirmer_id::text, true);
  if public.confirm_bingo(request->>'token')->>'confirmed' is distinct from 'true' then raise exception 'legacy round QR confirmation failed'; end if;
  perform set_config('request.jwt.claim.sub', owner_id::text, true);
  perform public.manage_bingo_round('close', 2);
  select to_jsonb(r) into legacy_round from private.bingo_rounds r where round_no = 2;
  select jsonb_build_object(
    'boards', (select jsonb_agg(to_jsonb(b) order by member_id) from private.bingo_boards b where round_no = 2),
    'marks', (select jsonb_agg(to_jsonb(m) order by member_id, cell) from private.bingo_marks m where round_no = 2),
    'requests', (select jsonb_agg(to_jsonb(r) order by token) from private.bingo_requests r where round_no = 2)
  ) into legacy_records;
  perform public.manage_bingo_round('restart', 2);
  if not exists(select 1 from private.bingo_game where round_no = 3 and closes_at = opens_at + interval '25 minutes'
    and closed_at is null and prize = 'Preserved duration prize') then raise exception 'legacy restart did not use 25 minutes'; end if;
  if (select to_jsonb(r) from private.bingo_rounds r where round_no = 2) is distinct from legacy_round
    or (select jsonb_build_object(
      'boards', (select jsonb_agg(to_jsonb(b) order by member_id) from private.bingo_boards b where round_no = 2),
      'marks', (select jsonb_agg(to_jsonb(m) order by member_id, cell) from private.bingo_marks m where round_no = 2),
      'requests', (select jsonb_agg(to_jsonb(r) order by token) from private.bingo_requests r where round_no = 2)
    )) is distinct from legacy_records then raise exception 'legacy round records were rewritten'; end if;
  perform set_config('request.jwt.claim.sub', person_id::text, true);
  if (public.get_bingo_round(2)->>'closes_at')::timestamptz - (public.get_bingo_round(2)->>'opens_at')::timestamptz
      is distinct from interval '30 minutes'
    or public.get_bingo_round(2)->>'status' is distinct from 'closed' then raise exception 'legacy archive duration not readable'; end if;
end;
$$;

do $$ declare saved record; actual jsonb; begin
  for saved in select * from duration_preserved loop
    execute format('select jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text) from %s t', saved.name) into actual;
    if actual is distinct from saved.data then raise exception 'bingo duration operations mutated %', saved.name; end if;
  end loop;
end; $$;
do $$ begin
  if (select count(*) from private.operator_access_logs where operation like 'write:bingo_%' and resource='audit_logs'
    and actor_login='duration1@example.test' and cardinality(subject_ids)=0) <> 5
    or exists(select 1 from private.operator_access_logs l left join public.members m on m.id=l.actor_id
      where m.id is null or m.role not in('owner','staff') or l.actor_login is distinct from m.email
        or l.retain_until<l.created_at+interval '1 year') then raise exception 'bingo operator mutation audit missing or invalid'; end if;
end; $$;
select '1..1' as tap;
select 'ok 1 - 25-minute opening/restart/deadline, bounded QR, owner-only control, legacy 30-minute preservation and unrelated data unchanged' as tap;
rollback;

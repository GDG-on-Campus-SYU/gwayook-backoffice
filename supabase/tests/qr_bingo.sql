begin;

insert into auth.users(id, email)
select ('b1000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, 'bingo' || n || '@example.test' from generate_series(1,32) n;
insert into public.members(id, name, email, auth_user_id, role)
select id, 'Bingo ' || row_number() over(order by email), email, id,
  case when email = 'bingo1@example.test' then 'owner' when email = 'bingo2@example.test' then 'staff' else 'participant' end
from auth.users where email like 'bingo%@example.test';

\ir fixtures/consented-members.sql
select pg_temp.consent_fixture_members('{"team":false,"presentation":false,"bingo":true}');

set local role authenticated;
do $$
declare
  owner_id uuid := 'b1000000-0000-0000-0000-000000000001';
  staff_id uuid := 'b1000000-0000-0000-0000-000000000002';
  person_id uuid := 'b1000000-0000-0000-0000-000000000003';
  questions text[] := array_fill(''::text, array[25]);
  fn text;
begin
  foreach fn in array array['get_bingo_status()', 'get_bingo()', 'save_bingo_config(text[],text)', 'manage_bingo(text)',
    'request_bingo_confirmation(integer)', 'inspect_bingo_confirmation(text)', 'confirm_bingo(text)'] loop
    if has_function_privilege('anon', 'public.' || fn, 'execute')
      or has_function_privilege('service_role', 'public.' || fn, 'execute') then
      raise exception 'unexpected bingo API grant: %', fn;
    end if;
  end loop;
  if has_table_privilege('authenticated', 'private.bingo_marks', 'insert')
    or has_table_privilege('authenticated', 'private.bingo_requests', 'select')
    or has_function_privilege('authenticated', 'private.bingo_confirmation(text,boolean)', 'execute') then
    raise exception 'unexpected private bingo access';
  end if;
  perform set_config('request.jwt.claim.sub', '', true);
  begin
    perform public.get_bingo();
    raise exception 'unlisted read bingo';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub', person_id::text, true);
  if public.get_bingo() <> '{"status":"hidden"}'::jsonb or public.get_bingo_status() <> '{"status":"hidden"}'::jsonb then
    raise exception 'draft leaked to participant';
  end if;
  begin
    perform public.request_bingo_confirmation(0);
    raise exception 'participant played hidden game';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.save_bingo_config(questions, '');
    raise exception 'participant configured bingo';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub', staff_id::text, true);
  if public.get_bingo()->>'status' <> 'draft' then raise exception 'staff cannot see draft'; end if;
  begin
    perform public.manage_bingo('open');
    raise exception 'staff opened bingo';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub', owner_id::text, true);
  perform public.save_bingo_config(questions, '상품 미정');
  begin
    perform public.manage_bingo('open');
    raise exception 'empty questions allowed';
  exception when invalid_parameter_value then null; end;
  perform public.save_bingo_config(array_fill(E'\t\n'::text, array[25]), '');
  begin
    perform public.manage_bingo('open');
    raise exception 'whitespace-only questions allowed';
  exception when invalid_parameter_value then null; end;
end;
$$;
reset role;

do $$
declare
  owner_id uuid := 'b1000000-0000-0000-0000-000000000001';
  staff_id uuid := 'b1000000-0000-0000-0000-000000000002';
  person_id uuid := 'b1000000-0000-0000-0000-000000000003';
  confirmer uuid := 'b1000000-0000-0000-0000-000000000004';
  other_id uuid := 'b1000000-0000-0000-0000-000000000005';
  questions text[];
  request jsonb;
  old_request jsonb;
  first_board jsonb;
  saved_completion timestamptz;
  event_before text := (select md5(to_jsonb(e)::text) from public.event_settings e where id);
  reps_before text := (select md5(coalesce(jsonb_agg(jsonb_build_array(id, representative_id) order by id)::text, '[]')) from public.teams);
  i integer;
begin
  select array_agg('Question ' || n order by n) into questions from generate_series(1,25) n;
  perform set_config('request.jwt.claim.sub', owner_id::text, true);
  update public.members set active = false where id = owner_id;
  begin
    perform public.manage_bingo('open');
    raise exception 'inactive owner opened game';
  exception when insufficient_privilege then null; end;
  update public.members set active = true where id = owner_id;
  begin
    perform public.save_bingo_config(array['too few'], '');
    raise exception 'invalid question count accepted';
  exception when invalid_parameter_value then null; end;
  perform public.save_bingo_config(questions, 'Bingo prize');
  perform public.manage_bingo('open');
  if not exists(select 1 from private.bingo_game where closes_at = opens_at + interval '25 minutes') then raise exception 'wrong duration'; end if;
  begin
    perform public.save_bingo_config(questions, 'changed');
    raise exception 'edited opened game';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.manage_bingo('open');
    raise exception 'reopened game';
  exception when invalid_parameter_value then null; end;

  perform set_config('request.jwt.claim.sub', person_id::text, true);
  first_board := public.get_bingo()->'board';
  if jsonb_array_length(first_board) <> 25 or first_board <> public.get_bingo()->'board' then raise exception 'board not stable'; end if;
  if (select count(distinct x->>'question') from jsonb_array_elements(first_board) x) <> 25 then raise exception 'questions not shuffled permutation'; end if;
  request := public.request_bingo_confirmation(0);
  begin
    perform public.request_bingo_confirmation(1);
    raise exception 'rapid QR generation allowed';
  exception when invalid_parameter_value then null; end;
  if public.confirm_bingo(request->>'token')->>'error' is null then raise exception 'self confirmation allowed'; end if;
  perform set_config('request.jwt.claim.sub', confirmer::text, true);
  if public.inspect_bingo_confirmation(request->>'token')->>'question' is null then raise exception 'inspect failed'; end if;
  if exists(select 1 from private.bingo_marks where member_id = person_id) then raise exception 'GET consumed request'; end if;
  if public.confirm_bingo(request->>'code')->>'confirmed' <> 'true' then raise exception 'manual code confirm failed'; end if;
  if public.confirm_bingo(request->>'token')->>'error' is null then raise exception 'token replay allowed'; end if;

  perform set_config('request.jwt.claim.sub', person_id::text, true);
  update private.bingo_requests set created_at = created_at - interval '3 seconds' where member_id = person_id;
  request := public.request_bingo_confirmation(1);
  perform set_config('request.jwt.claim.sub', confirmer::text, true);
  if public.confirm_bingo(request->>'token')->>'error' is null then raise exception 'same counterpart reused'; end if;
  old_request := request;
  perform set_config('request.jwt.claim.sub', person_id::text, true);
  update private.bingo_requests set created_at = created_at - interval '3 seconds' where member_id = person_id;
  request := public.request_bingo_confirmation(1);
  perform set_config('request.jwt.claim.sub', other_id::text, true);
  if public.confirm_bingo(old_request->>'token')->>'error' is null then raise exception 'replaced token usable'; end if;
  update private.bingo_requests set expires_at = clock_timestamp() - interval '1 second' where token = (request->>'token')::uuid;
  if public.confirm_bingo(request->>'token')->>'error' is null then raise exception 'expired QR usable'; end if;

  -- Complete three rows using distinct counterpart accounts, all with server-time marks.
  for i in 1..14 loop
    perform set_config('request.jwt.claim.sub', person_id::text, true);
    update private.bingo_requests set created_at = created_at - interval '3 seconds' where member_id = person_id;
    request := public.request_bingo_confirmation(i);
    perform set_config('request.jwt.claim.sub', ('b1000000-0000-0000-0000-' || lpad((i+4)::text,12,'0')), true);
    if public.confirm_bingo(request->>'token')->>'confirmed' <> 'true' then raise exception 'confirmation % failed', i; end if;
  end loop;
  perform set_config('request.jwt.claim.sub', person_id::text, true);
  if (public.get_bingo()->>'completed_lines')::integer <> 3 or public.get_bingo()->>'completed_at' is null then raise exception 'three-line completion failed'; end if;
  if public.get_bingo()::text like '%@example.test%' or public.get_bingo() ? 'participants' or public.get_bingo() ? 'flags' then
    raise exception 'staff-only email or aggregates leaked to participant';
  end if;
  select completed_at into saved_completion from private.bingo_boards where member_id = person_id;
  if private.bingo_line_count(array[0,6,12,18,24,4,8,16,20]) <> 2
    or private.bingo_line_count(array(select generate_series(0,24))) <> 12
    or private.bingo_line_count(null) <> 0 then raise exception 'diagonal/full/empty line count wrong'; end if;
  perform set_config('request.jwt.claim.sub', staff_id::text, true);
  if jsonb_array_length(public.get_bingo()->'flags') = 0 then raise exception 'rapid confirmations not flagged'; end if;
  if jsonb_array_length(public.get_bingo()->'participants') <> 1 then raise exception 'staff aggregate wrong'; end if;
  if public.get_bingo()->'participants'->0->>'email' <> 'bingo3@example.test'
    or public.get_bingo()->'flags'->0->>'requester_email' <> 'bingo3@example.test'
    or public.get_bingo()->'flags'->0->>'confirmer_email' is null then
    raise exception 'staff cannot disambiguate same-name participants';
  end if;

  perform set_config('request.jwt.claim.sub', other_id::text, true);
  update private.bingo_lookup_limits set window_at = clock_timestamp() - interval '2 minutes' where member_id = other_id;
  for i in 1..30 loop perform public.inspect_bingo_confirmation('INVALID'); end loop;
  if public.inspect_bingo_confirmation('INVALID')->>'error' not like '%1분%' then raise exception 'lookup rate limit missing'; end if;
  if (select attempts from private.bingo_lookup_limits where member_id = other_id) <> 31 then raise exception 'invalid lookup increments lost'; end if;

  perform set_config('request.jwt.claim.sub', person_id::text, true);
  update private.bingo_requests set created_at = created_at - interval '3 seconds' where member_id = person_id;
  request := public.request_bingo_confirmation(15);
  update public.members set active = false where id = person_id;
  begin
    perform public.get_bingo();
    raise exception 'inactive participant read';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub', 'b1000000-0000-0000-0000-000000000031', true);
  if public.confirm_bingo(request->>'token')->>'error' is null then raise exception 'inactive requester accepted'; end if;
  update public.members set active = true where id = person_id;

  update private.bingo_game set opens_at = opens_at - interval '31 minutes', closes_at = closes_at - interval '31 minutes' where id;
  perform set_config('request.jwt.claim.sub', person_id::text, true);
  if public.get_bingo_status()->>'status' <> 'closed' then raise exception 'clock expiry not reflected'; end if;
  begin
    perform public.request_bingo_confirmation(15);
    raise exception 'request after automatic expiry';
  exception when invalid_parameter_value then null; end;
  perform set_config('request.jwt.claim.sub', 'b1000000-0000-0000-0000-000000000031', true);
  if public.confirm_bingo(request->>'token')->>'error' is null then raise exception 'confirm after automatic expiry'; end if;
  update private.bingo_game set opens_at = opens_at + interval '31 minutes', closes_at = closes_at + interval '31 minutes' where id;

  perform set_config('request.jwt.claim.sub', owner_id::text, true);
  perform public.manage_bingo('close');
  perform set_config('request.jwt.claim.sub', person_id::text, true);
  if public.get_bingo()->>'status' <> 'closed' or jsonb_array_length(public.get_bingo()->'board') <> 25 then raise exception 'closed board not retained'; end if;
  begin
    perform public.request_bingo_confirmation(15);
    raise exception 'request after close';
  exception when invalid_parameter_value then null; end;
  perform set_config('request.jwt.claim.sub', 'b1000000-0000-0000-0000-000000000031', true);
  if public.confirm_bingo(request->>'token')->>'error' is null then raise exception 'confirm after close'; end if;
  if saved_completion is distinct from (select completed_at from private.bingo_boards where member_id = person_id) then raise exception 'completion changed'; end if;
  if event_before <> (select md5(to_jsonb(e)::text) from public.event_settings e where id)
    or reps_before <> (select md5(coalesce(jsonb_agg(jsonb_build_array(id, representative_id) order by id)::text, '[]')) from public.teams) then
    raise exception 'existing event or representatives changed';
  end if;
end;
$$;

select '1..1' as tap;
select 'ok 1 - hidden 25-minute bingo, atomic QR confirmation, replay/expiry/role protections, line completion and rapid flags' as tap;
rollback;

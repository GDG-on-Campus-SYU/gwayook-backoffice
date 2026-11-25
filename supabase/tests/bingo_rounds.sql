begin;

insert into auth.users(id,email)
select ('b2000000-0000-0000-0000-' || lpad(n::text,12,'0'))::uuid, 'round' || n || '@example.test' from generate_series(1,6) n;
insert into public.members(id,name,email,auth_user_id,role)
select id,'Round person ' || row_number() over(order by email),email,id,case when email='round1@example.test' then 'owner' when email='round2@example.test' then 'staff' else 'participant' end
from auth.users where email like 'round%@example.test';

\ir fixtures/consented-members.sql
select pg_temp.consent_fixture_members('{"team":false,"presentation":false,"bingo":true}');

do $$
declare
  owner_id uuid := 'b2000000-0000-0000-0000-000000000001';
  staff_id uuid := 'b2000000-0000-0000-0000-000000000002';
  person_id uuid := 'b2000000-0000-0000-0000-000000000003';
  confirmer uuid := 'b2000000-0000-0000-0000-000000000004';
  other_id uuid := 'b2000000-0000-0000-0000-000000000005';
  p_questions text[];
  request jsonb;
  pending jsonb;
  board_before jsonb;
  records_before jsonb;
  round_before jsonb;
  event_before jsonb := (select to_jsonb(e) from public.event_settings e where id);
  reps_before jsonb := (select coalesce(jsonb_agg(jsonb_build_array(id,representative_id) order by id),'[]'::jsonb) from public.teams);
  votes_before jsonb := (select coalesce(jsonb_agg(to_jsonb(v) order by member_id),'[]'::jsonb) from private.votes v);
  fn text;
begin
  foreach fn in array array['get_bingo_round(integer)','manage_bingo_round(text,integer)','request_bingo_confirmation_round(integer,integer)'] loop
    if has_function_privilege('anon','public.'||fn,'execute') or has_function_privilege('service_role','public.'||fn,'execute') then
      raise exception 'unexpected round API grant: %', fn;
    end if;
  end loop;
  if has_table_privilege('authenticated','private.bingo_rounds','select') or has_table_privilege('authenticated','private.bingo_rounds','update') then
    raise exception 'direct round history exposed';
  end if;
  select array_agg('Round question ' || n order by n) into p_questions from generate_series(1,25) n;
  perform set_config('request.jwt.claim.sub',person_id::text,true);
  if public.get_bingo_round(1) <> '{"status":"hidden"}'::jsonb then raise exception 'draft history leaked'; end if;
  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  begin
    perform public.manage_bingo_round('restart',1);
    raise exception 'unopened game restarted';
  exception when invalid_parameter_value then null; end;
  perform public.save_bingo_config(p_questions,'Round prize');
  perform public.manage_bingo_round('open',1);
  begin
    perform public.manage_bingo_round('restart',1);
    raise exception 'active game restarted';
  exception when invalid_parameter_value then null; end;
  perform set_config('request.jwt.claim.sub',person_id::text,true);
  perform public.get_bingo();
  request := public.request_bingo_confirmation_round(1,0);
  perform set_config('request.jwt.claim.sub',confirmer::text,true);
  if public.confirm_bingo(request->>'token')->>'confirmed' <> 'true' then raise exception 'round1 confirmation failed'; end if;
  perform set_config('request.jwt.claim.sub',person_id::text,true);
  update private.bingo_requests set created_at=created_at-interval '3 seconds' where round_no=1 and member_id=person_id;
  pending := public.request_bingo_confirmation_round(1,1);
  board_before := public.get_bingo()->'board';
  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  perform public.manage_bingo_round('close',1);
  select to_jsonb(r) into round_before from private.bingo_rounds r where round_no=1;
  select jsonb_build_object(
    'boards',(select jsonb_agg(to_jsonb(b) order by member_id) from private.bingo_boards b where round_no=1),
    'marks',(select jsonb_agg(to_jsonb(m) order by member_id,cell) from private.bingo_marks m where round_no=1),
    'requests',(select jsonb_agg(to_jsonb(q) order by token) from private.bingo_requests q where round_no=1)
  ) into records_before;
  perform set_config('request.jwt.claim.sub',staff_id::text,true);
  begin
    perform public.manage_bingo_round('restart',1);
    raise exception 'staff restarted game';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub',person_id::text,true);
  begin
    perform public.manage_bingo_round('restart',1);
    raise exception 'participant restarted game';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  update public.members set active=false where id=owner_id;
  begin
    perform public.manage_bingo_round('restart',1);
    raise exception 'inactive owner restarted';
  exception when insufficient_privilege then null; end;
  update public.members set active=true where id=owner_id;
  perform public.manage_bingo_round('restart',1);
  if not exists(select 1 from private.bingo_game where round_no=2 and closes_at=opens_at+interval '25 minutes' and closed_at is null and questions=p_questions and prize='Round prize') then
    raise exception 'new round state invalid';
  end if;
  if (public.get_bingo()->>'round_no')::integer <> 2 or public.get_bingo()->>'status'<>'open' then raise exception 'new current round not exposed'; end if;
  if (select to_jsonb(r) from private.bingo_rounds r where round_no=1) <> round_before then raise exception 'archived round config changed'; end if;
  if records_before <> (select jsonb_build_object(
    'boards',(select jsonb_agg(to_jsonb(b) order by member_id) from private.bingo_boards b where round_no=1),
    'marks',(select jsonb_agg(to_jsonb(m) order by member_id,cell) from private.bingo_marks m where round_no=1),
    'requests',(select jsonb_agg(to_jsonb(q) order by token) from private.bingo_requests q where round_no=1))) then raise exception 'old records changed on restart'; end if;
  begin
    perform public.manage_bingo_round('restart',1);
    raise exception 'duplicate stale restart accepted';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.manage_bingo_round('close',1);
    raise exception 'stale close targeted new round';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.manage_bingo('close');
    raise exception 'legacy close targeted new round';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.manage_bingo_round('close',null);
    raise exception 'missing expected round accepted';
  exception when invalid_parameter_value then null; end;

  perform set_config('request.jwt.claim.sub',person_id::text,true);
  if public.get_bingo_round(1)->'board' <> board_before or public.get_bingo_round(1)->>'status'<>'closed'
    or public.get_bingo_round(1)->>'is_current'<>'false' or public.get_bingo_round(1)::text like '%@example.test%'
    or public.get_bingo_round(1) ? 'participants' then raise exception 'archive changed or leaked data'; end if;
  if jsonb_array_length(public.get_bingo()->'rounds')<>2 or public.get_bingo()->>'is_current'<>'true'
    or (public.get_bingo()->>'completed_lines')::integer<>0
    or exists(select 1 from jsonb_array_elements(public.get_bingo()->'board') c where c->>'confirmed_at' is not null) then
    raise exception 'new board retained previous marks';
  end if;
  begin
    perform public.request_bingo_confirmation_round(1,2);
    raise exception 'stale request targeted new round';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.request_bingo_confirmation(2);
    raise exception 'legacy request targeted new round';
  exception when invalid_parameter_value then null; end;
  request := public.request_bingo_confirmation_round(2,0);
  perform set_config('request.jwt.claim.sub',confirmer::text,true);
  if public.inspect_bingo_confirmation(pending->>'token')->>'error' is null or public.confirm_bingo(pending->>'code')->>'error' is null then
    raise exception 'old unexpired QR usable in new round';
  end if;
  if public.confirm_bingo(request->>'token')->>'confirmed'<>'true' then raise exception 'counterpart cannot confirm again in new round'; end if;
  perform set_config('request.jwt.claim.sub',other_id::text,true);
  if jsonb_array_length(public.get_bingo_round(1)->'board')<>0
    or exists(select 1 from private.bingo_boards where round_no=1 and member_id=other_id) then raise exception 'historical read created board or exposed others'; end if;
  begin
    perform public.get_bingo_round(999);
    raise exception 'unknown round returned data';
  exception when invalid_parameter_value then null; end;
  perform set_config('request.jwt.claim.sub',staff_id::text,true);
  if jsonb_array_length(public.get_bingo_round(1)->'participants')<>1
    or jsonb_array_length(public.get_bingo_round(2)->'participants')<>1
    or (public.get_bingo_round(1)->'participants'->0->>'marked_count')::integer<>1
    or (public.get_bingo_round(2)->'participants'->0->>'marked_count')::integer<>1 then raise exception 'round aggregates mixed'; end if;

  update private.bingo_game set opens_at=opens_at-interval '31 minutes', closes_at=closes_at-interval '31 minutes' where id;
  if public.get_bingo_status()->>'status'<>'closed' or (public.get_bingo_status()->>'round_no')::integer<>2 then raise exception 'expiry implicitly restarted game'; end if;
  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  perform public.manage_bingo_round('restart',2);
  if (public.get_bingo()->>'round_no')::integer<>3 or public.get_bingo()->>'status'<>'open' then raise exception 'expired round restart failed'; end if;
  if event_before<>(select to_jsonb(e) from public.event_settings e where id)
    or reps_before<>(select coalesce(jsonb_agg(jsonb_build_array(id,representative_id) order by id),'[]'::jsonb) from public.teams)
    or votes_before<>(select coalesce(jsonb_agg(to_jsonb(v) order by member_id),'[]'::jsonb) from private.votes v) then raise exception 'unrelated event/reps/votes changed'; end if;
end;
$$;

select '1..1' as tap;
select 'ok 1 - owner-only round restart, archive preservation/privacy, stale guards, legacy guards, scoped QR and expiry' as tap;
rollback;

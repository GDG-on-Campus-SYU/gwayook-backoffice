begin;

insert into auth.users(id, email)
select ('b3000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, 'ranking' || n || '@example.test' from generate_series(1,30) n;
insert into public.teams(id, name) values
  ('b3100000-0000-0000-0000-000000000001', 'Completion team A'),
  ('b3100000-0000-0000-0000-000000000002', 'Completion team B');
insert into public.members(id, name, email, auth_user_id, role, team_id)
select id, 'Ranking ' || split_part(email, '@', 1), email, id,
  case when email = 'ranking1@example.test' then 'owner' when email = 'ranking2@example.test' then 'staff' else 'participant' end,
  case when email = 'ranking3@example.test' then 'b3100000-0000-0000-0000-000000000001'::uuid end
from auth.users where email like 'ranking%@example.test';

\ir fixtures/consented-members.sql
select pg_temp.consent_fixture_members('{"team":false,"presentation":false,"bingo":true}');

do $$
declare
  owner_id uuid := 'b3000000-0000-0000-0000-000000000001';
  staff_id uuid := 'b3000000-0000-0000-0000-000000000002';
  requester_id uuid := 'b3000000-0000-0000-0000-000000000003';
  confirmer_id uuid := 'b3000000-0000-0000-0000-000000000004';
  another_id uuid := 'b3000000-0000-0000-0000-000000000005';
  request jsonb;
  finished timestamptz;
  original jsonb;
  result jsonb;
  person jsonb;
  event_before jsonb := (select to_jsonb(e) from public.event_settings e where id);
  votes_before jsonb := (select coalesce(jsonb_agg(to_jsonb(v) order by member_id), '[]') from private.votes v);
  awards_before jsonb := (select coalesce(jsonb_agg(to_jsonb(a) order by team_id), '[]') from private.award_decisions a);
begin
  if has_table_privilege('authenticated', 'private.bingo_boards', 'update')
    or has_function_privilege('authenticated', 'private.bingo_confirmation(text,boolean)', 'execute') then
    raise exception 'completion snapshot exposed to direct writes';
  end if;
  perform set_config('request.jwt.claim.sub', owner_id::text, true);
  perform public.save_bingo_config(array_fill('Ranking question'::text, array[25]), 'Undecided prize');
  perform public.manage_bingo_round('open', 1);
  perform set_config('request.jwt.claim.sub', requester_id::text, true);
  perform public.get_bingo();
  insert into private.bingo_marks(round_no, member_id, cell, confirmed_by, confirmed_at)
    select 1, requester_id, n, ('b3000000-0000-0000-0000-' || lpad((n+10)::text,12,'0'))::uuid, clock_timestamp() - interval '20 seconds'
    from generate_series(0,13) n;
  request := public.request_bingo_confirmation_round(1,14);
  perform set_config('request.jwt.claim.sub', confirmer_id::text, true);
  if public.confirm_bingo(request->>'token')->>'confirmed' is distinct from 'true' then raise exception 'completion confirmation failed'; end if;
  select completed_at, to_jsonb(b) into finished, original from private.bingo_boards b where round_no = 1 and member_id = requester_id;
  if finished is null or original->>'completed_team_id' is distinct from 'b3100000-0000-0000-0000-000000000001'
    or original->>'completed_team_name' is distinct from 'Completion team A' then raise exception 'first completion did not snapshot team'; end if;

  update public.members set team_id = 'b3100000-0000-0000-0000-000000000002' where id = requester_id;
  update public.teams set name = 'Renamed A' where id = 'b3100000-0000-0000-0000-000000000001';
  update private.bingo_requests set created_at = created_at - interval '3 seconds' where round_no = 1 and member_id = requester_id;
  perform set_config('request.jwt.claim.sub', requester_id::text, true);
  request := public.request_bingo_confirmation_round(1,15);
  perform set_config('request.jwt.claim.sub', another_id::text, true);
  if public.confirm_bingo(request->>'token')->>'confirmed' is distinct from 'true' then raise exception 'later confirmation failed'; end if;
  if original <> (select to_jsonb(b) from private.bingo_boards b where round_no = 1 and member_id = requester_id) then
    raise exception 'later completion or team edit changed the first completion snapshot';
  end if;

  insert into private.bingo_boards(round_no, member_id, question_order, completed_at)
    select 1, ('b3000000-0000-0000-0000-' || lpad(n::text,12,'0'))::uuid, array(select generate_series(1,25)),
      case when n in (4,5) then finished + interval '1 second' when n = 6 then finished + interval '2 seconds'
        when n = 7 then finished + interval '3 seconds' end from generate_series(4,8) n;
  perform set_config('request.jwt.claim.sub', staff_id::text, true);
  execute 'set local role authenticated';
  result := public.get_bingo_round(1);
  execute 'reset role';
  if (select jsonb_agg((p->>'completion_rank')::integer order by p->>'completed_at', p->>'member_id')
    from jsonb_array_elements(result->'participants') p where p->>'completed_at' is not null) <> '[1,2,2,4,5]'::jsonb then
    raise exception 'completion ranking did not preserve ties and gaps';
  end if;
  select p into person from jsonb_array_elements(result->'participants') p where p->>'member_id' = confirmer_id::text;
  if (person->>'completion_tied_count')::integer is distinct from 2 or person->>'completed_team_name' is not null then
    raise exception 'tied count or unknown historical team incorrect';
  end if;
  select p into person from jsonb_array_elements(result->'participants') p where p->>'member_id' = requester_id::text;
  if person->>'completed_team_name' is distinct from 'Completion team A' or coalesce((person->>'completion_elapsed_seconds')::numeric, -1) < 0 then
    raise exception 'completion report lost snapshot or elapsed time';
  end if;
  select p into person from jsonb_array_elements(result->'participants') p where p->>'member_id' = 'b3000000-0000-0000-0000-000000000008';
  if person->>'completion_rank' is not null or person->>'completion_elapsed_seconds' is not null then
    raise exception 'unfinished participant received completion rank';
  end if;
  perform set_config('request.jwt.claim.sub', requester_id::text, true);
  execute 'set local role authenticated';
  if public.get_bingo() ? 'participants' or public.get_bingo_round(1) ? 'flags' then raise exception 'participant saw other completion records'; end if;
  execute 'reset role';

  perform set_config('request.jwt.claim.sub', owner_id::text, true);
  perform public.manage_bingo_round('close', 1);
  perform public.manage_bingo_round('restart', 1);
  if (public.get_bingo_round(1)->'participants') <> result->'participants' then raise exception 'new round changed old completion ranking'; end if;
  perform set_config('request.jwt.claim.sub', requester_id::text, true);
  perform public.get_bingo();
  insert into private.bingo_marks(round_no, member_id, cell, confirmed_by, confirmed_at)
    select 2, requester_id, n, ('b3000000-0000-0000-0000-' || lpad((n+10)::text,12,'0'))::uuid, clock_timestamp() - interval '20 seconds'
    from generate_series(0,13) n;
  request := public.request_bingo_confirmation_round(2,14);
  perform set_config('request.jwt.claim.sub', confirmer_id::text, true);
  if public.confirm_bingo(request->>'token')->>'confirmed' is distinct from 'true' then raise exception 'new round confirmation failed'; end if;
  perform set_config('request.jwt.claim.sub', staff_id::text, true);
  person := public.get_bingo_round(2)->'participants'->0;
  if jsonb_array_length(public.get_bingo_round(2)->'participants') is distinct from 1 or (person->>'completion_rank')::integer is distinct from 1
    or person->>'completed_team_name' is distinct from 'Completion team B' then raise exception 'new round did not start independent ranking and team snapshot'; end if;
  if original <> (select to_jsonb(b) from private.bingo_boards b where round_no = 1 and member_id = requester_id) then
    raise exception 'new round altered original completion';
  end if;
  if event_before <> (select to_jsonb(e) from public.event_settings e where id)
    or votes_before <> (select coalesce(jsonb_agg(to_jsonb(v) order by member_id), '[]') from private.votes v)
    or awards_before <> (select coalesce(jsonb_agg(to_jsonb(a) order by team_id), '[]') from private.award_decisions a) then
    raise exception 'bingo ranking changed event deadlines, voting or awards';
  end if;
end;
$$;

select '1..1' as tap;
select 'ok 1 - bingo completion ranking ties, immutable team/time snapshots, round isolation, historical unknown teams and staff-only visibility' as tap;
rollback;

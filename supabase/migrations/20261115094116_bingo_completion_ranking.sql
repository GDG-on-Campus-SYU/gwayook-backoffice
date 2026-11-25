-- Do not infer an earlier completion's team from today's membership.
alter table private.bingo_boards
  add column completed_team_id uuid references public.teams(id),
  add column completed_team_name text;
create index bingo_boards_completed_team_id on private.bingo_boards(completed_team_id);
create or replace function private.get_bingo_round(p_round_no integer) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  actor public.members := private.current_member();
  game private.bingo_game;
  selected private.bingo_rounds;
  board private.bingo_boards;
  result jsonb;
  current_round boolean;
begin
  if actor.id is null then raise exception '참가자 등록과 로그인이 필요합니다.' using errcode = '42501'; end if;
  select * into strict game from private.bingo_game where id for share;
  actor := private.current_member();
  if actor.id is null then raise exception '참가자 등록과 로그인이 필요합니다.' using errcode = '42501'; end if;
  if actor.role = 'participant' and game.opens_at is null then return jsonb_build_object('status', 'hidden'); end if;
  p_round_no := coalesce(p_round_no, game.round_no);
  current_round := p_round_no = game.round_no;
  if current_round then
    select game.round_no, game.questions, game.prize, game.opens_at, game.closes_at, game.closed_at into selected;
  else
    select * into selected from private.bingo_rounds r where r.round_no = p_round_no and r.round_no < game.round_no and r.opens_at is not null;
    if selected.round_no is null then raise exception '빙고 회차를 찾을 수 없습니다.' using errcode = '22023'; end if;
  end if;
  result := jsonb_build_object(
    'status', case when selected.opens_at is null then 'draft' when not current_round or selected.closed_at is not null or clock_timestamp() >= selected.closes_at then 'closed' else 'open' end,
    'round_no', p_round_no, 'is_current', current_round,
    'opens_at', selected.opens_at, 'closes_at', selected.closes_at, 'closed_at', selected.closed_at, 'prize', selected.prize,
    'board', '[]'::jsonb, 'completed_lines', 0, 'completed_at', null,
    'rounds', (select jsonb_agg(jsonb_build_object('round_no', r.round_no,
      'status', case when r.opens_at is null then 'draft' when r.round_no <> game.round_no or r.closed_at is not null or clock_timestamp() >= r.closes_at then 'closed' else 'open' end,
      'opens_at', r.opens_at, 'closes_at', r.closes_at, 'closed_at', r.closed_at, 'is_current', r.round_no = game.round_no) order by r.round_no desc)
      from (select round_no, opens_at, closes_at, closed_at from private.bingo_rounds where round_no < game.round_no and opens_at is not null
        union all select game.round_no, game.opens_at, game.closes_at, game.closed_at) r));
  if actor.role in ('owner', 'staff') then
    return result || jsonb_build_object('questions', selected.questions,
      'participants', coalesce((select jsonb_agg(jsonb_build_object(
        'member_id', b.member_id, 'name', m.name, 'email', m.email,
        'marked_count', (select count(*) from private.bingo_marks k where k.round_no = p_round_no and k.member_id = b.member_id),
        'completed_lines', private.bingo_line_count((select array_agg(k.cell) from private.bingo_marks k where k.round_no = p_round_no and k.member_id = b.member_id)),
        'completed_at', b.completed_at,
        'completion_rank', case when b.completed_at is not null then b.completion_rank end,
        'completion_tied_count', b.completion_tied_count,
        'completed_team_id', b.completed_team_id, 'completed_team_name', b.completed_team_name,
        'completion_elapsed_seconds', case when b.completed_at is not null then greatest(0, extract(epoch from b.completed_at - selected.opens_at)) end,
        'suspicious_count', (select count(*) from private.bingo_marks k where k.round_no = p_round_no and k.member_id = b.member_id and k.suspicious)
      ) order by b.completed_at nulls last, m.name) from (select records.*, rank() over (order by completed_at nulls last) completion_rank,
        count(completed_at) over (partition by completed_at) completion_tied_count
        from private.bingo_boards records where round_no = p_round_no) b join public.members m on m.id = b.member_id), '[]'::jsonb),
      'flags', coalesce((select jsonb_agg(to_jsonb(f) order by f.confirmed_at desc) from (
        select m.name requester_name, m.email requester_email, c.name confirmer_name, c.email confirmer_email, k.cell,
          selected.questions[b.question_order[k.cell + 1]] question, k.confirmed_at,
          '10초 안에 3칸 이상 확인됨'::text reason
        from private.bingo_marks k join private.bingo_boards b on b.round_no = k.round_no and b.member_id = k.member_id
        join public.members m on m.id = k.member_id join public.members c on c.id = k.confirmed_by
        where k.round_no = p_round_no and k.suspicious order by k.confirmed_at desc limit 100
      ) f), '[]'::jsonb));
  end if;
  if current_round and result->>'status' = 'open' then
    insert into private.bingo_boards(round_no, member_id, question_order)
      select p_round_no, actor.id, array_agg(n order by random()) from generate_series(1,25) n
      on conflict (round_no, member_id) do nothing;
  end if;
  select * into board from private.bingo_boards where round_no = p_round_no and member_id = actor.id;
  if board.member_id is null then return result; end if;
  return result || jsonb_build_object('completed_at', board.completed_at,
    'completed_lines', private.bingo_line_count((select array_agg(cell) from private.bingo_marks where round_no = p_round_no and member_id = actor.id)),
    'board', (select jsonb_agg(jsonb_build_object('cell', n, 'question', selected.questions[board.question_order[n+1]],
      'confirmed_by', m.name, 'confirmed_at', k.confirmed_at) order by n)
      from generate_series(0,24) n left join private.bingo_marks k on k.round_no = p_round_no and k.member_id = actor.id and k.cell = n
      left join public.members m on m.id = k.confirmed_by));
end;
$$;

create or replace function private.bingo_confirmation(p_token text, p_confirm boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  actor public.members := private.current_member();
  requester public.members;
  game private.bingo_game;
  board private.bingo_boards;
  request private.bingo_requests;
  v_now timestamptz;
  attempts integer;
  suspect boolean;
  question text;
begin
  if actor.id is null or actor.role <> 'participant' then raise exception '참가자만 상대방을 확인할 수 있습니다.' using errcode = '42501'; end if;
  select * into strict game from private.bingo_game where id for update;
  actor := private.current_member();
  if actor.id is null or actor.role <> 'participant' then raise exception '참가자만 상대방을 확인할 수 있습니다.' using errcode = '42501'; end if;
  v_now := clock_timestamp();
  if game.opens_at is null or game.closed_at is not null or v_now >= game.closes_at then
    return jsonb_build_object('error', '지금은 빙고 참여 시간이 아닙니다.');
  end if;
  insert into private.bingo_lookup_limits(member_id, window_at, attempts) values (actor.id, v_now, 1)
    on conflict(member_id) do update set
      window_at = case when bingo_lookup_limits.window_at <= v_now - interval '1 minute' then v_now else bingo_lookup_limits.window_at end,
      attempts = case when bingo_lookup_limits.window_at <= v_now - interval '1 minute' then 1 else bingo_lookup_limits.attempts + 1 end
    returning bingo_lookup_limits.attempts into attempts;
  if attempts > 30 then return jsonb_build_object('error', '확인 요청이 많습니다. 1분 뒤 다시 시도해 주세요.'); end if;
  p_token := upper(btrim(coalesce(p_token, '')));
  if p_token !~ '^([A-F0-9]{12}|[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12})$' then
    return jsonb_build_object('error', '유효하지 않거나 만료된 QR·코드입니다.');
  end if;
  select * into request from private.bingo_requests where round_no = game.round_no
    and (upper(token::text) = p_token or code = p_token) and used_at is null and revoked_at is null and expires_at > v_now;
  if request.token is null then return jsonb_build_object('error', '유효하지 않거나 만료된 QR·코드입니다.'); end if;
  if request.member_id = actor.id then return jsonb_build_object('error', '자신의 칸은 직접 확인할 수 없습니다.'); end if;
  -- Serialize completion's team snapshot with membership edits.
  select * into requester from public.members where id = request.member_id and active and role = 'participant' for share;
  if requester.id is null then return jsonb_build_object('error', '참가 상태가 변경되어 확인할 수 없습니다.'); end if;
  if exists (select 1 from private.bingo_marks where round_no = game.round_no and member_id = request.member_id and confirmed_by = actor.id) then
    return jsonb_build_object('error', '한 사람의 빙고판에서는 한 칸만 확인할 수 있습니다.');
  end if;
  if exists (select 1 from private.bingo_marks where round_no = game.round_no and member_id = request.member_id and cell = request.cell) then
    return jsonb_build_object('error', '이미 확인된 칸입니다.');
  end if;
  select * into strict board from private.bingo_boards where round_no = game.round_no and member_id = request.member_id;
  question := game.questions[board.question_order[request.cell + 1]];
  if not p_confirm then
    return jsonb_build_object('round_no', game.round_no, 'requester_name', requester.name, 'question', question, 'cell', request.cell, 'expires_at', request.expires_at);
  end if;
  select count(*) >= 2 into suspect from private.bingo_marks
    where round_no = game.round_no and member_id = request.member_id and confirmed_at >= v_now - interval '10 seconds';
  insert into private.bingo_marks(round_no, member_id, cell, confirmed_by, confirmed_at, suspicious)
    values (game.round_no, request.member_id, request.cell, actor.id, v_now, suspect);
  update private.bingo_requests set used_at = v_now where token = request.token;
  if private.bingo_line_count((select array_agg(cell) from private.bingo_marks where round_no = game.round_no and member_id = request.member_id)) >= 3 then
    update private.bingo_boards set completed_at = v_now, completed_team_id = requester.team_id,
      completed_team_name = coalesce((select name from public.teams where id = requester.team_id), '미배정')
      where round_no = game.round_no and member_id = request.member_id and completed_at is null;
  end if;
  return jsonb_build_object('confirmed', true, 'round_no', game.round_no, 'requester_name', requester.name, 'question', question);
end;
$$;

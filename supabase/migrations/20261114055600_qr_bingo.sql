create table private.bingo_game (
  id boolean primary key default true check (id),
  questions text[] not null default array_fill(''::text, array[25])
    check (cardinality(questions) = 25 and array_ndims(questions) = 1),
  prize text not null default '' check (char_length(prize) <= 500),
  opens_at timestamptz,
  closes_at timestamptz,
  closed_at timestamptz,
  check ((opens_at is null) = (closes_at is null)),
  check (closes_at = opens_at + interval '30 minutes')
);
insert into private.bingo_game default values;

create table private.bingo_boards (
  member_id uuid primary key references public.members(id),
  question_order integer[] not null check (cardinality(question_order) = 25),
  created_at timestamptz not null default clock_timestamp(),
  completed_at timestamptz
);

create table private.bingo_requests (
  token uuid primary key default gen_random_uuid(),
  code text not null unique default upper(left(replace(gen_random_uuid()::text, '-', ''), 12)),
  member_id uuid not null references private.bingo_boards(member_id),
  cell integer not null check (cell between 0 and 24),
  created_at timestamptz not null default clock_timestamp(),
  expires_at timestamptz not null,
  used_at timestamptz,
  revoked_at timestamptz
);
create unique index bingo_one_pending_request on private.bingo_requests(member_id)
  where used_at is null and revoked_at is null;
create index bingo_requests_member_created on private.bingo_requests(member_id, created_at desc);

create table private.bingo_marks (
  member_id uuid not null references private.bingo_boards(member_id),
  cell integer not null check (cell between 0 and 24),
  confirmed_by uuid not null references public.members(id),
  confirmed_at timestamptz not null,
  suspicious boolean not null default false,
  primary key (member_id, cell),
  unique (member_id, confirmed_by),
  check (member_id <> confirmed_by)
);
create index bingo_marks_confirmed_by on private.bingo_marks(confirmed_by);

create table private.bingo_lookup_limits (
  member_id uuid primary key references public.members(id),
  window_at timestamptz not null,
  attempts integer not null
);

alter table private.bingo_game enable row level security;
alter table private.bingo_boards enable row level security;
alter table private.bingo_requests enable row level security;
alter table private.bingo_marks enable row level security;
alter table private.bingo_lookup_limits enable row level security;
revoke all on private.bingo_game, private.bingo_boards, private.bingo_requests,
  private.bingo_marks, private.bingo_lookup_limits from public, anon, authenticated, service_role;

create function private.bingo_line_count(p_cells integer[]) returns integer
language sql immutable set search_path = '' as $$
  select count(*)::integer from (
    select array_agg(r * 5 + c order by c) cells from generate_series(0, 4) r cross join generate_series(0, 4) c group by r
    union all
    select array_agg(r * 5 + c order by r) from generate_series(0, 4) r cross join generate_series(0, 4) c group by c
    union all select array[0,6,12,18,24]
    union all select array[4,8,12,16,20]
  ) lines where cells <@ coalesce(p_cells, '{}'::integer[]);
$$;

create function private.get_bingo_status() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  actor public.members := private.current_member();
  game private.bingo_game;
begin
  if actor.id is null then raise exception '참가자 등록과 로그인이 필요합니다.' using errcode = '42501'; end if;
  select * into strict game from private.bingo_game where id;
  if game.opens_at is null then return jsonb_build_object('status', 'hidden'); end if;
  return jsonb_build_object('status', case when game.closed_at is not null or clock_timestamp() >= game.closes_at then 'closed' else 'open' end,
    'opens_at', game.opens_at, 'closes_at', game.closes_at);
end;
$$;

create function private.get_bingo() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  actor public.members := private.current_member();
  game private.bingo_game;
  board private.bingo_boards;
  result jsonb;
begin
  if actor.id is null then raise exception '참가자 등록과 로그인이 필요합니다.' using errcode = '42501'; end if;
  select * into strict game from private.bingo_game where id for share;
  actor := private.current_member();
  if actor.id is null then raise exception '참가자 등록과 로그인이 필요합니다.' using errcode = '42501'; end if;
  if actor.role = 'participant' and game.opens_at is null then return jsonb_build_object('status', 'hidden'); end if;
  result := jsonb_build_object(
    'status', case when game.opens_at is null then 'draft' when game.closed_at is not null or clock_timestamp() >= game.closes_at then 'closed' else 'open' end,
    'opens_at', game.opens_at, 'closes_at', game.closes_at, 'prize', game.prize,
    'board', '[]'::jsonb, 'completed_lines', 0, 'completed_at', null);
  if actor.role in ('owner', 'staff') then
    return result || jsonb_build_object('questions', game.questions,
      'participants', coalesce((select jsonb_agg(jsonb_build_object(
        'member_id', b.member_id, 'name', m.name, 'email', m.email,
        'marked_count', (select count(*) from private.bingo_marks k where k.member_id = b.member_id),
        'completed_lines', private.bingo_line_count((select array_agg(k.cell) from private.bingo_marks k where k.member_id = b.member_id)),
        'completed_at', b.completed_at,
        'suspicious_count', (select count(*) from private.bingo_marks k where k.member_id = b.member_id and k.suspicious)
      ) order by b.completed_at nulls last, m.name) from private.bingo_boards b join public.members m on m.id = b.member_id), '[]'::jsonb),
      'flags', coalesce((select jsonb_agg(to_jsonb(f) order by f.confirmed_at desc) from (
        select m.name requester_name, m.email requester_email, c.name confirmer_name, c.email confirmer_email, k.cell,
          game.questions[b.question_order[k.cell + 1]] question, k.confirmed_at,
          '10초 안에 3칸 이상 확인됨'::text reason
        from private.bingo_marks k join private.bingo_boards b on b.member_id = k.member_id
        join public.members m on m.id = k.member_id join public.members c on c.id = k.confirmed_by
        where k.suspicious order by k.confirmed_at desc limit 100
      ) f), '[]'::jsonb));
  end if;
  if result->>'status' = 'open' then
    insert into private.bingo_boards(member_id, question_order)
      select actor.id, array_agg(n order by random()) from generate_series(1,25) n
      on conflict (member_id) do nothing;
  end if;
  select * into board from private.bingo_boards where member_id = actor.id;
  if board.member_id is null then return result; end if;
  return result || jsonb_build_object('completed_at', board.completed_at,
    'completed_lines', private.bingo_line_count((select array_agg(cell) from private.bingo_marks where member_id = actor.id)),
    'board', (select jsonb_agg(jsonb_build_object('cell', n, 'question', game.questions[board.question_order[n+1]],
      'confirmed_by', m.name, 'confirmed_at', k.confirmed_at) order by n)
      from generate_series(0,24) n left join private.bingo_marks k on k.member_id = actor.id and k.cell = n
      left join public.members m on m.id = k.confirmed_by));
end;
$$;

create function private.save_bingo_config(p_questions text[], p_prize text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor public.members := private.current_member();
  game private.bingo_game;
begin
  if actor.id is null or actor.role <> 'owner' then raise exception '총관리자 권한이 필요합니다.' using errcode = '42501'; end if;
  if p_questions is null or cardinality(p_questions) <> 25 or array_ndims(p_questions) <> 1
    or exists (select 1 from unnest(p_questions) q where q is null or char_length(btrim(q)) > 200)
    or char_length(coalesce(p_prize, '')) > 500 then
    raise exception '문항은 25개, 각 200자 이하이며 상품 안내는 500자 이하로 입력해 주세요.' using errcode = '22023';
  end if;
  select * into strict game from private.bingo_game where id for update;
  actor := private.current_member();
  if actor.id is null or actor.role <> 'owner' then raise exception '총관리자 권한이 필요합니다.' using errcode = '42501'; end if;
  if game.opens_at is not null then raise exception '공개한 빙고의 문항과 상품은 변경할 수 없습니다.' using errcode = '22023'; end if;
  update private.bingo_game set questions = (select array_agg(btrim(q) order by n) from unnest(p_questions) with ordinality t(q,n)),
    prize = btrim(coalesce(p_prize, '')) where id;
  insert into public.audit_logs(actor_id, action) values (actor.id, 'bingo_config_saved');
end;
$$;

create function private.manage_bingo(p_operation text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor public.members := private.current_member();
  game private.bingo_game;
  v_now timestamptz;
begin
  if actor.id is null or actor.role <> 'owner' then raise exception '총관리자 권한이 필요합니다.' using errcode = '42501'; end if;
  select * into strict game from private.bingo_game where id for update;
  actor := private.current_member();
  if actor.id is null or actor.role <> 'owner' then raise exception '총관리자 권한이 필요합니다.' using errcode = '42501'; end if;
  v_now := clock_timestamp();
  if p_operation = 'open' then
    if game.opens_at is not null then raise exception '이미 공개한 빙고입니다.' using errcode = '22023'; end if;
    if exists (select 1 from unnest(game.questions) q where q !~ '[^[:space:]]') then
      raise exception '25개 문항을 모두 저장한 뒤 공개해 주세요.' using errcode = '22023';
    end if;
    update private.bingo_game set opens_at = v_now, closes_at = v_now + interval '30 minutes' where id;
  elsif p_operation = 'close' then
    if game.opens_at is null or game.closed_at is not null then raise exception '진행 중인 빙고가 없습니다.' using errcode = '22023'; end if;
    update private.bingo_game set closed_at = v_now where id;
  else
    raise exception '처리 종류를 확인해 주세요.' using errcode = '22023';
  end if;
  insert into public.audit_logs(actor_id, action) values (actor.id, 'bingo_' || p_operation);
end;
$$;

create function private.request_bingo_confirmation(p_cell integer) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  actor public.members := private.current_member();
  game private.bingo_game;
  board private.bingo_boards;
  request private.bingo_requests;
  v_now timestamptz;
begin
  if actor.id is null or actor.role <> 'participant' then raise exception '참가자만 빙고를 진행할 수 있습니다.' using errcode = '42501'; end if;
  if p_cell is null or p_cell not between 0 and 24 then raise exception '빙고 칸을 다시 선택해 주세요.' using errcode = '22023'; end if;
  select * into strict game from private.bingo_game where id for update;
  actor := private.current_member();
  if actor.id is null or actor.role <> 'participant' then raise exception '참가자만 빙고를 진행할 수 있습니다.' using errcode = '42501'; end if;
  v_now := clock_timestamp();
  if game.opens_at is null or game.closed_at is not null or v_now >= game.closes_at then
    raise exception '지금은 빙고 참여 시간이 아닙니다.' using errcode = '22023';
  end if;
  select * into board from private.bingo_boards where member_id = actor.id;
  if board.member_id is null then raise exception '빙고판을 먼저 열어 주세요.' using errcode = '22023'; end if;
  if exists (select 1 from private.bingo_marks where member_id = actor.id and cell = p_cell) then
    raise exception '이미 확인된 칸입니다.' using errcode = '22023';
  end if;
  if exists (select 1 from private.bingo_requests where member_id = actor.id and created_at > v_now - interval '2 seconds') then
    raise exception '잠시 뒤 QR을 다시 만들어 주세요.' using errcode = '22023';
  end if;
  update private.bingo_requests set revoked_at = v_now where member_id = actor.id and used_at is null and revoked_at is null;
  insert into private.bingo_requests(member_id, cell, created_at, expires_at)
    values (actor.id, p_cell, v_now, least(v_now + interval '2 minutes', game.closes_at)) returning * into request;
  return jsonb_build_object('token', request.token, 'code', request.code, 'expires_at', request.expires_at,
    'cell', p_cell, 'question', game.questions[board.question_order[p_cell+1]]);
end;
$$;

-- Invalid lookups return JSON so the per-member limit survives the API transaction.
create function private.bingo_confirmation(p_token text, p_confirm boolean) returns jsonb
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
  -- One game-row lock makes expiry, token consumption and line completion atomic.
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
  select * into request from private.bingo_requests
    where (upper(token::text) = p_token or code = p_token) and used_at is null and revoked_at is null and expires_at > v_now;
  if request.token is null then return jsonb_build_object('error', '유효하지 않거나 만료된 QR·코드입니다.'); end if;
  if request.member_id = actor.id then return jsonb_build_object('error', '자신의 칸은 직접 확인할 수 없습니다.'); end if;
  select * into requester from public.members where id = request.member_id and active and role = 'participant';
  if requester.id is null then return jsonb_build_object('error', '참가 상태가 변경되어 확인할 수 없습니다.'); end if;
  if exists (select 1 from private.bingo_marks where member_id = request.member_id and confirmed_by = actor.id) then
    return jsonb_build_object('error', '한 사람의 빙고판에서는 한 칸만 확인할 수 있습니다.');
  end if;
  if exists (select 1 from private.bingo_marks where member_id = request.member_id and cell = request.cell) then
    return jsonb_build_object('error', '이미 확인된 칸입니다.');
  end if;
  select * into strict board from private.bingo_boards where member_id = request.member_id;
  question := game.questions[board.question_order[request.cell + 1]];
  if not p_confirm then
    return jsonb_build_object('requester_name', requester.name, 'question', question, 'cell', request.cell, 'expires_at', request.expires_at);
  end if;
  select count(*) >= 2 into suspect from private.bingo_marks
    where member_id = request.member_id and confirmed_at >= v_now - interval '10 seconds';
  insert into private.bingo_marks(member_id, cell, confirmed_by, confirmed_at, suspicious)
    values (request.member_id, request.cell, actor.id, v_now, suspect);
  update private.bingo_requests set used_at = v_now where token = request.token;
  if private.bingo_line_count((select array_agg(cell) from private.bingo_marks where member_id = request.member_id)) >= 3 then
    update private.bingo_boards set completed_at = v_now where member_id = request.member_id and completed_at is null;
  end if;
  return jsonb_build_object('confirmed', true, 'requester_name', requester.name, 'question', question);
end;
$$;

create function public.get_bingo_status() returns jsonb
language sql security invoker set search_path = '' as $$ select private.get_bingo_status(); $$;
create function public.get_bingo() returns jsonb
language sql security invoker set search_path = '' as $$ select private.get_bingo(); $$;
create function public.save_bingo_config(p_questions text[], p_prize text) returns void
language sql security invoker set search_path = '' as $$ select private.save_bingo_config(p_questions, p_prize); $$;
create function public.manage_bingo(p_operation text) returns void
language sql security invoker set search_path = '' as $$ select private.manage_bingo(p_operation); $$;
create function public.request_bingo_confirmation(p_cell integer) returns jsonb
language sql security invoker set search_path = '' as $$ select private.request_bingo_confirmation(p_cell); $$;
create function private.inspect_bingo_confirmation(p_token text) returns jsonb
language sql security definer set search_path = '' as $$ select private.bingo_confirmation(p_token, false); $$;
create function public.inspect_bingo_confirmation(p_token text) returns jsonb
language sql security invoker set search_path = '' as $$ select private.inspect_bingo_confirmation(p_token); $$;
create function private.confirm_bingo(p_token text) returns jsonb
language sql security definer set search_path = '' as $$ select private.bingo_confirmation(p_token, true); $$;
create function public.confirm_bingo(p_token text) returns jsonb
language sql security invoker set search_path = '' as $$ select private.confirm_bingo(p_token); $$;

revoke all on function private.bingo_line_count(integer[]), private.bingo_confirmation(text, boolean)
  from public, anon, authenticated, service_role;
revoke all on function private.get_bingo_status(), public.get_bingo_status(), private.get_bingo(), public.get_bingo(),
  private.save_bingo_config(text[],text), public.save_bingo_config(text[],text),
  private.manage_bingo(text), public.manage_bingo(text),
  private.request_bingo_confirmation(integer), public.request_bingo_confirmation(integer),
  private.inspect_bingo_confirmation(text), public.inspect_bingo_confirmation(text),
  private.confirm_bingo(text), public.confirm_bingo(text)
  from public, anon, authenticated, service_role;
grant execute on function private.get_bingo_status(), public.get_bingo_status(), private.get_bingo(), public.get_bingo(),
  private.save_bingo_config(text[],text), public.save_bingo_config(text[],text),
  private.manage_bingo(text), public.manage_bingo(text),
  private.request_bingo_confirmation(integer), public.request_bingo_confirmation(integer),
  private.inspect_bingo_confirmation(text), public.inspect_bingo_confirmation(text),
  private.confirm_bingo(text), public.confirm_bingo(text) to authenticated;

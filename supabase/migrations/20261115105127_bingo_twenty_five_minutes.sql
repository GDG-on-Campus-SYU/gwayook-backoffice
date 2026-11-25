-- Keep every previously opened 30-minute round unchanged. Only subsequent
-- open/restart operations use 25 minutes; installing this migration starts nothing.
alter table private.bingo_game drop constraint bingo_game_check1;
alter table private.bingo_game add constraint bingo_game_duration_check
  check (closes_at = opens_at + interval '25 minutes' or closes_at = opens_at + interval '30 minutes');
alter table private.bingo_rounds drop constraint bingo_rounds_check1;
alter table private.bingo_rounds add constraint bingo_rounds_duration_check
  check (closes_at = opens_at + interval '25 minutes' or closes_at = opens_at + interval '30 minutes');

create or replace function private.manage_bingo_round(p_operation text, p_round_no integer) returns void
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
  if p_round_no is distinct from game.round_no then raise exception '빙고 회차가 변경되었습니다. 화면을 새로고침해 주세요.' using errcode = '22023'; end if;
  v_now := clock_timestamp();
  if p_operation = 'open' then
    if game.opens_at is not null then raise exception '이미 공개한 빙고입니다.' using errcode = '22023'; end if;
    if exists (select 1 from unnest(game.questions) q where q !~ '[^[:space:]]') then
      raise exception '25개 문항을 모두 저장한 뒤 공개해 주세요.' using errcode = '22023';
    end if;
    update private.bingo_game set opens_at = v_now, closes_at = v_now + interval '25 minutes' where id returning * into game;
  elsif p_operation = 'close' then
    if game.opens_at is null or game.closed_at is not null then raise exception '진행 중인 빙고가 없습니다.' using errcode = '22023'; end if;
    update private.bingo_game set closed_at = v_now where id returning * into game;
  elsif p_operation = 'restart' then
    if game.opens_at is null or (game.closed_at is null and v_now < game.closes_at) then
      raise exception '현재 빙고가 종료된 뒤 새 회차를 시작할 수 있습니다.' using errcode = '22023';
    end if;
    -- Archive the finished round without changing any board, mark or QR record.
    update private.bingo_rounds set questions = game.questions, prize = game.prize,
      opens_at = game.opens_at, closes_at = game.closes_at, closed_at = game.closed_at where round_no = game.round_no;
    insert into private.bingo_rounds(round_no, questions, prize, opens_at, closes_at)
      values (game.round_no + 1, game.questions, game.prize, v_now, v_now + interval '25 minutes');
    update private.bingo_game set round_no = game.round_no + 1, opens_at = v_now,
      closes_at = v_now + interval '25 minutes', closed_at = null where id returning * into game;
  else
    raise exception '처리 종류를 확인해 주세요.' using errcode = '22023';
  end if;
  update private.bingo_rounds set questions = game.questions, prize = game.prize,
    opens_at = game.opens_at, closes_at = game.closes_at, closed_at = game.closed_at where round_no = game.round_no;
  insert into public.audit_logs(actor_id, action, details)
    values (actor.id, 'bingo_' || p_operation, jsonb_build_object('round_no', game.round_no));
end;
$$;

-- CREATE OR REPLACE retains the existing grants; restate the private API boundary.
revoke all on function private.manage_bingo_round(text, integer) from public, anon, authenticated, service_role;
grant execute on function private.manage_bingo_round(text, integer) to authenticated;

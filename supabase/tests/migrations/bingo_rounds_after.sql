-- Run after bingo_rounds_before.sql and then the bingo_rounds migration.
do $$
declare
  before_data jsonb := (select data from migration_verification.bingo_before);
  after_data jsonb;
  person_id uuid := 'b3000000-0000-0000-0000-000000000003';
begin
  select jsonb_build_object(
    'game',(select to_jsonb(g)-'round_no' from private.bingo_game g where id),
    'boards',(select jsonb_agg(to_jsonb(b)-'round_no' order by member_id) from private.bingo_boards b),
    'marks',(select jsonb_agg(to_jsonb(m)-'round_no' order by member_id,cell) from private.bingo_marks m),
    'requests',(select jsonb_agg(to_jsonb(q)-'round_no' order by token) from private.bingo_requests q),
    'event',(select to_jsonb(e) from public.event_settings e where id),
    'representatives',(select coalesce(jsonb_agg(jsonb_build_array(id,representative_id) order by id),'[]'::jsonb) from public.teams),
    'audit',(select jsonb_agg(to_jsonb(a) order by id) from public.audit_logs a)
  ) into after_data;
  if after_data <> before_data then raise exception 'migration changed pre-existing data'; end if;
  if (select to_jsonb(r)-'round_no' from private.bingo_rounds r where round_no=1) <> (before_data->'game')-'id'
    or exists(select 1 from private.bingo_boards where round_no<>1)
    or exists(select 1 from private.bingo_marks where round_no<>1)
    or exists(select 1 from private.bingo_requests where round_no<>1) then raise exception 'round1 backfill invalid'; end if;
  perform set_config('request.jwt.claim.sub',person_id::text,true);
  if (public.get_bingo()->>'completed_lines')::integer<>3 or public.get_bingo()->>'completed_at' is null
    or jsonb_array_length(public.get_bingo()->'board')<>25 then raise exception 'migrated completion not readable'; end if;
end;
$$;
select 'ok - migration preserved existing questions, prize, timing, board, 15 marks, completion, flags, pending QR, audit, representatives and event settings' as result;

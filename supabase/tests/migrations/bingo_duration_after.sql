-- Run immediately after bingo_duration_before.sql and the 25-minute migration.
do $$
declare
  saved record;
  actual jsonb;
begin
  if (select count(*) from migration_verification.bingo_duration_before) is distinct from
    (select count(*) from pg_tables where schemaname in ('public', 'private', 'auth', 'storage')) then
    raise exception 'duration migration unexpectedly added or removed a data table';
  end if;
  for saved in select * from migration_verification.bingo_duration_before loop
    execute format('select jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text) from %s t', saved.name) into actual;
    if actual is distinct from saved.data then raise exception 'duration migration mutated existing data: %', saved.name; end if;
  end loop;
  select jsonb_object_agg(p.oid::text, jsonb_build_object(
    'definition', case when n.nspname = 'private' and p.proname = 'manage_bingo_round' then null else pg_get_functiondef(p.oid) end,
    'acl', p.proacl, 'security_definer', p.prosecdef, 'config', p.proconfig)) into actual
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname in ('private', 'public') and p.prokind = 'f';
  if actual is distinct from (select data from migration_verification.bingo_duration_functions_before) then
    raise exception 'duration migration changed another function or its execution permissions';
  end if;
  if not exists(select 1 from private.bingo_game where round_no = 2 and opens_at is not null
      and closes_at = opens_at + interval '30 minutes' and closed_at is null)
    or (select count(*) from private.bingo_rounds where closes_at = opens_at + interval '30 minutes') is distinct from 2
    or not exists(select 1 from private.bingo_boards where round_no = 1 and completed_at is not null
      and completed_team_name = 'Preserved duration team') then
    raise exception 'legacy current round or completed archive changed';
  end if;
end;
$$;
select 'ok - duration migration preserves every existing table row and all other function definitions/permissions, including an active 30-minute round and completed archive' as result;

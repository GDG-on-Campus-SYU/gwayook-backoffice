begin;

-- Only the eight user-approved participant entries are bootstrapped.
do $$ begin
  if (select count(*) from private.schedule_items) is distinct from 8
    or (select published from private.schedule_settings where id) is distinct from true
    or (select min(starts_at) from private.schedule_items) is distinct from '2026-11-24 18:00+09'::timestamptz
    or (select max(ends_at) from private.schedule_items) is distinct from '2026-11-24 21:40+09'::timestamptz
    or exists(select 1 from private.schedule_items where location is distinct from '서울과학기술대학교') then
    raise exception 'approved timetable bootstrap incorrect';
  end if;
  if has_table_privilege('authenticated', 'private.schedule_items', 'select,insert,update,delete')
    or has_table_privilege('authenticated', 'private.schedule_settings', 'select,insert,update,delete')
    or has_table_privilege('service_role', 'private.schedule_items', 'select,insert,update,delete')
    or has_function_privilege('anon', 'public.get_event_schedule()', 'execute')
    or has_function_privilege('service_role', 'public.set_schedule_published(boolean,integer)', 'execute')
    or not (select relrowsecurity from pg_class where oid='private.schedule_items'::regclass)
    or not (select relrowsecurity from pg_class where oid='private.schedule_settings'::regclass) then
    raise exception 'timetable permission boundary missing';
  end if;
end; $$;

insert into auth.users(id,email) select ('81000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  'timetable-'||i||'@example.test' from generate_series(1,5) i;
insert into public.members(id,name,email,auth_user_id,role,active)
select ('81000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid, 'Timetable member '||i,
  'timetable-'||i||'@example.test', ('81000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  case i when 1 then 'owner' when 2 then 'staff' else 'participant' end, i<>4 from generate_series(1,4) i;
\ir fixtures/consented-members.sql
select pg_temp.consent_fixture_members('{"team":false,"presentation":false,"bingo":false}');

create temp table timetable_preserved as select
  (select to_jsonb(e) from public.event_settings e where id) as settings,
  (select coalesce(jsonb_agg(to_jsonb(t) order by id),'[]') from public.teams t) as teams,
  (select coalesce(jsonb_agg(to_jsonb(m) order by id),'[]') from public.members m) as members,
  (select to_jsonb(g) from private.bingo_game g where id) as bingo,
  (select coalesce(jsonb_agg(to_jsonb(v) order by member_id),'[]') from private.votes v) as ballots,
  (select coalesce(jsonb_agg(to_jsonb(r) order by id),'[]') from private.vote_runoffs r) as runoffs;
update private.schedule_settings set published=false, version=1, updated_by=null where id;
delete from private.schedule_items;

set local role authenticated;
do $$
declare
  owner_auth constant text := '81000000-0000-0000-0000-000000000001';
  staff_auth constant text := '81000000-0000-0000-0000-000000000002';
  participant_auth constant text := '81000000-0000-0000-0000-000000000003';
  denied_auth text;
  statement text;
  a uuid;
  b uuid;
  untimed uuid;
  current_version integer;
  content jsonb;
begin
  foreach denied_auth in array array['',staff_auth,participant_auth,
    '81000000-0000-0000-0000-000000000004','81000000-0000-0000-0000-000000000005'] loop
    perform set_config('request.jwt.claim.sub',denied_auth,true);
    foreach statement in array array[
      'select public.get_schedule_admin()',
      'select public.save_schedule_item(null,0,''Unauthorized'',null,null,null,null)',
      'select public.delete_schedule_item(null,1)',
      'select public.set_schedule_published(true,1)',
      'select private.set_schedule_published(true,1)'
    ] loop
      begin execute statement; raise exception 'nonowner changed timetable: %',statement;
      exception when insufficient_privilege then null; end;
    end loop;
    if denied_auth not in (staff_auth,participant_auth) then
      begin perform public.get_event_schedule(); raise exception 'inactive or unlisted user read timetable';
      exception when insufficient_privilege then null; end;
    elsif public.get_event_schedule()->'items' is distinct from '[]'::jsonb then
      raise exception 'draft content visible';
    end if;
  end loop;
  perform set_config('request.jwt.claim.sub',owner_auth,true);
  begin perform public.set_schedule_published(true,1); raise exception 'empty timetable published';
  exception when invalid_parameter_value then null; end;
  begin perform public.save_schedule_item(null,0,E'\t\n',null,null,null,null); raise exception 'whitespace-only title accepted';
  exception when invalid_parameter_value then null; end;
  foreach statement in array array[
    'select public.save_schedule_item(null,0,'' '',null,null,null,null)',
    'select public.save_schedule_item(null,0,repeat(''x'',121),null,null,null,null)',
    'select public.save_schedule_item(null,0,''Bad'',repeat(''x'',2001),null,null,null)',
    'select public.save_schedule_item(null,0,''Bad'',null,repeat(''x'',201),null,null)',
    'select public.save_schedule_item(null,0,''Bad'',null,null,''infinity'',null)',
    'select public.save_schedule_item(null,0,''Bad'',null,null,null,''2026-11-24 18:30+09'')',
    'select public.save_schedule_item(null,0,''Bad'',null,null,''2026-11-24 18:30+09'',''2026-11-24 18:30+09'')',
    'select public.save_schedule_item(null,null,''Bad'',null,null,null,null)'
  ] loop
    begin execute statement; raise exception 'invalid timetable input accepted: %',statement;
    exception when invalid_parameter_value then null; end;
  end loop;
  a:=public.save_schedule_item(null,0,' First ','Participant content','Hall','2026-11-24 18:30+09','2026-11-24 18:35+09');
  untimed:=public.save_schedule_item(null,0,'Time undecided',null,null,null,null);
  b:=public.save_schedule_item(null,0,'Second',null,null,'2026-11-24 18:35+09',null);
  content:=public.get_schedule_admin();
  if jsonb_array_length(content->'items') is distinct from 3 or content->'items'->0->>'title' is distinct from 'First'
    or content->'items'->1->>'id' is distinct from b::text or content->'items'->2->>'id' is distinct from untimed::text
    or public.get_event_schedule()->'items' is distinct from '[]'::jsonb then raise exception 'draft CRUD or order incorrect'; end if;
  current_version:=(content->>'version')::integer;
  begin perform public.set_schedule_published(true,current_version-1); raise exception 'stale publication accepted';
  exception when invalid_parameter_value then null; end;
  perform public.set_schedule_published(true,current_version);
  foreach denied_auth in array array[staff_auth,participant_auth] loop
    perform set_config('request.jwt.claim.sub',denied_auth,true);
    content:=public.get_event_schedule();
    if content->>'published' is distinct from 'true' or jsonb_array_length(content->'items') is distinct from 3
      or content->'items'->0->>'description' is distinct from 'Participant content'
      or (content->'items'->0) ? 'updated_by' or (content->'items'->0) ? 'version' then
      raise exception 'published reader data incorrect or internal metadata exposed';
    end if;
  end loop;
  perform set_config('request.jwt.claim.sub',owner_auth,true);
  perform public.save_schedule_item(a,1,'First updated','Updated participant content','Hall','2026-11-24 18:30+09','2026-11-24 18:36+09');
  begin perform public.save_schedule_item(a,1,'Stale overwrite',null,null,null,null); raise exception 'stale edit accepted';
  exception when invalid_parameter_value then null; end;
  begin perform public.delete_schedule_item(a,1); raise exception 'stale delete accepted';
  exception when invalid_parameter_value then null; end;
  if public.get_event_schedule()->'items'->0->>'title' is distinct from 'First updated' then raise exception 'published edit not reflected'; end if;
  perform public.delete_schedule_item(b,1);
  perform public.delete_schedule_item(untimed,1);
  begin perform public.delete_schedule_item(a,2); raise exception 'last published entry deleted without hiding';
  exception when invalid_parameter_value then null; end;
  current_version:=(public.get_schedule_admin()->>'version')::integer;
  perform public.set_schedule_published(false,current_version);
  if public.get_event_schedule()->'items' is distinct from '[]'::jsonb
    or jsonb_array_length(public.get_schedule_admin()->'items') is distinct from 1 then raise exception 'unpublish lost draft or left content visible'; end if;
  perform public.delete_schedule_item(a,2);
  begin perform public.delete_schedule_item(a,2); raise exception 'already deleted entry accepted';
  exception when invalid_parameter_value then null; end;
  if jsonb_array_length(public.get_schedule_admin()->'items') is distinct from 0 then raise exception 'delete failed'; end if;
end;
$$;
reset role;
do $$
declare original timetable_preserved;
begin
  select * into strict original from timetable_preserved;
  if original.settings is distinct from (select to_jsonb(e) from public.event_settings e where id)
    or original.teams is distinct from (select coalesce(jsonb_agg(to_jsonb(t) order by id),'[]') from public.teams t)
    or original.members is distinct from (select coalesce(jsonb_agg(to_jsonb(m) order by id),'[]') from public.members m)
    or original.bingo is distinct from (select to_jsonb(g) from private.bingo_game g where id)
    or original.ballots is distinct from (select coalesce(jsonb_agg(to_jsonb(v) order by member_id),'[]') from private.votes v)
    or original.runoffs is distinct from (select coalesce(jsonb_agg(to_jsonb(r) order by id),'[]') from private.vote_runoffs r) then
    raise exception 'announcement changed operational settings or participant data';
  end if;
  if (select count(*) from public.audit_logs where action in ('schedule_item_saved','schedule_item_deleted','schedule_publication_changed')) is distinct from 9
    or exists(select 1 from public.audit_logs where action in ('schedule_item_saved','schedule_item_deleted','schedule_publication_changed')
      and actor_id is distinct from '81000000-0000-0000-0000-000000000001'::uuid) then
    raise exception 'timetable changes lack the correct audit actor';
  end if;
end; $$;
select '1..1' as tap;
select 'ok 1 - timetable owner CRUD, KST validation, draft privacy, approved seed, publication/version guards and unchanged operational state' as tap;
rollback;

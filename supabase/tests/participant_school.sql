begin;
update private.privacy_control set enforced=true where id;
insert into auth.users(id,email,email_confirmed_at) values
  ('b1000000-0000-0000-0000-000000000001','school-staff@example.test',now()),
  ('b1000000-0000-0000-0000-000000000002','school-person@example.test',now());
insert into public.teams(id,name) values ('b2000000-0000-0000-0000-000000000001','School fixture');
insert into public.members(id,name,email,role,auth_user_id,team_id) values
  ('b3000000-0000-0000-0000-000000000001','School staff','school-staff@example.test','staff','b1000000-0000-0000-0000-000000000001',null),
  ('b3000000-0000-0000-0000-000000000002','School person','school-person@example.test','participant','b1000000-0000-0000-0000-000000000002','b2000000-0000-0000-0000-000000000001');
update public.teams set representative_id='b3000000-0000-0000-0000-000000000002' where id='b2000000-0000-0000-0000-000000000001';
create temp table school_preserved as select
  (select to_jsonb(e) from public.event_settings e) event,
  (select jsonb_agg(to_jsonb(t) order by id) from public.teams t) teams,
  (select jsonb_agg(to_jsonb(g)) from private.bingo_game g) bingo;

set local role authenticated;
do $$
declare
  rows jsonb := '[{"name":"School person","email":"school-person@example.test","school":"서울과학기술대학교"}]';
  edit jsonb := '{"id":"b3000000-0000-0000-0000-000000000002","name":"School person","team_id":"b2000000-0000-0000-0000-000000000001","active":true}';
  r jsonb; revision text; kind text;
begin
  if has_function_privilege('anon','public.manage_roster(text,jsonb)','execute')
    or has_table_privilege('authenticated','public.members','update')
    or has_function_privilege('authenticated','private.roster_preview_without_access_log(jsonb)','execute')
    or has_function_privilege('authenticated','private.get_participant_operations_without_access_log()','execute')
    or has_function_privilege('authenticated','private.get_event_export_without_access_log(text)','execute') then
    raise exception 'school migration broadened privileges';
  end if;
  perform set_config('request.jwt.claim.sub','b1000000-0000-0000-0000-000000000002',true);
  perform public.save_my_consents('2026-11-16.1',true,'{"team":false,"presentation":false,"bingo":false}');
  begin perform public.manage_roster('update_member',edit || '{"school":"forbidden"}');
    raise exception 'participant changed roster'; exception when insufficient_privilege then null; end;
  begin perform public.get_staff_members('participants');
    raise exception 'participant read roster'; exception when insufficient_privilege then null; end;

  perform set_config('request.jwt.claim.sub','b1000000-0000-0000-0000-000000000001',true);
  perform public.save_my_consents('2026-11-16.1',true,'{}');
  perform public.manage_roster('create_member','{"name":"New school","email":"school-new@example.test","school":"  삼육대학교  "}');
  r:=public.get_staff_members('participants');
  if not exists(select 1 from jsonb_array_elements(r) p where p->>'email'='school-new@example.test' and p->>'school'='삼육대학교') then
    raise exception 'manual registration did not save normalized school';
  end if;
  perform public.manage_roster('create_member','{"name":"No school","email":"school-none@example.test"}');
  r:=public.get_staff_members('participants');
  if not exists(select 1 from jsonb_array_elements(r) p where p->>'email'='school-none@example.test' and p->>'school' is null) then
    raise exception 'optional school was required or inferred';
  end if;
  begin perform public.manage_roster('create_member',jsonb_build_object('name','Bad','email','bad@example.test','school',repeat('가',101)));
    raise exception 'long school accepted'; exception when invalid_parameter_value then null; end;
  begin perform public.manage_roster('update_member',edit || '{"school":100}');
    raise exception 'non-text school accepted'; exception when invalid_parameter_value then null; end;
  begin perform public.manage_roster('update_member',edit || jsonb_build_object('school',repeat('가',101)));
    raise exception 'long update accepted'; exception when invalid_parameter_value then null; end;

  r:=public.roster_preview(rows);
  if jsonb_array_length(r->'errors')<>0 or r#>>'{rows,0,action}'<>'update'
    or r#>>'{rows,0,school}'<>'서울과학기술대학교' or r#>>'{rows,0,before,school}' is not null then
    raise exception 'school-only preview incorrect: %',r;
  end if;
  perform public.roster_apply(rows,r->>'revision');
  -- Old clients and blank spreadsheet cells must not erase an existing school.
  perform public.manage_roster('update_member',edit);
  r:=public.roster_preview('[{"name":"School person","email":"school-person@example.test","school":"   "}]');
  if r#>>'{rows,0,school}'<>'서울과학기술대학교' or r#>>'{rows,0,action}'<>'unchanged' then
    raise exception 'blank import or old request erased school';
  end if;
  perform public.roster_apply('[{"name":"School person","email":"school-person@example.test","school":"   "}]',r->>'revision');
  r:=public.roster_preview(jsonb_build_array(jsonb_build_object('name','School person','email','school-person@example.test','school',E'\t\n\r')));
  if r#>>'{rows,0,school}'<>'서울과학기술대학교' or r#>>'{rows,0,action}'<>'unchanged' then
    raise exception 'whitespace import erased school';
  end if;
  r:=public.roster_preview('[{"name":"School person","email":"school-person@example.test"}]');
  if r#>>'{rows,0,school}'<>'서울과학기술대학교' then raise exception 'omitted school erased'; end if;
  revision:=r->>'revision';
  perform public.manage_roster('update_member',edit || '{"school":"삼육대학교"}');
  r:=public.roster_apply('[{"name":"School person","email":"school-person@example.test"}]',revision);
  if jsonb_array_length(r->'errors')=0 then raise exception 'stale school revision overwrote data'; end if;
  r:=public.roster_preview('[{"name":"School person","email":"school-person@example.test","school":false}]');
  if jsonb_array_length(r->'errors')=0 then raise exception 'invalid imported school accepted'; end if;
  r:=public.roster_preview(jsonb_build_array(jsonb_build_object('name','School person','email','school-person@example.test','school',repeat('가',101))));
  if jsonb_array_length(r->'errors')=0 then raise exception 'long imported school accepted'; end if;

  r:=public.get_participant_operations();
  if not exists(select 1 from jsonb_array_elements(r) p where p->>'email'='school-person@example.test' and p->>'school'='삼육대학교') then
    raise exception 'attendance missing school';
  end if;
  foreach kind in array array['teams','attendance'] loop
    r:=public.get_event_export(kind);
    if r->'headers'->>-1<>'학교' or not exists(select 1 from jsonb_array_elements(r->'rows') row where row->>-1='삼육대학교')
      or exists(select 1 from jsonb_array_elements(r->'rows') row where jsonb_array_length(row)<>jsonb_array_length(r->'headers')) then
      raise exception 'school export shape wrong: %',kind;
    end if;
  end loop;
  perform public.manage_roster('update_member',edit || jsonb_build_object('school',E'\t \n'));
  r:=public.get_staff_members('participants');
  if not exists(select 1 from jsonb_array_elements(r) p where p->>'email'='school-person@example.test' and p->>'school' is null) then
    raise exception 'explicit school clearing failed';
  end if;
  perform public.manage_roster('update_member',edit || '{"school":"삼육대학교"}');
  perform set_config('request.jwt.claim.sub','b1000000-0000-0000-0000-000000000002',true);
  if strpos(public.get_my_team()::text,'school')>0 then raise exception 'school exposed to team API'; end if;
end;
$$;
reset role;
do $$ begin
  if exists(select 1 from school_preserved p where p.event is distinct from (select to_jsonb(e) from public.event_settings e)
    or p.teams is distinct from (select jsonb_agg(to_jsonb(t) order by id) from public.teams t)
    or p.bingo is distinct from (select jsonb_agg(to_jsonb(g)) from private.bingo_game g)) then
    raise exception 'representative or event/bingo settings changed';
  end if;
  if not exists(select 1 from private.operator_access_logs where operation='read' and resource='roster_preview') then
    raise exception 'roster access log lost';
  end if;
end $$;
rollback;

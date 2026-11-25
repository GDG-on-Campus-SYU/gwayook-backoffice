begin;
update private.privacy_control set enforced=true where id;
insert into auth.users(id,email,email_confirmed_at) select ('a1000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,'privacy-'||i||'@example.test',now() from generate_series(1,4) i;
insert into public.teams(id,name) values('a2000000-0000-0000-0000-000000000001','Privacy one'),('a2000000-0000-0000-0000-000000000002','Privacy two');
insert into public.members(id,name,email,auth_user_id,role,team_id)
select ('a3000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,'Privacy person '||i,'privacy-'||i||'@example.test',
('a1000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,case i when 1 then 'owner' when 2 then 'staff' else 'participant' end,
case when i>2 then 'a2000000-0000-0000-0000-000000000001'::uuid end from generate_series(1,4) i;
update public.teams set representative_id='a3000000-0000-0000-0000-000000000003' where id='a2000000-0000-0000-0000-000000000001';
insert into public.submissions(team_id,current_path,file_name,size_bytes,submitted_at,submitted_by,version)
values('a2000000-0000-0000-0000-000000000001','a2000000-0000-0000-0000-000000000001/test.pdf','test.pdf',100,now(),'a3000000-0000-0000-0000-000000000003',1);
create temp table preserved as select
  (select to_jsonb(e) from public.event_settings e) event,
  (select jsonb_agg(to_jsonb(t) order by id) from public.teams t) teams,
  (select jsonb_agg(to_jsonb(g) order by id) from private.bingo_game g) bingo,
  (select jsonb_agg(to_jsonb(m) order by id) from public.members m) members,
  (select jsonb_agg(to_jsonb(s) order by team_id) from public.submissions s) submissions;
insert into public.inventory_items(id,name,source) values('a4000000-0000-0000-0000-000000000001','Privacy fixture','TEST ONLY');
insert into public.inventory_movements(id,item_id,kind,quantity,actor_id,reason) values('a5000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000001','received',2,'a3000000-0000-0000-0000-000000000002','TEST ONLY');
set local role authenticated;
do $$ declare i integer; r jsonb; kind text; before_count integer; begin
  if has_function_privilege('anon','public.save_my_consents(text,boolean,jsonb)','execute')
    or has_table_privilege('authenticated','private.consent_records','insert,update,delete,select')
    or has_table_privilege('authenticated','private.operator_access_logs','insert,update,delete,select')
    or has_function_privilege('authenticated','private.get_event_export_without_access_log(text)','execute') then raise exception 'privacy access grants leaked'; end if;
  perform set_config('request.jwt.claim.sub','a1000000-0000-0000-0000-000000000001',true);
  if (private.current_member()).id is not null then raise exception 'unconsented owner bypassed gate'; end if;
  if (select count(*) from public.members)<>1 then raise exception 'membership bootstrap exposed roster'; end if;
  begin perform public.get_staff_members('participants'); raise exception 'unconsented access'; exception when insufficient_privilege then null; end;
  begin perform public.save_my_consents('old',true,'{}'); raise exception 'old consent accepted'; exception when invalid_parameter_value then null; end;
  begin perform public.save_my_consents('2026-11-16.1',false,'{}'); raise exception 'missing terms accepted'; exception when invalid_parameter_value then null; end;
  for i in 1..4 loop
    perform set_config('request.jwt.claim.sub','a1000000-0000-0000-0000-'||lpad(i::text,12,'0'),true);
    perform public.save_my_consents('2026-11-16.1',true,'{"team":false,"presentation":false,"bingo":false}');
    perform public.save_my_consents('2026-11-16.1',true,'{"team":false,"presentation":false,"bingo":false}');
    r:=public.get_my_consents();
    if (r->>'terms')::boolean is distinct from true or (r->>'team')::boolean is distinct from false then raise exception 'wrong defaults'; end if;
    if jsonb_array_length(r->'history')<>(case when i<3 then 1 else 4 end) then raise exception 'duplicate records created'; end if;
  end loop;
  perform set_config('request.jwt.claim.sub','a1000000-0000-0000-0000-000000000003',true);
  r:=public.get_my_team();
  if strpos(r::text,'Privacy person 4')>0 then raise exception 'unconsented teammate name exposed'; end if;
  begin perform public.get_privacy_operations(); raise exception 'participant got privacy dashboard'; exception when insufficient_privilege then null; end;
  begin perform public.save_erasure_review('bad'); raise exception 'participant saved erasure review'; exception when insufficient_privilege then null; end;
  begin perform public.request_bingo_confirmation_round(1,0); raise exception 'bingo without consent'; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub','a1000000-0000-0000-0000-000000000004',true);
  if public.get_presentation_file('a2000000-0000-0000-0000-000000000001') is not null then raise exception 'unshared presentation exposed'; end if;
  begin perform public.get_staff_members('names'); raise exception 'participant got staff members'; exception when insufficient_privilege then null; end;
  begin perform public.save_my_consents('2026-11-16.1',true,'{"team":true,"presentation":false,"bingo":false,"gsa_external":true}'); raise exception 'unknown external consent accepted'; exception when invalid_parameter_value then null; end;
  perform public.save_my_consents('2026-11-16.1',true,'{"team":true,"presentation":false,"bingo":false}');
  perform set_config('request.jwt.claim.sub','a1000000-0000-0000-0000-000000000003',true);
  if strpos(public.get_my_team()::text,'Privacy person 4')=0 then raise exception 'opted in name missing'; end if;
  perform public.save_my_consents('2026-11-16.1',true,'{"team":false,"presentation":true,"bingo":true}');
  perform set_config('request.jwt.claim.sub','a1000000-0000-0000-0000-000000000004',true);
  if public.get_presentation_file('a2000000-0000-0000-0000-000000000001') is null then raise exception 'shared presentation unavailable'; end if;
  perform public.save_my_consents('2026-11-16.1',true,'{"team":false,"presentation":false,"bingo":false}');
  perform set_config('request.jwt.claim.sub','a1000000-0000-0000-0000-000000000003',true);
  if strpos(public.get_my_team()::text,'Privacy person 4')>0 then raise exception 'withdrawal not applied'; end if;
  perform public.save_my_consents('2026-11-16.1',true,'{"team":false,"presentation":false,"bingo":false}');
  perform set_config('request.jwt.claim.sub','a1000000-0000-0000-0000-000000000002',true);
  perform set_config('request.headers','{"x-gwayook-client-ip":"192.0.2.10","x-forwarded-for":"192.0.2.20"}',true);
  if (select count(*) from public.members)<>1 or (select count(*) from public.audit_logs)<>0 or (select count(*) from public.submissions)<>0 then raise exception 'direct unlogged staff read allowed'; end if;
  if jsonb_array_length(public.get_staff_members('participants'))<>2 then raise exception 'staff roster failed'; end if;
  perform public.get_participant_operations(); perform public.get_event_export('gsa'); perform public.get_presentation_list(); perform public.get_presentation_file('a2000000-0000-0000-0000-000000000001');
  if (select on_hand from public.inventory_item_balances where id='a4000000-0000-0000-0000-000000000001')<>2 then raise exception 'inventory balance inaccessible'; end if;
  if jsonb_array_length(public.get_inventory_history('a4000000-0000-0000-0000-000000000001'))<>1 then raise exception 'inventory history failed'; end if;
  begin perform reason from public.inventory_movements; raise exception 'unlogged inventory reason accessible'; exception when insufficient_privilege then null; end;
  perform public.get_bingo(); perform public.get_vote_details();
  begin perform public.get_privacy_operations(); raise exception 'staff got owner logs'; exception when insufficient_privilege then null; end;
  begin perform public.get_staff_members('staff'); raise exception 'staff got owner roster'; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub','a1000000-0000-0000-0000-000000000001',true);
  perform public.get_privacy_operations(); perform public.get_audit_entries(); perform public.get_vote_delegation(); perform public.get_gemini_bonuses();
  perform public.save_erasure_review('TEST ONLY: review without execution');
end; $$;
reset role;
do $$ begin
  if not exists(select 1 from private.operator_access_logs where actor_login='privacy-2@example.test' and operation='export' and source_ip='192.0.2.10' and cardinality(subject_ids)=2) then raise exception 'CSV audit incomplete'; end if;
  if not exists(select 1 from private.operator_access_logs where operation='download' and cardinality(subject_ids)=1) then raise exception 'PDF audit missing'; end if;
  if exists(select 1 from private.operator_access_logs where retain_until<created_at+interval '1 year') then raise exception 'short security retention'; end if;
  if not exists(select 1 from private.erasure_reviews where manifest->>'executed'='false') then raise exception 'erasure review not recorded'; end if;
  if (select event from preserved) is distinct from (select to_jsonb(e) from public.event_settings e)
    or (select teams from preserved) is distinct from (select jsonb_agg(to_jsonb(t) order by id) from public.teams t)
    or (select bingo from preserved) is distinct from (select jsonb_agg(to_jsonb(g) order by id) from private.bingo_game g)
    or (select members from preserved) is distinct from (select jsonb_agg(to_jsonb(m) order by id) from public.members m)
    or (select submissions from preserved) is distinct from (select jsonb_agg(to_jsonb(s) order by team_id) from public.submissions s) then raise exception 'protected state changed'; end if;
end; $$;
-- Exercise the live QR flow in this rollback-only fixture, including withdrawal of a pending request.
do $$ declare questions text[]; request jsonb; result jsonb; begin
  perform set_config('request.jwt.claim.sub','a1000000-0000-0000-0000-000000000001',true);
  select array_agg('Privacy test question '||i order by i) into questions from generate_series(1,25) i;
  perform public.save_bingo_config(questions,'TEST ONLY');
  perform public.manage_bingo_round('open',1);
  perform set_config('request.jwt.claim.sub','a1000000-0000-0000-0000-000000000003',true);
  perform public.save_my_consents('2026-11-16.1',true,'{"team":false,"presentation":false,"bingo":true}');
  perform public.get_bingo();
  request:=public.request_bingo_confirmation_round(1,0);
  perform public.save_my_consents('2026-11-16.1',true,'{"team":false,"presentation":false,"bingo":false}');
  perform set_config('request.jwt.claim.sub','a1000000-0000-0000-0000-000000000004',true);
  perform public.save_my_consents('2026-11-16.1',true,'{"team":false,"presentation":false,"bingo":true}');
  result:=public.confirm_bingo(request->>'token');
  if result->>'error' is null or result->>'confirmed'='true' then raise exception 'withdrawn QR request confirmed'; end if;
  perform set_config('request.jwt.claim.sub','a1000000-0000-0000-0000-000000000003',true);
  perform public.save_my_consents('2026-11-16.1',true,'{"team":false,"presentation":false,"bingo":true}');
  perform set_config('request.jwt.claim.sub','a1000000-0000-0000-0000-000000000004',true);
  if public.confirm_bingo(request->>'token')->>'confirmed' is distinct from 'true' then raise exception 'consented QR failed'; end if;
  perform public.save_my_consents('2026-11-16.1',true,'{"team":false,"presentation":false,"bingo":false}');
  perform set_config('request.jwt.claim.sub','a1000000-0000-0000-0000-000000000003',true);
  if strpos(public.get_bingo()::text,'Privacy person 4')>0 then raise exception 'withdrawn confirmer name leaked'; end if;
  perform set_config('request.jwt.claim.sub','a1000000-0000-0000-0000-000000000001',true);
end; $$;
insert into public.audit_logs(actor_id,action,target_id) values('a3000000-0000-0000-0000-000000000001','staff_activate','a3000000-0000-0000-0000-000000000002');
do $$ begin
  if not exists(select 1 from private.operator_access_logs where permission_change and retain_until>=created_at+interval '3 years') then raise exception 'permission retention missing'; end if;
end; $$;
rollback;

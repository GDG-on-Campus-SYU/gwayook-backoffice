-- Stage enforcement separately so the previous app can run during deployment.
create table private.privacy_control (id boolean primary key default true check(id), enforced boolean not null default false);
insert into private.privacy_control values(true,false);
create table private.consent_records (
  id bigint generated always as identity primary key,
  member_id uuid not null references public.members(id) on delete cascade,
  auth_user_id uuid not null,
  kind text not null check(kind in ('terms','team','presentation','bingo')),
  version text not null,
  accepted boolean not null,
  recorded_at timestamptz not null default clock_timestamp()
);
create index consent_records_latest on private.consent_records(member_id,auth_user_id,kind,version,id desc);
create table private.operator_access_logs (
  id bigint generated always as identity primary key,
  actor_id uuid,
  actor_login text not null,
  operation text not null,
  resource text not null,
  subject_ids uuid[] not null default '{}',
  source_ip text,
  gateway_ip text,
  source_kind text not null,
  created_at timestamptz not null default clock_timestamp(),
  retain_until timestamptz not null,
  permission_change boolean not null default false
);
create index operator_access_logs_time on private.operator_access_logs(created_at desc);
create table private.erasure_reviews (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid not null,
  created_at timestamptz not null default clock_timestamp(),
  manifest jsonb not null,
  note text not null check(char_length(note) between 1 and 1000)
);
alter table private.privacy_control enable row level security;
alter table private.consent_records enable row level security;
alter table private.operator_access_logs enable row level security;
alter table private.erasure_reviews enable row level security;
revoke all on private.privacy_control,private.consent_records,private.operator_access_logs,private.erasure_reviews from public,anon,authenticated,service_role;

create function private.privacy_enforced() returns boolean
language sql stable security definer set search_path='' as $$ select enforced from private.privacy_control where id; $$;
revoke all on function private.privacy_enforced() from public,anon,authenticated,service_role;
grant execute on function private.privacy_enforced() to authenticated;

create function private.has_consent(p_member uuid,p_kind text) returns boolean
language sql stable security definer set search_path='' as $$
  select coalesce((select c.accepted from private.consent_records c join public.members m on m.id=c.member_id
    where c.member_id=p_member and c.auth_user_id=m.auth_user_id and c.kind=p_kind and c.version='2026-11-16.1'
    order by c.id desc limit 1),false);
$$;

create or replace function private.current_member() returns public.members
language sql stable security definer set search_path='' as $$
  select m from public.members m where m.auth_user_id=(select auth.uid()) and m.active
    and (not (select enforced from private.privacy_control where id) or private.has_consent(m.id,'terms'));
$$;

create function private.get_my_consents() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare actor public.members;
begin
  select * into actor from public.members where auth_user_id=auth.uid() and active;
  if actor.id is null then raise exception '로그인이 필요합니다.' using errcode='42501'; end if;
  return jsonb_build_object('version','2026-11-16.1','enforced',(select enforced from private.privacy_control where id),
    'terms',private.has_consent(actor.id,'terms'),'team',private.has_consent(actor.id,'team'),
    'presentation',private.has_consent(actor.id,'presentation'),'bingo',private.has_consent(actor.id,'bingo'),
    'history',coalesce((select jsonb_agg(to_jsonb(r) order by r.id desc) from
      (select id,kind,version,accepted,recorded_at from private.consent_records where member_id=actor.id order by id desc limit 40) r),'[]'::jsonb));
end;
$$;

create function private.save_my_consents(p_version text,p_terms boolean,p_choices jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare actor public.members; v_kind text; choice boolean; previous boolean;
begin
  select * into actor from public.members where auth_user_id=auth.uid() and active for update;
  if actor.id is null then raise exception '로그인이 필요합니다.' using errcode='42501'; end if;
  if p_version is distinct from '2026-11-16.1' or p_terms is distinct from true
    or jsonb_typeof(p_choices) is distinct from 'object'
    or (p_choices - array['team','presentation','bingo']) <> '{}'::jsonb then
    raise exception '안내 버전과 동의 항목을 다시 확인해 주세요.' using errcode='22023';
  end if;
  foreach v_kind in array array['terms','team','presentation','bingo'] loop
    if v_kind <> 'terms' and actor.role <> 'participant' then continue; end if;
    if v_kind <> 'terms' and jsonb_typeof(p_choices->v_kind) is distinct from 'boolean' then
      raise exception '공유 항목별 선택이 필요합니다.' using errcode='22023';
    end if;
    choice:=case when v_kind='terms' then true else (p_choices->>v_kind)::boolean end;
    select c.accepted into previous from private.consent_records c where c.member_id=actor.id
      and c.auth_user_id=auth.uid() and c.version=p_version and c.kind=v_kind order by c.id desc limit 1;
    if previous is distinct from choice then
      insert into private.consent_records(member_id,auth_user_id,kind,version,accepted) values(actor.id,auth.uid(),v_kind,p_version,choice);
    end if;
  end loop;
end;
$$;

create function private.record_operator_access(p_operation text,p_resource text,p_subjects uuid[],p_permission boolean default false) returns void
language plpgsql security definer set search_path='' as $$
declare recorded_time timestamptz:=clock_timestamp(); actor public.members; h jsonb:=coalesce(nullif(current_setting('request.headers',true),'')::jsonb,'{}');
begin
  select * into actor from public.members where auth_user_id=auth.uid() and active;
  if actor.id is null or actor.role not in ('staff','owner') then return; end if;
  insert into private.operator_access_logs(actor_id,actor_login,operation,resource,subject_ids,source_ip,gateway_ip,source_kind,created_at,retain_until,permission_change)
    values(actor.id,actor.email,left(p_operation,100),left(p_resource,100),coalesce(p_subjects,'{}'),
      left(h->>'x-gwayook-client-ip',100),left(h->>'x-forwarded-for',200),
      case when h ? 'x-gwayook-client-ip' then 'forwarded-header' when h ? 'x-forwarded-for' then 'api-gateway' else 'database-session' end,
      recorded_time,recorded_time+case when p_permission then interval '3 years' else interval '1 year' end,p_permission);
end;
$$;

create function private.audit_personal_reads(p_resource text,p_result jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare subjects uuid[];
begin
  if (private.current_member()).role not in ('owner','staff') then return; end if;
  -- Match identifiers in the actual returned payload; never copy its names, emails or vote choices into logs.
  select array_agg(m.id order by m.id) into subjects from public.members m
    where strpos(coalesce(p_result::text,''),m.id::text)>0 or strpos(coalesce(p_result::text,''),to_jsonb(m.email)::text)>0;
  perform private.record_operator_access(case when p_resource='get_event_export' then 'export' else 'read' end,p_resource,subjects);
end;
$$;

-- Existing guarded RPCs remain the data source. Their internal implementations are no longer callable by clients.
do $migration$
declare f record; sig text; args text; params text;
begin
  for f in select p.oid,p.proname,p.proargnames from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='private' and p.proname in ('get_participant_operations','get_event_export','get_bingo_round','get_gemini_bonuses','get_vote_delegation','get_vote_details','roster_preview') loop
    sig:=pg_get_function_identity_arguments(f.oid);
    params:=pg_get_function_arguments(f.oid);
    select coalesce(string_agg(quote_ident(a),','),'') into args from unnest(f.proargnames) a;
    execute format('alter function private.%I(%s) rename to %I',f.proname,sig,f.proname||'_without_access_log');
    execute format('revoke all on function private.%I(%s) from public,anon,authenticated,service_role',f.proname||'_without_access_log',sig);
    execute format('create function private.%I(%s) returns jsonb language plpgsql volatile security definer set search_path='''' as $fn$ declare result jsonb; begin result:=private.%I(%s); perform private.audit_personal_reads(%L,result); return result; end; $fn$',f.proname,params,f.proname||'_without_access_log',args,f.proname);
    execute format('revoke all on function private.%I(%s) from public,anon,authenticated,service_role',f.proname,sig);
    execute format('grant execute on function private.%I(%s) to authenticated',f.proname,sig);
    execute format('alter function public.%I(%s) volatile',f.proname,sig);
  end loop;
end;
$migration$;
alter function private.get_bingo() volatile;
alter function public.get_bingo() volatile;

create function private.get_staff_members(p_scope text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; actor public.members:=private.current_member();
begin
  perform private.require_staff();
  if p_scope not in ('participants','staff','names','counts') or p_scope is null then raise exception 'Invalid scope' using errcode='22023'; end if;
  if p_scope='staff' and actor.role<>'owner' then raise exception '총관리자 권한이 필요합니다.' using errcode='42501'; end if;
  if p_scope='counts' then
    return jsonb_build_object('active',(select count(*) from public.members where active and role='participant'),
      'unassigned',(select count(*) from public.members where active and role='participant' and team_id is null));
  end if;
  select coalesce(jsonb_agg(case when p_scope='names' then jsonb_build_object('id',m.id,'name',m.name)
    else to_jsonb(m)-'representative_team_id' end order by m.name,m.id),'[]') into result
    from public.members m where p_scope='names' or (p_scope='participants' and m.role='participant') or (p_scope='staff' and m.role in ('staff','owner'));
  perform private.audit_personal_reads('members:'||p_scope,result);
  return result;
end;
$$;

create function private.get_audit_entries() returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
  if (private.current_member()).role is distinct from 'owner' then raise exception '총관리자 권한이 필요합니다.' using errcode='42501'; end if;
  select coalesce(jsonb_agg(to_jsonb(a) order by a.created_at desc),'[]') into result from
    (select l.id,l.action,l.created_at,jsonb_build_object('name',m.name) actor,l.actor_id
      from public.audit_logs l join public.members m on m.id=l.actor_id order by l.created_at desc limit 30) a;
  perform private.audit_personal_reads('audit_logs',result); return result;
end;
$$;

create function private.get_inventory_history(p_item_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
  perform private.require_staff();
  select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc,r.id),'[]') into result from
    (select i.id,i.kind,i.quantity,i.team_id,i.reason,i.created_at,i.actor_id,jsonb_build_object('name',m.name) actor
      from public.inventory_movements i join public.members m on m.id=i.actor_id
      where i.item_id=p_item_id order by i.created_at desc,i.id limit 20) r;
  perform private.audit_personal_reads('inventory_history',result); return result;
end;
$$;

create function private.get_presentation_list() returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor public.members:=private.current_member(); result jsonb;
begin
  if actor.id is null then raise exception '약관 동의와 로그인이 필요합니다.' using errcode='42501'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('team_id',s.team_id,'file_name',s.file_name,'size_bytes',s.size_bytes,
    'submitted_at',s.submitted_at,'submitted_by',s.submitted_by,'version',s.version)),'[]') into result
    from public.submissions s where actor.role in ('staff','owner') or actor.id=s.submitted_by or private.has_consent(s.submitted_by,'presentation');
  perform private.audit_personal_reads('submissions',result); return result;
end;
$$;

create function private.get_presentation_file(p_team_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor public.members:=private.current_member(); result jsonb; subject uuid;
begin
  if actor.id is null then raise exception '약관 동의와 로그인이 필요합니다.' using errcode='42501'; end if;
  select jsonb_build_object('current_path',s.current_path,'file_name',s.file_name),s.submitted_by into result,subject
    from public.submissions s where s.team_id=p_team_id and (actor.role in ('staff','owner') or actor.id=s.submitted_by or private.has_consent(s.submitted_by,'presentation'));
  if result is not null then perform private.record_operator_access('download','presentation-pdfs',array[subject]); end if;
  return result;
end;
$$;

-- Own membership is needed to show the consent form. Other members and audit entries use logged RPCs.
alter policy read_own_member_or_staff on public.members using (active and auth_user_id=(select auth.uid()) or
  not (select private.privacy_enforced()) and (select (private.current_member()).role) in ('staff','owner'));
alter policy read_staff_audit on public.audit_logs using (not (select private.privacy_enforced()) and (select (private.current_member()).role) in ('staff','owner'));
alter policy read_final_presentations on public.submissions using (
  (not (select private.privacy_enforced()) and (select (private.current_member()).id) is not null) or
  ((select (private.current_member()).role)='participant' and
  (submitted_by=(select (private.current_member()).id) or private.has_consent(submitted_by,'presentation')))
);
revoke all on function private.has_consent(uuid,text) from public,anon,authenticated,service_role;
grant execute on function private.has_consent(uuid,text) to authenticated;

create or replace function private.get_my_team() returns jsonb
language sql stable security definer set search_path='' as $$
  select to_jsonb(t)||jsonb_build_object('members',(
    select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'name',case when not private.privacy_enforced() or m.id=(private.current_member()).id or private.has_consent(m.id,'team') then m.name else '이름 비공개' end) order by m.name,m.id),'[]')
    from public.members m where m.team_id=t.id and m.active
  )) from public.teams t where t.id=(private.current_member()).team_id;
$$;

-- Add consent checks to the established, locked bingo flow without changing round or timing rules.
do $migration$
declare definition text; changed text;
begin
  definition:=pg_get_functiondef('private.get_bingo_round_without_access_log(integer)'::regprocedure);
  changed:=replace(definition,'  if current_round and result',E'  if private.privacy_enforced() and not private.has_consent(actor.id,''bingo'') then raise exception ''빙고 상호 확인 공유에 동의한 뒤 참여해 주세요.'' using errcode=''42501''; end if;\n  if current_round and result');
  changed:=replace(changed,'''confirmed_by'', m.name','''confirmed_by'', case when private.has_consent(m.id,''bingo'') then m.name else ''이름 비공개'' end');
  if changed=definition then raise exception 'Bingo consent patch did not match'; end if;
  execute changed;
  definition:=pg_get_functiondef('private.bingo_confirmation(text,boolean)'::regprocedure);
  changed:=replace(definition,'  if requester.id is null then',E'  if private.privacy_enforced() and (not private.has_consent(actor.id,''bingo'') or not private.has_consent(requester.id,''bingo'')) then return jsonb_build_object(''error'',''빙고 공유 동의 상태가 변경되었습니다.''); end if;\n  if requester.id is null then');
  if changed=definition then raise exception 'Bingo confirmation patch did not match'; end if;
  execute changed;
  definition:=pg_get_functiondef('private.request_bingo_confirmation_round(integer,integer)'::regprocedure);
  changed:=replace(definition,'  if actor.id is null or actor.role',E'  if private.privacy_enforced() and not private.has_consent(actor.id,''bingo'') then raise exception ''빙고 공유 동의가 필요합니다.'' using errcode=''42501''; end if;\n  if actor.id is null or actor.role');
  if changed=definition then raise exception 'Bingo request patch did not match'; end if;
  execute changed;
  definition:=pg_get_functiondef('private.require_presentation_account(uuid,uuid)'::regprocedure);
  changed:=replace(definition,'  -- Use the same lock',E'  if private.privacy_enforced() and not private.has_consent(p_member_id,''terms'') then raise exception ''약관 동의가 필요합니다.'' using errcode=''42501''; end if;\n  -- Use the same lock');
  if changed=definition then raise exception 'Presentation consent patch did not match'; end if;
  execute changed;
  definition:=pg_get_functiondef('private.bind_member()'::regprocedure);
  changed:=replace(definition,'  return to_jsonb(matched)',E'  perform private.record_operator_access(''login'',''app'',array[matched.id]);\n  return to_jsonb(matched)');
  if changed=definition then raise exception 'Login audit patch did not match'; end if;
  execute changed;
  definition:=pg_get_functiondef('private.can_upload_presentation(text)'::regprocedure);
  changed:=replace(definition,'where u.path = p_path','where u.path = p_path and (not private.privacy_enforced() or private.has_consent(m.id,''terms''))');
  if changed=definition then raise exception 'Upload policy consent patch did not match'; end if;
  execute changed;
end;
$migration$;

create function private.audit_operator_mutation() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  perform private.record_operator_access('write:'||new.action,'audit_logs',array_remove(array[new.target_id],null),
    new.action in ('staff_add','staff_activate','staff_deactivate','vote_delegate_changed'));
  return new;
end;
$$;
create trigger operator_mutation_access after insert on public.audit_logs for each row execute function private.audit_operator_mutation();

create function private.get_privacy_operations() returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; subjects uuid[];
begin
  if (private.current_member()).role is distinct from 'owner' then raise exception '총관리자 권한이 필요합니다.' using errcode='42501'; end if;
  select array_agg(distinct actor_id) into subjects from (select actor_id from private.operator_access_logs order by id desc limit 100) x;
  perform private.record_operator_access('read','operator_access_logs',subjects);
  select jsonb_build_object(
    'counts',jsonb_build_object('members',(select count(*) from public.members),'auth_accounts',(select count(*) from auth.users),
      'consents',(select count(*) from private.consent_records),'pdf_objects',(select count(*) from storage.objects where bucket_id='presentation-pdfs'),
      'gsa_records',(select count(*) from private.participant_operations),'teams',(select count(*) from public.teams),'votes',(select count(*) from private.votes),'runoff_votes',(select count(*) from private.runoff_votes),'bingo_requests',(select count(*) from private.bingo_requests),'bingo_marks',(select count(*) from private.bingo_marks),'audit_logs',(select count(*) from public.audit_logs),'inventory_movements',(select count(*) from public.inventory_movements),'bingo_boards',(select count(*) from private.bingo_boards),
      'access_logs',(select count(*) from private.operator_access_logs)),
    'erase_by',(select coalesce((event_ends_at at time zone 'Asia/Seoul')::date,event_date)+30 from public.event_settings where id),'photos_by',(select coalesce((event_ends_at at time zone 'Asia/Seoul')::date,event_date)+interval '1 year' from public.event_settings where id),
    'access_logs',coalesce((select jsonb_agg(to_jsonb(l) order by l.id desc) from (select * from private.operator_access_logs order by id desc limit 100) l),'[]'),
    'reviews',coalesce((select jsonb_agg(to_jsonb(r) order by r.created_at desc) from (select * from private.erasure_reviews order by created_at desc limit 10) r),'[]'),
    'consents',coalesce((select jsonb_agg(jsonb_build_object('id',m.id,'name',m.name,'terms',private.has_consent(m.id,'terms'),'team',private.has_consent(m.id,'team'),'presentation',private.has_consent(m.id,'presentation'),'bingo',private.has_consent(m.id,'bingo')) order by m.name) from public.members m where m.active),'[]')
  ) into result;
  perform private.audit_personal_reads('consent_status',result->'consents');
  return result;
end;
$$;

create function private.save_erasure_review(p_note text) returns uuid
language plpgsql security definer set search_path='' as $$
declare snapshot jsonb; review uuid;
begin
  snapshot:=private.get_privacy_operations();
  if char_length(btrim(p_note)) not between 1 and 1000 or p_note is null then raise exception '검토 내용을 입력해 주세요.' using errcode='22023'; end if;
  insert into private.erasure_reviews(actor_id,manifest,note) values((private.current_member()).id,
    jsonb_build_object('counts',snapshot->'counts','erase_by',snapshot->'erase_by','photos_by',snapshot->'photos_by','executed',false),btrim(p_note)) returning id into review;
  perform private.record_operator_access('review','erasure_plan','{}'); return review;
end;
$$;

do $migration$
declare f record; args text; sig text; params text;
begin
  for f in select p.oid,p.proname,p.proargnames,pg_get_function_result(p.oid) result from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='private' and p.proname in ('get_my_consents','save_my_consents','get_staff_members','get_audit_entries','get_inventory_history','get_presentation_list','get_presentation_file','get_privacy_operations','save_erasure_review') loop
    sig:=pg_get_function_identity_arguments(f.oid); params:=pg_get_function_arguments(f.oid);
    select coalesce(string_agg(quote_ident(a),','),'') into args from unnest(f.proargnames) a;
    execute format('create function public.%I(%s) returns %s language sql volatile security invoker set search_path='''' as $fn$ select private.%I(%s); $fn$',f.proname,params,f.result,f.proname,args);
    execute format('revoke all on function public.%I(%s),private.%I(%s) from public,anon,authenticated,service_role',f.proname,sig,f.proname,sig);
    execute format('grant execute on function public.%I(%s),private.%I(%s) to authenticated',f.proname,sig,f.proname,sig);
  end loop;
end;
$migration$;
revoke all on function private.record_operator_access(text,text,uuid[],boolean),private.audit_personal_reads(text,jsonb),private.audit_operator_mutation() from public,anon,authenticated,service_role;
notify pgrst, 'reload schema';

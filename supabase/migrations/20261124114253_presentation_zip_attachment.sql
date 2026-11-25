insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('presentation-zips', 'presentation-zips', false, 20971520, array['application/zip']);

-- Only a team with a submitted PDF can reserve its independent ZIP slot.
create table private.presentation_zips (
  team_id uuid primary key references public.submissions(team_id) on delete cascade,
  current_path text unique,
  file_name text,
  submitted_by uuid references public.members(id),
  version integer not null default 0,
  pending_path text unique,
  pending_name text,
  pending_size integer,
  pending_account uuid,
  pending_member uuid references public.members(id),
  expires_at timestamptz
);
alter table private.presentation_zips enable row level security;
revoke all on private.presentation_zips from public, anon, authenticated, service_role;

create function private.zip_submission_team(p_member_id uuid, p_auth_user_id uuid) returns uuid
language plpgsql set search_path = '' as $$
declare team uuid;
begin
  perform private.require_presentation_account(p_member_id, p_auth_user_id);
  team := private.presentation_representative_team(p_member_id);
  if not exists (select 1 from public.event_settings where submission_deadline > clock_timestamp()) then
    raise exception '발표자료 제출 기간을 확인해 주세요.' using errcode='22023';
  end if;
  if not exists (select 1 from public.submissions where team_id=team) then
    raise exception '먼저 발표자료 PDF를 제출해 주세요.' using errcode='22023';
  end if;
  return team;
end;
$$;

create function private.prepare_presentation_zip(p_member_id uuid, p_auth_user_id uuid, p_version integer, p_file_name text, p_size_bytes integer) returns text
language plpgsql security definer set search_path = '' as $$
declare team uuid := private.zip_submission_team(p_member_id, p_auth_user_id); path text;
begin
  if p_file_name is null or char_length(p_file_name) not between 5 and 180 or lower(right(p_file_name,4)) <> '.zip'
    or p_file_name ~ '[[:cntrl:]/]' or strpos(p_file_name,chr(92))>0 or p_size_bytes is null or p_size_bytes not between 22 and 20971520 then
    raise exception '20MB 이하 ZIP 파일을 선택해 주세요.' using errcode='22023';
  end if;
  path := team::text || '/' || gen_random_uuid()::text || '.zip';
  insert into private.presentation_zips(team_id) values(team) on conflict do nothing;
  update private.presentation_zips set pending_path=path, pending_name=p_file_name, pending_size=p_size_bytes,
    pending_member=p_member_id, pending_account=p_auth_user_id, expires_at=clock_timestamp()+interval '15 minutes'
    where team_id=team and version=p_version;
  if not found then raise exception '첨부 파일이 변경되었습니다. 화면을 새로고침해 주세요.' using errcode='22023'; end if;
  return path;
end;
$$;

create function private.can_upload_presentation_zip(p_path text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from private.presentation_zips z join public.teams t on t.id=z.team_id
    join public.members m on m.id=t.representative_id and m.representative_team_id=t.id
    cross join public.event_settings e where z.pending_path=p_path and z.pending_member=m.id
    and z.pending_account=m.auth_user_id and m.auth_user_id=auth.uid() and z.expires_at>clock_timestamp()
    and e.submission_deadline>clock_timestamp());
$$;
create policy insert_reserved_zip on storage.objects for insert to authenticated
  with check (bucket_id='presentation-zips' and private.can_upload_presentation_zip(name));
create policy read_own_reserved_zip on storage.objects for select to authenticated
  using (bucket_id='presentation-zips' and private.can_upload_presentation_zip(name));

create function private.complete_presentation_zip(p_member_id uuid, p_auth_user_id uuid, p_path text, p_verified_size integer) returns uuid
language plpgsql security definer set search_path = '' as $$
declare team uuid := private.zip_submission_team(p_member_id, p_auth_user_id); new_version integer;
begin
  update private.presentation_zips z set current_path=pending_path, file_name=pending_name, submitted_by=p_member_id,
    version=version+1, pending_path=null, pending_name=null, pending_size=null, pending_account=null, pending_member=null, expires_at=null
    where team_id=team and pending_path=p_path and pending_member=p_member_id and pending_account=p_auth_user_id
    and expires_at>clock_timestamp() and pending_size=p_verified_size and exists (
      select 1 from storage.objects where bucket_id='presentation-zips' and name=p_path
        and metadata->>'size'=p_verified_size::text and metadata->>'mimetype'='application/zip')
    returning version into new_version;
  if not found then raise exception '첨부가 만료되었거나 파일이 변경되었습니다. 다시 선택해 주세요.' using errcode='22023'; end if;
  insert into public.audit_logs(actor_id,action,target_id,details)
    values(p_member_id,'submit_presentation_zip',team,jsonb_build_object('version',new_version));
  return team;
end;
$$;

create function private.abandon_presentation_zip(p_member_id uuid, p_auth_user_id uuid, p_path text) returns uuid
language sql security definer set search_path = '' as $$
  update private.presentation_zips set pending_path=null, pending_name=null, pending_size=null, pending_member=null, pending_account=null, expires_at=null
    where pending_path=p_path and pending_member=p_member_id and pending_account=p_auth_user_id returning team_id;
$$;

create function private.unreferenced_presentation_zips(p_team_id uuid) returns text[]
language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(o.name),'{}') from storage.objects o
    where o.bucket_id='presentation-zips' and split_part(o.name,'/',1)=p_team_id::text
    and not exists(select 1 from private.presentation_zips z where z.team_id=p_team_id
      and (z.current_path=o.name or (z.pending_path=o.name and z.expires_at>clock_timestamp())));
$$;

create function private.get_presentation_zips(p_download_team uuid default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare actor public.members := private.current_member(); result jsonb; subject uuid;
begin
  if actor.id is null then raise exception '약관 동의와 로그인이 필요합니다.' using errcode='42501'; end if;
  if p_download_team is null then
    select coalesce(jsonb_agg(jsonb_build_object('team_id',s.team_id,'file_name',z.file_name,'version',coalesce(z.version,0))),'[]')
      into result from public.submissions s join public.teams t on t.id=s.team_id left join private.presentation_zips z on z.team_id=t.id
      where actor.role in ('staff','owner') or t.representative_id=actor.id;
  else
    select jsonb_build_object('current_path',z.current_path,'file_name',z.file_name),z.submitted_by into result,subject
      from private.presentation_zips z join public.teams t on t.id=z.team_id where z.team_id=p_download_team
      and z.current_path is not null and (actor.role in ('staff','owner') or t.representative_id=actor.id);
    if result is not null then perform private.record_operator_access('download','presentation-zips',array[subject]); end if;
  end if;
  return result;
end;
$$;

revoke all on function private.zip_submission_team(uuid,uuid), private.can_upload_presentation_zip(text) from public, anon, authenticated, service_role;
grant execute on function private.can_upload_presentation_zip(text) to authenticated;

create function public.prepare_presentation_zip(p_member_id uuid, p_auth_user_id uuid, p_version integer, p_file_name text, p_size_bytes integer) returns text
language sql security invoker set search_path = '' as $$
  select private.prepare_presentation_zip(p_member_id, p_auth_user_id, p_version, p_file_name, p_size_bytes);
$$;
revoke all on function public.prepare_presentation_zip(uuid, uuid, integer, text, integer), private.prepare_presentation_zip(uuid, uuid, integer, text, integer) from public, anon, authenticated, service_role;
grant execute on function public.prepare_presentation_zip(uuid, uuid, integer, text, integer), private.prepare_presentation_zip(uuid, uuid, integer, text, integer) to service_role;

create function public.complete_presentation_zip(p_member_id uuid, p_auth_user_id uuid, p_path text, p_verified_size integer) returns uuid
language sql security invoker set search_path = '' as $$
  select private.complete_presentation_zip(p_member_id, p_auth_user_id, p_path, p_verified_size);
$$;
revoke all on function public.complete_presentation_zip(uuid, uuid, text, integer), private.complete_presentation_zip(uuid, uuid, text, integer) from public, anon, authenticated, service_role;
grant execute on function public.complete_presentation_zip(uuid, uuid, text, integer), private.complete_presentation_zip(uuid, uuid, text, integer) to service_role;

create function public.abandon_presentation_zip(p_member_id uuid, p_auth_user_id uuid, p_path text) returns uuid
language sql security invoker set search_path = '' as $$
  select private.abandon_presentation_zip(p_member_id, p_auth_user_id, p_path);
$$;
revoke all on function public.abandon_presentation_zip(uuid, uuid, text), private.abandon_presentation_zip(uuid, uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.abandon_presentation_zip(uuid, uuid, text), private.abandon_presentation_zip(uuid, uuid, text) to service_role;

create function public.unreferenced_presentation_zips(p_team_id uuid) returns text[]
language sql security invoker set search_path = '' as $$
  select private.unreferenced_presentation_zips(p_team_id);
$$;
revoke all on function public.unreferenced_presentation_zips(uuid), private.unreferenced_presentation_zips(uuid) from public, anon, authenticated, service_role;
grant execute on function public.unreferenced_presentation_zips(uuid), private.unreferenced_presentation_zips(uuid) to service_role;

create function public.get_presentation_zips(p_download_team uuid default null) returns jsonb
language sql security invoker set search_path = '' as $$
  select private.get_presentation_zips(p_download_team);
$$;
revoke all on function public.get_presentation_zips(uuid), private.get_presentation_zips(uuid) from public, anon, authenticated, service_role;
grant execute on function public.get_presentation_zips(uuid), private.get_presentation_zips(uuid) to authenticated;

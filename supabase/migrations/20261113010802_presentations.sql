insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('presentation-pdfs', 'presentation-pdfs', false, 5242880, array['application/pdf']);

create table public.submissions (
  team_id uuid primary key references public.teams (id),
  current_path text not null unique,
  previous_path text unique,
  file_name text not null,
  size_bytes integer not null check (size_bytes between 1 and 5242880),
  submitted_at timestamptz not null,
  submitted_by uuid not null references public.members (id),
  version integer not null check (version > 0)
);
alter table public.submissions enable row level security;
revoke all on public.submissions from public, anon, authenticated;
grant select on public.submissions to authenticated;
create policy read_final_presentations on public.submissions for select to authenticated
  using ((select (private.current_member()).id) is not null);

create table private.presentation_uploads (
  team_id uuid primary key references public.teams (id),
  member_id uuid references public.members (id),
  path text unique,
  file_name text,
  size_bytes integer,
  version integer,
  expires_at timestamptz
);
alter table private.presentation_uploads enable row level security;
revoke all on private.presentation_uploads from public, anon, authenticated;

create function private.can_upload_presentation(p_path text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from private.presentation_uploads u
    join public.teams t on t.id = u.team_id and t.representative_id = u.member_id
    join public.members m on m.id = u.member_id and m.representative_team_id = t.id
    cross join public.event_settings e
    where u.path = p_path and m.auth_user_id = (select auth.uid())
      and u.expires_at > clock_timestamp() and e.submission_deadline > clock_timestamp()
  );
$$;
revoke all on function private.can_upload_presentation(text) from public, anon, authenticated;
grant execute on function private.can_upload_presentation(text) to authenticated;

create policy upload_reserved_presentation on storage.objects for insert to authenticated
  with check (bucket_id = 'presentation-pdfs' and private.can_upload_presentation(name));

create policy read_final_presentation_files on storage.objects for select to authenticated
  using (bucket_id = 'presentation-pdfs'
    and exists (select 1 from public.submissions s where s.current_path = storage.objects.name));

create policy read_own_reserved_presentation on storage.objects for select to authenticated
  using (bucket_id = 'presentation-pdfs' and private.can_upload_presentation(name));

create function private.presentation_representative_team(p_member_id uuid) returns uuid
language plpgsql stable set search_path = '' as $$
declare
  team uuid;
begin
  select m.team_id into team from public.members m
  join public.teams t on t.id = m.representative_team_id and t.representative_id = m.id
  where m.id = p_member_id and m.auth_user_id is not null;
  if team is null then raise exception '현재 팀의 대표자만 제출할 수 있습니다.' using errcode = '42501'; end if;
  return team;
end;
$$;

create function private.prepare_presentation(p_member_id uuid, p_version integer, p_file_name text, p_size_bytes integer) returns text
language plpgsql security definer set search_path = '' as $$
declare
  deadline timestamptz;
  team uuid;
  current_version integer;
  upload_path text;
begin
  select submission_deadline into deadline from public.event_settings where id for update;
  team := private.presentation_representative_team(p_member_id);
  if deadline is null or deadline <= clock_timestamp() then
    raise exception '발표자료 제출 기간을 확인해 주세요.' using errcode = '22023';
  end if;

  select version into current_version from public.submissions where team_id = team;
  if p_version is distinct from coalesce(current_version, 0) then
    raise exception '제출본이 변경되었습니다. 화면을 새로고침해 주세요.' using errcode = '22023';
  end if;
  if p_size_bytes is null or p_size_bytes not between 1 and 5242880 or p_file_name is null
    or char_length(p_file_name) not between 5 and 180 or lower(right(p_file_name, 4)) <> '.pdf'
    or p_file_name ~ '[[:cntrl:]/]' or strpos(p_file_name, chr(92)) > 0 then
    raise exception '5MB 이하 PDF의 파일명을 확인해 주세요.' using errcode = '22023';
  end if;

  upload_path := team::text || '/' || gen_random_uuid()::text || '.pdf';
  insert into private.presentation_uploads (team_id, member_id, path, file_name, size_bytes, version, expires_at)
  values (team, p_member_id, upload_path, p_file_name, p_size_bytes, p_version, clock_timestamp() + interval '15 minutes')
  on conflict (team_id) do update set
    member_id = excluded.member_id, path = excluded.path, file_name = excluded.file_name,
    size_bytes = excluded.size_bytes, version = excluded.version, expires_at = excluded.expires_at;
  return upload_path;
end;
$$;

create function private.complete_presentation(p_member_id uuid, p_path text, p_verified_size integer) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  deadline timestamptz;
  team uuid;
  upload private.presentation_uploads;
  current_version integer;
  stored_metadata jsonb;
begin
  select submission_deadline into deadline from public.event_settings where id for update;
  team := private.presentation_representative_team(p_member_id);
  if deadline is null or deadline <= clock_timestamp() then
    raise exception '발표자료 제출 기간을 확인해 주세요.' using errcode = '22023';
  end if;

  select * into upload from private.presentation_uploads where team_id = team;
  select version into current_version from public.submissions where team_id = team;
  if upload.path is null or upload.path is distinct from p_path or upload.member_id is distinct from p_member_id
    or upload.expires_at <= clock_timestamp() or upload.version is distinct from coalesce(current_version, 0) then
    raise exception '업로드가 만료되었거나 제출본이 변경되었습니다. 화면을 새로고침해 주세요.' using errcode = '22023';
  end if;

  select metadata into stored_metadata from storage.objects where bucket_id = 'presentation-pdfs' and name = p_path;
  if upload.size_bytes is distinct from p_verified_size
    or stored_metadata->>'size' is distinct from upload.size_bytes::text
    or stored_metadata->>'mimetype' is distinct from 'application/pdf' then
    raise exception '저장된 PDF를 확인할 수 없습니다. 다시 업로드해 주세요.' using errcode = '22023';
  end if;

  insert into public.submissions (team_id, current_path, file_name, size_bytes, submitted_at, submitted_by, version)
  values (team, p_path, upload.file_name, upload.size_bytes, clock_timestamp(), p_member_id, 1)
  on conflict (team_id) do update set
    current_path = excluded.current_path, previous_path = submissions.current_path, file_name = excluded.file_name,
    size_bytes = excluded.size_bytes, submitted_at = excluded.submitted_at,
    submitted_by = excluded.submitted_by, version = submissions.version + 1;
  delete from private.presentation_uploads where team_id = team;
  insert into public.audit_logs (actor_id, action, target_id, details)
  values (p_member_id, 'submit_presentation', team, jsonb_build_object('version', upload.version + 1));
  return team;
end;
$$;

create function private.abandon_presentation(p_member_id uuid, p_path text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  team uuid;
begin
  perform id from public.event_settings where id for update;
  delete from private.presentation_uploads where member_id = p_member_id and path = p_path returning team_id into team;
  return team;
end;
$$;

create function private.unreferenced_presentation_files(p_team_id uuid) returns text[]
language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(o.name), '{}') from storage.objects o
  where o.bucket_id = 'presentation-pdfs' and split_part(o.name, '/', 1) = p_team_id::text
    and not exists (select 1 from public.submissions s where s.team_id = p_team_id and o.name in (s.current_path, s.previous_path))
    and not exists (select 1 from private.presentation_uploads u where u.team_id = p_team_id and u.path = o.name);
$$;

create function public.prepare_presentation(p_member_id uuid, p_version integer, p_file_name text, p_size_bytes integer) returns text
language sql security invoker set search_path = '' as $$
  select private.prepare_presentation(p_member_id, p_version, p_file_name, p_size_bytes);
$$;

create function public.complete_presentation(p_member_id uuid, p_path text, p_verified_size integer) returns uuid
language sql security invoker set search_path = '' as $$
  select private.complete_presentation(p_member_id, p_path, p_verified_size);
$$;

create function public.abandon_presentation(p_member_id uuid, p_path text) returns uuid
language sql security invoker set search_path = '' as $$
  select private.abandon_presentation(p_member_id, p_path);
$$;

create function public.unreferenced_presentation_files(p_team_id uuid) returns text[]
language sql stable security invoker set search_path = '' as $$
  select private.unreferenced_presentation_files(p_team_id);
$$;

revoke all on function
  public.prepare_presentation(uuid, integer, text, integer), private.prepare_presentation(uuid, integer, text, integer),
  public.complete_presentation(uuid, text, integer), private.complete_presentation(uuid, text, integer),
  public.abandon_presentation(uuid, text), private.abandon_presentation(uuid, text),
  public.unreferenced_presentation_files(uuid), private.unreferenced_presentation_files(uuid)
from public, anon, authenticated;
grant usage on schema private to service_role;
grant execute on function
  public.prepare_presentation(uuid, integer, text, integer), private.prepare_presentation(uuid, integer, text, integer),
  public.complete_presentation(uuid, text, integer), private.complete_presentation(uuid, text, integer),
  public.abandon_presentation(uuid, text), private.abandon_presentation(uuid, text),
  public.unreferenced_presentation_files(uuid), private.unreferenced_presentation_files(uuid)
to service_role;

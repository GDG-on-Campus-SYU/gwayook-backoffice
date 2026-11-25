alter table private.presentation_uploads add column auth_user_id uuid;

create or replace function private.can_upload_presentation(p_path text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from private.presentation_uploads u
    join public.teams t on t.id = u.team_id and t.representative_id = u.member_id
    join public.members m on m.id = u.member_id and m.representative_team_id = t.id
    cross join public.event_settings e
    where u.path = p_path and u.auth_user_id = (select auth.uid()) and m.auth_user_id = u.auth_user_id
      and u.expires_at > clock_timestamp() and e.submission_deadline > clock_timestamp()
  );
$$;

create function private.require_presentation_account(p_member_id uuid, p_auth_user_id uuid) returns void
language plpgsql set search_path = '' as $$
begin
  -- Use the same lock order as participant email correction.
  perform id from public.event_settings where id for update;
  perform id from public.members where id = p_member_id and auth_user_id = p_auth_user_id and active for no key update;
  if not found then
    raise exception '연결된 로그인 계정이 변경되었습니다. 다시 로그인해 주세요.' using errcode = '42501';
  end if;
end;
$$;

create function private.prepare_presentation(p_member_id uuid, p_auth_user_id uuid, p_version integer, p_file_name text, p_size_bytes integer) returns text
language plpgsql security definer set search_path = '' as $$
declare
  upload_path text;
begin
  perform private.require_presentation_account(p_member_id, p_auth_user_id);
  upload_path := private.prepare_presentation(p_member_id, p_version, p_file_name, p_size_bytes);
  update private.presentation_uploads set auth_user_id = p_auth_user_id where path = upload_path;
  return upload_path;
end;
$$;

create function private.complete_presentation(p_member_id uuid, p_auth_user_id uuid, p_path text, p_verified_size integer) returns uuid
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_presentation_account(p_member_id, p_auth_user_id);
  if not exists (select 1 from private.presentation_uploads
    where path = p_path and member_id = p_member_id and auth_user_id = p_auth_user_id) then
    raise exception '업로드가 만료되었거나 제출본이 변경되었습니다. 화면을 새로고침해 주세요.' using errcode = '22023';
  end if;
  return private.complete_presentation(p_member_id, p_path, p_verified_size);
end;
$$;

create function private.abandon_presentation(p_member_id uuid, p_auth_user_id uuid, p_path text) returns uuid
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_presentation_account(p_member_id, p_auth_user_id);
  if not exists (select 1 from private.presentation_uploads
    where path = p_path and member_id = p_member_id and auth_user_id = p_auth_user_id) then
    return null;
  end if;
  return private.abandon_presentation(p_member_id, p_path);
end;
$$;

drop function public.prepare_presentation(uuid, integer, text, integer);
drop function public.complete_presentation(uuid, text, integer);
drop function public.abandon_presentation(uuid, text);
revoke all on function private.prepare_presentation(uuid, integer, text, integer),
  private.complete_presentation(uuid, text, integer), private.abandon_presentation(uuid, text)
from public, anon, authenticated, service_role;

create function public.prepare_presentation(p_member_id uuid, p_auth_user_id uuid, p_version integer, p_file_name text, p_size_bytes integer) returns text
language sql security invoker set search_path = '' as $$
  select private.prepare_presentation(p_member_id, p_auth_user_id, p_version, p_file_name, p_size_bytes);
$$;
create function public.complete_presentation(p_member_id uuid, p_auth_user_id uuid, p_path text, p_verified_size integer) returns uuid
language sql security invoker set search_path = '' as $$
  select private.complete_presentation(p_member_id, p_auth_user_id, p_path, p_verified_size);
$$;
create function public.abandon_presentation(p_member_id uuid, p_auth_user_id uuid, p_path text) returns uuid
language sql security invoker set search_path = '' as $$
  select private.abandon_presentation(p_member_id, p_auth_user_id, p_path);
$$;

revoke all on function private.require_presentation_account(uuid, uuid),
  private.prepare_presentation(uuid, uuid, integer, text, integer), public.prepare_presentation(uuid, uuid, integer, text, integer),
  private.complete_presentation(uuid, uuid, text, integer), public.complete_presentation(uuid, uuid, text, integer),
  private.abandon_presentation(uuid, uuid, text), public.abandon_presentation(uuid, uuid, text)
from public, anon, authenticated, service_role;
grant execute on function
  private.prepare_presentation(uuid, uuid, integer, text, integer), public.prepare_presentation(uuid, uuid, integer, text, integer),
  private.complete_presentation(uuid, uuid, text, integer), public.complete_presentation(uuid, uuid, text, integer),
  private.abandon_presentation(uuid, uuid, text), public.abandon_presentation(uuid, uuid, text)
to service_role;

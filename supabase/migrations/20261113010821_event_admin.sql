create function private.require_owner() returns uuid
language plpgsql stable set search_path = '' as $$
declare
  actor public.members := private.current_member();
begin
  if actor.id is null or actor.role <> 'owner' then
    raise exception '총관리자 권한이 필요합니다.' using errcode = '42501';
  end if;
  return actor.id;
end;
$$;
revoke all on function private.require_owner() from public, anon, authenticated;

create function private.save_event_settings(p_settings jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid;
  current_settings public.event_settings;
  field text;
begin
  perform private.require_owner();
  select * into strict current_settings from public.event_settings where id for update;
  actor := private.require_owner();
  if jsonb_typeof(p_settings) is distinct from 'object' then
    raise exception '행사 설정을 확인해 주세요.' using errcode = '22023';
  end if;
  for field in select jsonb_object_keys(p_settings) loop
    if field not in ('notice', 'contact', 'event_starts_at', 'event_ends_at', 'submission_deadline', 'vote_closes_at')
      or jsonb_typeof(p_settings->field) not in ('null','string') then
      raise exception '행사 설정을 확인해 주세요.' using errcode = '22023';
    end if;
  end loop;
  if length(p_settings->>'notice') > 2500 or length(p_settings->>'contact') > 160 then
    raise exception '공지 또는 문의처가 너무 깁니다.' using errcode = '22023';
  end if;
  if current_settings.vote_status <> 'draft' and p_settings ? 'vote_closes_at' then
    raise exception '시작한 투표의 마감은 변경할 수 없습니다.' using errcode = '22023';
  end if;
  update public.event_settings as e set
    notice = case when p_settings ? 'notice' then nullif(btrim(p_settings->>'notice'), '') else e.notice end,
    contact = case when p_settings ? 'contact' then nullif(btrim(p_settings->>'contact'), '') else e.contact end,
    event_starts_at = case when p_settings ? 'event_starts_at' then (p_settings->>'event_starts_at')::timestamptz else e.event_starts_at end,
    event_ends_at = case when p_settings ? 'event_ends_at' then (p_settings->>'event_ends_at')::timestamptz else e.event_ends_at end,
    submission_deadline = case when p_settings ? 'submission_deadline' then (p_settings->>'submission_deadline')::timestamptz else e.submission_deadline end,
    vote_closes_at = case when p_settings ? 'vote_closes_at' then (p_settings->>'vote_closes_at')::timestamptz else e.vote_closes_at end
  where e.id;
  insert into public.audit_logs(actor_id, action) values (actor, 'event_settings');
exception when invalid_datetime_format or datetime_field_overflow or check_violation then
  raise exception '시각을 확인해 주세요. 행사 종료는 시작 이후여야 합니다.' using errcode = '22023';
end;
$$;

create function private.save_event_staff(p_id uuid, p_name text, p_email text, p_active boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid;
  target_id uuid;
begin
  perform private.require_owner();
  perform id from public.event_settings where id for update;
  actor := private.require_owner();
  if p_id is null then
    insert into public.members(name, email, role) values (btrim(p_name), lower(btrim(p_email)), 'staff') returning id into target_id;
  else
    if p_active is null then raise exception '운영진 상태를 확인해 주세요.' using errcode = '22023'; end if;
    update public.members set active = p_active where id = p_id and role = 'staff' returning id into target_id;
    if not found then raise exception '운영진 계정을 찾을 수 없습니다.' using errcode = '22023'; end if;
  end if;
  insert into public.audit_logs(actor_id, action, target_id)
  values (actor, case when p_id is null then 'staff_add' when p_active then 'staff_activate' else 'staff_deactivate' end, target_id);
exception
  when unique_violation then raise exception '이미 등록된 이메일입니다.' using errcode = '22023';
  when check_violation or not_null_violation then raise exception '이름과 Google 이메일을 확인해 주세요.' using errcode = '22023';
end;
$$;

create function public.save_event_settings(p_settings jsonb) returns void
language sql security invoker set search_path = '' as $$ select private.save_event_settings(p_settings) $$;
create function public.save_event_staff(p_id uuid, p_name text, p_email text, p_active boolean) returns void
language sql security invoker set search_path = '' as $$ select private.save_event_staff(p_id, p_name, p_email, p_active) $$;
revoke all on function public.save_event_settings(jsonb), public.save_event_staff(uuid, text, text, boolean),
  private.save_event_settings(jsonb), private.save_event_staff(uuid, text, text, boolean) from public, anon, authenticated;
grant execute on function public.save_event_settings(jsonb), public.save_event_staff(uuid, text, text, boolean),
  private.save_event_settings(jsonb), private.save_event_staff(uuid, text, text, boolean) to authenticated;

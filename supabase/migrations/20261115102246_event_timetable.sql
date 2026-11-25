-- The participant timetable is an announcement. These tables never control
-- event_settings, submission/voting deadlines, or the QR bingo clock.
create table private.schedule_settings (
  id boolean primary key default true check (id),
  published boolean not null default false,
  version integer not null default 1 check (version > 0),
  updated_at timestamptz not null default clock_timestamp(),
  updated_by uuid references public.members(id)
);
insert into private.schedule_settings(id) values (true);
create table private.schedule_items (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(btrim(title)) between 1 and 120 and title ~ '[^[:space:]]'),
  description text check (char_length(description) <= 2000),
  location text check (char_length(location) <= 200),
  starts_at timestamptz check (isfinite(starts_at)),
  ends_at timestamptz check (isfinite(ends_at)),
  version integer not null default 1 check (version > 0),
  updated_at timestamptz not null default clock_timestamp(),
  updated_by uuid references public.members(id),
  check (ends_at is null or (starts_at is not null and ends_at > starts_at))
);
alter table private.schedule_settings enable row level security;
alter table private.schedule_items enable row level security;
revoke all on private.schedule_settings, private.schedule_items from public, anon, authenticated, service_role;

create function private.get_event_schedule() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if (private.current_member()).id is null then
    raise exception '행사 명단에 등록된 계정이 필요합니다.' using errcode = '42501';
  end if;
  return (select jsonb_build_object('published', s.published, 'updated_at', s.updated_at,
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'title', i.title,
      'description', i.description, 'location', i.location, 'starts_at', i.starts_at, 'ends_at', i.ends_at)
      order by i.starts_at nulls last, i.ends_at nulls last, i.title, i.id)
      from private.schedule_items i where s.published), '[]'::jsonb))
    from private.schedule_settings s where s.id);
end;
$$;

create function private.get_schedule_admin() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_owner();
  return (select jsonb_build_object('published', s.published, 'version', s.version, 'updated_at', s.updated_at,
    'items', coalesce((select jsonb_agg(to_jsonb(i) order by i.starts_at nulls last, i.ends_at nulls last, i.title, i.id)
      from private.schedule_items i), '[]'::jsonb)) from private.schedule_settings s where s.id);
end;
$$;

create function private.save_schedule_item(p_id uuid, p_version integer, p_title text,
  p_description text, p_location text, p_starts_at timestamptz, p_ends_at timestamptz) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid;
  previous private.schedule_items;
  saved private.schedule_items;
begin
  perform private.require_owner();
  perform id from private.schedule_settings where id for update;
  actor := private.require_owner();
  p_title := btrim(p_title);
  p_description := nullif(btrim(p_description), '');
  p_location := nullif(btrim(p_location), '');
  if p_title is null or char_length(p_title) not between 1 and 120 or p_title !~ '[^[:space:]]'
    or char_length(p_description) > 2000 or char_length(p_location) > 200 then
    raise exception '제목은 1~120자, 내용은 2000자, 장소는 200자 이내로 입력해 주세요.' using errcode = '22023';
  end if;
  if (p_starts_at is not null and not isfinite(p_starts_at)) or (p_ends_at is not null and not isfinite(p_ends_at))
    or (p_ends_at is not null and (p_starts_at is null or p_ends_at <= p_starts_at)) then
    raise exception '종료 시각은 시작 시각 이후여야 합니다. 미정 시각은 비워 주세요.' using errcode = '22023';
  end if;
  if p_id is null then
    if p_version is distinct from 0 then raise exception '새 일정을 다시 입력해 주세요.' using errcode = '22023'; end if;
    if (select count(*) from private.schedule_items) >= 200 then
      raise exception '일정은 최대 200개까지 등록할 수 있습니다.' using errcode = '22023';
    end if;
    insert into private.schedule_items(title, description, location, starts_at, ends_at, updated_by)
      values(p_title, p_description, p_location, p_starts_at, p_ends_at, actor) returning * into saved;
  else
    select * into previous from private.schedule_items where id = p_id for update;
    if previous.id is null or previous.version is distinct from p_version then
      raise exception '다른 화면에서 일정이 변경되거나 삭제되었습니다. 새로고침 후 다시 확인해 주세요.' using errcode = '22023';
    end if;
    update private.schedule_items set title = p_title, description = p_description, location = p_location,
      starts_at = p_starts_at, ends_at = p_ends_at, version = version + 1,
      updated_at = clock_timestamp(), updated_by = actor where id = p_id returning * into saved;
  end if;
  update private.schedule_settings set version = version + 1, updated_at = clock_timestamp(), updated_by = actor where id;
  insert into public.audit_logs(actor_id, action, target_id, details) values(actor, 'schedule_item_saved', saved.id,
    jsonb_build_object('before', case when previous.id is not null then to_jsonb(previous) end, 'after', to_jsonb(saved)));
  return saved.id;
end;
$$;

create function private.delete_schedule_item(p_id uuid, p_version integer) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid;
  settings private.schedule_settings;
  previous private.schedule_items;
begin
  perform private.require_owner();
  select * into strict settings from private.schedule_settings where id for update;
  actor := private.require_owner();
  select * into previous from private.schedule_items where id = p_id for update;
  if previous.id is null or previous.version is distinct from p_version then
    raise exception '다른 화면에서 일정이 변경되거나 삭제되었습니다. 새로고침 후 다시 확인해 주세요.' using errcode = '22023';
  end if;
  if settings.published and (select count(*) from private.schedule_items) = 1 then
    raise exception '마지막 일정을 삭제하려면 타임테이블을 먼저 비공개로 바꿔 주세요.' using errcode = '22023';
  end if;
  delete from private.schedule_items where id = p_id;
  update private.schedule_settings set version = version + 1, updated_at = clock_timestamp(), updated_by = actor where id;
  insert into public.audit_logs(actor_id, action, target_id, details) values(actor, 'schedule_item_deleted', p_id, to_jsonb(previous));
end;
$$;

create function private.set_schedule_published(p_published boolean, p_version integer) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid;
  settings private.schedule_settings;
begin
  perform private.require_owner();
  select * into strict settings from private.schedule_settings where id for update;
  actor := private.require_owner();
  if p_published is null or settings.version is distinct from p_version then
    raise exception '일정이 변경되었습니다. 새로고침 후 공개할 내용을 다시 확인해 주세요.' using errcode = '22023';
  end if;
  if p_published and not exists(select 1 from private.schedule_items) then
    raise exception '일정을 한 개 이상 등록한 뒤 공개해 주세요.' using errcode = '22023';
  end if;
  if settings.published = p_published then return; end if;
  update private.schedule_settings set published = p_published, version = version + 1,
    updated_at = clock_timestamp(), updated_by = actor where id;
  insert into public.audit_logs(actor_id, action, details) values(actor, 'schedule_publication_changed',
    jsonb_build_object('published', p_published, 'item_count', (select count(*) from private.schedule_items)));
end;
$$;

create function public.get_event_schedule() returns jsonb
language sql stable security invoker set search_path = '' as $$ select private.get_event_schedule(); $$;
create function public.get_schedule_admin() returns jsonb
language sql stable security invoker set search_path = '' as $$ select private.get_schedule_admin(); $$;
create function public.save_schedule_item(p_id uuid, p_version integer, p_title text, p_description text,
  p_location text, p_starts_at timestamptz, p_ends_at timestamptz) returns uuid
language sql security invoker set search_path = '' as $$
  select private.save_schedule_item(p_id, p_version, p_title, p_description, p_location, p_starts_at, p_ends_at); $$;
create function public.delete_schedule_item(p_id uuid, p_version integer) returns void
language sql security invoker set search_path = '' as $$ select private.delete_schedule_item(p_id, p_version); $$;
create function public.set_schedule_published(p_published boolean, p_version integer) returns void
language sql security invoker set search_path = '' as $$ select private.set_schedule_published(p_published, p_version); $$;

revoke all on function private.get_event_schedule(), private.get_schedule_admin(),
  private.save_schedule_item(uuid, integer, text, text, text, timestamptz, timestamptz), private.delete_schedule_item(uuid, integer),
  private.set_schedule_published(boolean, integer), public.get_event_schedule(), public.get_schedule_admin(),
  public.save_schedule_item(uuid, integer, text, text, text, timestamptz, timestamptz), public.delete_schedule_item(uuid, integer),
  public.set_schedule_published(boolean, integer) from public, anon, authenticated, service_role;
grant execute on function private.get_event_schedule(), private.get_schedule_admin(),
  private.save_schedule_item(uuid, integer, text, text, text, timestamptz, timestamptz), private.delete_schedule_item(uuid, integer),
  private.set_schedule_published(boolean, integer), public.get_event_schedule(), public.get_schedule_admin(),
  public.save_schedule_item(uuid, integer, text, text, text, timestamptz, timestamptz), public.delete_schedule_item(uuid, integer),
  public.set_schedule_published(boolean, integer) to authenticated;

-- The user approved these eight participant-facing entries and publication on
-- 2026-11-15. No internal staffing, contact details, or old Drive draft is copied.
insert into private.schedule_items(title, description, location, starts_at, ends_at) values
  ('참가자 입장', '자리 확인 및 착석', '서울과학기술대학교', '2026-11-24 18:00+09', '2026-11-24 18:30+09'),
  ('오프닝', '행사 및 챕터 소개', '서울과학기술대학교', '2026-11-24 18:30+09', '2026-11-24 18:35+09'),
  ('아이스브레이킹', '팀별 교류 활동', '서울과학기술대학교', '2026-11-24 18:35+09', '2026-11-24 19:00+09'),
  ('주제 공개·룰 안내', '주제 및 심사 방식', '서울과학기술대학교', '2026-11-24 19:00+09', '2026-11-24 19:10+09'),
  ('아이디어톤 스프린트', '아이디어 기획·자료 제작', '서울과학기술대학교', '2026-11-24 19:10+09', '2026-11-24 20:30+09'),
  ('팀별 발표', '팀당 약 3분', '서울과학기술대학교', '2026-11-24 20:30+09', '2026-11-24 21:00+09'),
  ('네트워킹 및 심사', '아이디어 투표·평가', '서울과학기술대학교', '2026-11-24 21:00+09', '2026-11-24 21:20+09'),
  ('시상식', '수상·단체사진', '서울과학기술대학교', '2026-11-24 21:20+09', '2026-11-24 21:40+09');
update private.schedule_settings set published = true where id;

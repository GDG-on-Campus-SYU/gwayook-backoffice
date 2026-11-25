create or replace function private.save_event_settings(p_settings jsonb) returns void
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
    if field not in ('name', 'event_date', 'notice', 'contact', 'event_starts_at', 'event_ends_at', 'submission_deadline', 'vote_closes_at')
      or jsonb_typeof(p_settings->field) not in ('null', 'string') then
      raise exception '행사 설정을 확인해 주세요.' using errcode = '22023';
    end if;
  end loop;
  if p_settings ? 'name' and length(coalesce(btrim(p_settings->>'name'), '')) not between 1 and 100 then
    raise exception '행사명은 1자 이상 100자 이하로 입력해 주세요.' using errcode = '22023';
  end if;
  if p_settings ? 'event_date' and coalesce(p_settings->>'event_date', '') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    raise exception '행사 날짜를 확인해 주세요.' using errcode = '22023';
  end if;
  if length(p_settings->>'notice') > 2500 or length(p_settings->>'contact') > 160 then
    raise exception '공지 또는 문의처가 너무 깁니다.' using errcode = '22023';
  end if;
  if current_settings.vote_status <> 'draft' and p_settings ? 'vote_closes_at' then
    raise exception '시작한 투표의 마감은 변경할 수 없습니다.' using errcode = '22023';
  end if;
  foreach field in array array['event_starts_at', 'event_ends_at', 'submission_deadline', 'vote_closes_at'] loop
    if not isfinite((p_settings->>field)::timestamptz) then
      raise exception '시각을 확인해 주세요.' using errcode = '22023';
    end if;
  end loop;

  update public.event_settings as e set
    name = case when p_settings ? 'name' then btrim(p_settings->>'name') else e.name end,
    event_date = case when p_settings ? 'event_date' then (p_settings->>'event_date')::date else e.event_date end,
    notice = case when p_settings ? 'notice' then nullif(btrim(p_settings->>'notice'), '') else e.notice end,
    contact = case when p_settings ? 'contact' then nullif(btrim(p_settings->>'contact'), '') else e.contact end,
    event_starts_at = case when p_settings ? 'event_starts_at' then (p_settings->>'event_starts_at')::timestamptz else e.event_starts_at end,
    event_ends_at = case when p_settings ? 'event_ends_at' then (p_settings->>'event_ends_at')::timestamptz else e.event_ends_at end,
    submission_deadline = case when p_settings ? 'submission_deadline' then (p_settings->>'submission_deadline')::timestamptz else e.submission_deadline end,
    vote_closes_at = case when p_settings ? 'vote_closes_at' then (p_settings->>'vote_closes_at')::timestamptz else e.vote_closes_at end
  where e.id;
  insert into public.audit_logs(actor_id, action) values (actor, 'event_settings');
exception when invalid_datetime_format or datetime_field_overflow or check_violation then
  raise exception '날짜와 시각을 확인해 주세요. 행사 종료는 시작 이후여야 합니다.' using errcode = '22023';
end;
$$;

create function private.manage_participant_registration(p_action text, p_payload jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor_id uuid;
  target public.members;
  target_id uuid;
  new_email text := lower(btrim(p_payload->>'email'));
  new_name text := btrim(p_payload->>'name');
  expected_email text;
  details jsonb := '{}'::jsonb;
begin
  perform private.require_staff();
  -- Serialize with roster imports and owner changes to staff permissions.
  perform id from public.event_settings where id for update;
  actor_id := private.require_staff();

  if jsonb_typeof(p_payload->'email') is distinct from 'string'
    or char_length(new_email) > 254
    or new_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception '로그인에 사용할 Google 이메일을 확인해 주세요.' using errcode = '22023';
  end if;

  case p_action
    when 'create_member' then
      if jsonb_typeof(p_payload->'name') is distinct from 'string'
        or char_length(new_name) not between 1 and 100 then
        raise exception '이름은 1~100자로 입력해 주세요.' using errcode = '22023';
      end if;
      insert into public.members (name, email, team_id, role)
      values (new_name, new_email, (p_payload->>'team_id')::uuid, 'participant')
      returning id into target_id;

    when 'update_member_email' then
      if jsonb_typeof(p_payload->'expected_email') is distinct from 'string'
        or jsonb_typeof(p_payload->'confirm_disconnect') is distinct from 'boolean' then
        raise exception '기존 이메일과 로그인 계정 연결 상태를 확인해 주세요.' using errcode = '22023';
      end if;
      expected_email := lower(btrim(p_payload->>'expected_email'));
      target_id := (p_payload->>'id')::uuid;

      -- First-time Google binding also locks this row, so check its current connection after locking.
      select * into target from public.members where id = target_id and role = 'participant' for update;
      if not found then
        raise exception '수정할 참가자를 찾을 수 없습니다.' using errcode = '22023';
      end if;
      if target.email is distinct from expected_email then
        raise exception '다른 운영진이 로그인 이메일을 변경했습니다. 새로고침 후 다시 확인해 주세요.' using errcode = '22023';
      end if;
      if target.email = new_email then return; end if;
      if target.auth_user_id is not null then
        if (private.current_member()).role <> 'owner' then
          raise exception '연결된 참가자의 로그인 이메일은 총관리자만 변경할 수 있습니다.' using errcode = '42501';
        end if;
        if p_payload->'confirm_disconnect' <> 'true'::jsonb then
          raise exception '새로고침 후 로그인 계정 연결 해제를 확인해 주세요.' using errcode = '22023';
        end if;
      end if;

      update public.members set email = new_email, auth_user_id = null where id = target_id;
      delete from private.presentation_uploads where member_id = target_id;
      details := jsonb_build_object('disconnected', target.auth_user_id is not null);
    else
      raise exception '지원하지 않는 참가자 변경입니다.' using errcode = '22023';
  end case;

  insert into public.audit_logs (actor_id, action, target_id, details)
  values (actor_id, p_action, target_id, details);
exception
  when unique_violation then
    raise exception '이미 등록된 이메일입니다.' using errcode = '22023';
  when foreign_key_violation or invalid_text_representation then
    raise exception '선택한 팀 또는 참가자를 확인해 주세요.' using errcode = '22023';
end;
$$;

revoke all on function private.manage_participant_registration(text, jsonb) from public, anon, authenticated;
grant execute on function private.manage_participant_registration(text, jsonb) to authenticated;

create or replace function public.manage_roster(p_action text, p_payload jsonb) returns void
language plpgsql security invoker set search_path = '' as $$
begin
  if p_action in ('create_member', 'update_member_email') then
    perform private.manage_participant_registration(p_action, p_payload);
  else
    perform private.manage_roster(p_action, p_payload);
  end if;
end;
$$;

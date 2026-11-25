-- Current-policy suites only; migration-stage fixtures must retain their original schema.
create function pg_temp.consent_fixture_members(choices jsonb) returns void
language plpgsql as $$
declare member record; previous_subject text := current_setting('request.jwt.claim.sub', true);
begin
  if not private.privacy_enforced() then raise exception 'current-policy fixture requires consent enforcement'; end if;
  for member in select m.auth_user_id from public.members m join auth.users u on u.id=m.auth_user_id
    where m.active and lower(m.email)=lower(u.email) and m.email like '%@%example.test' loop
    perform set_config('request.jwt.claim.sub', member.auth_user_id::text, true);
    set local role authenticated;
    perform public.save_my_consents('2026-11-16.1', true, choices);
    reset role;
  end loop;
  perform set_config('request.jwt.claim.sub', coalesce(previous_subject,''), true);
end;
$$;

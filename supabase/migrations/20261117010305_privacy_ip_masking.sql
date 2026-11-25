-- Keep protected audit originals; only return masked addresses to the application.
create function private.mask_access_ip(p_value text) returns text
language plpgsql immutable security invoker set search_path='' as $$
declare address text; octets text[]; masked text[] := '{}';
begin
  if p_value is null then return null; end if;
  foreach address in array string_to_array(p_value, ',') loop
    address := regexp_replace(btrim(address), '^::ffff:', '', 'i');
    if address ~ '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' then
      octets := string_to_array(address, '.');
      if octets[1]::integer <= 255 and octets[2]::integer <= 255
        and octets[3]::integer <= 255 and octets[4]::integer <= 255 then
        masked := array_append(masked, octets[1]::integer || '.' || octets[2]::integer || '.*.*');
        continue;
      end if;
    end if;
    -- IPv6 and unrecognized forwarding values must not fall back to raw text.
    masked := array_append(masked, '*');
  end loop;
  return coalesce(nullif(array_to_string(masked, ', '), ''), '*');
end;
$$;
revoke all on function private.mask_access_ip(text) from public, anon, authenticated, service_role;

do $migration$
declare definition text; old text := 'jsonb_agg(to_jsonb(l) order by l.id desc)';
begin
  definition := pg_get_functiondef('private.get_privacy_operations()'::regprocedure);
  if (length(definition)-length(replace(definition,old,'')))/length(old) <> 1 then
    raise exception 'Privacy IP masking requires exactly one access log projection';
  end if;
  execute replace(definition, old,
    $new$jsonb_agg(to_jsonb(l) || jsonb_build_object('source_ip',private.mask_access_ip(l.source_ip),'gateway_ip',private.mask_access_ip(l.gateway_ip)) order by l.id desc)$new$);
end;
$migration$;

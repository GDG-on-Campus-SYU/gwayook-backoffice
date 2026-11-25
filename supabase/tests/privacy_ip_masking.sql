begin;
update private.privacy_control set enforced=true where id;

do $$
declare sample record;
begin
  for sample in select * from (values
    (null::text, null::text), ('', '*'), ('  ', '*'),
    ('203.0.113.42', '203.0.*.*'), ('255.255.255.255', '255.255.*.*'),
    ('0.0.0.0', '0.0.*.*'), (' 198.51.100.73 ', '198.51.*.*'),
    ('198.51.100.73, 192.0.2.49', '198.51.*.*, 192.0.*.*'),
    ('::ffff:203.0.113.42', '203.0.*.*'), ('::FFFF:198.51.100.73', '198.51.*.*'),
    ('2001:db8:1234:5678::9', '*'), ('::1', '*'), ('unknown', '*'),
    ('256.1.2.3', '*'), ('1.2.3.256', '*'), ('1.2.3', '*'),
    ('203.0.113.42:443', '*'), ('203.0.113.42/24', '*'),
    ('198.51.100.73, 2001:db8::1, unknown', '198.51.*.*, *, *'),
    ('for="203.0.113.42";proto=https', '*')
  ) samples(raw, expected) loop
    if private.mask_access_ip(sample.raw) is distinct from sample.expected then
      raise exception 'unexpected IP mask for fixture %', sample.raw;
    end if;
  end loop;
end $$;

insert into auth.users(id,email,email_confirmed_at)
select ('c1000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,'ip-mask-'||i||'@example.test',now() from generate_series(1,3) i;
insert into public.members(id,name,email,auth_user_id,role)
select ('c2000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,'IP mask fixture '||i,'ip-mask-'||i||'@example.test',
  ('c1000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  case i when 1 then 'owner' when 2 then 'staff' else 'participant' end from generate_series(1,3) i;
insert into private.operator_access_logs(actor_id,actor_login,operation,resource,source_ip,gateway_ip,source_kind,retain_until)
select 'c2000000-0000-0000-0000-000000000001','ip-mask-1@example.test','read','ip-mask-fixture-'||i,source_ip,gateway_ip,'forwarded-header',now()+interval '1 year'
from (values
  (1,'203.0.113.42'::text,'198.51.100.73, 192.0.2.49'::text),
  (2,null,'198.51.100.73'),
  (3,'2001:db8:1234:5678::9','::1'),
  (4,null,null),
  (5,'::ffff:203.0.113.42','unknown')
) addresses(i,source_ip,gateway_ip);

create temp table ip_mask_preserved as select
  (select jsonb_agg(to_jsonb(l) order by id) from private.operator_access_logs l where resource like 'ip-mask-fixture-%') logs,
  (select to_jsonb(e) from public.event_settings e) event,
  (select jsonb_agg(to_jsonb(t) order by id) from public.teams t) teams,
  (select jsonb_agg(to_jsonb(g)) from private.bingo_game g) bingo;

set local role authenticated;
do $$
declare i integer; result jsonb; log jsonb;
begin
  if has_function_privilege('anon','public.get_privacy_operations()','execute')
    or has_function_privilege('authenticated','private.mask_access_ip(text)','execute')
    or has_table_privilege('authenticated','private.operator_access_logs','select') then
    raise exception 'IP masking broadened access';
  end if;
  for i in 1..3 loop
    perform set_config('request.jwt.claim.sub','c1000000-0000-0000-0000-'||lpad(i::text,12,'0'),true);
    perform public.save_my_consents('2026-11-16.1',true,'{"team":false,"presentation":false,"bingo":false}');
    if i>1 then
      begin perform public.get_privacy_operations(); raise exception 'non-owner obtained IP log dashboard';
      exception when insufficient_privilege then null; end;
    end if;
  end loop;
  perform set_config('request.jwt.claim.sub','c1000000-0000-0000-0000-000000000001',true);
  result:=public.get_privacy_operations();
  if strpos(result::text,'203.0.113.42')>0 or strpos(result::text,'198.51.100.73')>0
    or strpos(result::text,'192.0.2.49')>0 or strpos(result::text,'2001:db8:1234:5678::9')>0 then
    raise exception 'raw IP escaped the RPC projection';
  end if;
  select value into strict log from jsonb_array_elements(result->'access_logs') where value->>'resource'='ip-mask-fixture-1';
  if log->>'source_ip' is distinct from '203.0.*.*' or log->>'gateway_ip' is distinct from '198.51.*.*, 192.0.*.*' then
    raise exception 'IPv4 or forwarded chain not masked';
  end if;
  select value into strict log from jsonb_array_elements(result->'access_logs') where value->>'resource'='ip-mask-fixture-2';
  if log->>'source_ip' is not null or log->>'gateway_ip' is distinct from '198.51.*.*' then
    raise exception 'gateway fallback broken';
  end if;
  select value into strict log from jsonb_array_elements(result->'access_logs') where value->>'resource'='ip-mask-fixture-3';
  if log->>'source_ip' is distinct from '*' or log->>'gateway_ip' is distinct from '*' then raise exception 'IPv6 not hidden'; end if;
  select value into strict log from jsonb_array_elements(result->'access_logs') where value->>'resource'='ip-mask-fixture-4';
  if log->>'source_ip' is not null or log->>'gateway_ip' is not null then raise exception 'DB session null fallback changed'; end if;
end $$;
reset role;

do $$ begin
  if exists(select 1 from ip_mask_preserved p where
    p.logs is distinct from (select jsonb_agg(to_jsonb(l) order by id) from private.operator_access_logs l where resource like 'ip-mask-fixture-%')
    or p.event is distinct from (select to_jsonb(e) from public.event_settings e)
    or p.teams is distinct from (select jsonb_agg(to_jsonb(t) order by id) from public.teams t)
    or p.bingo is distinct from (select jsonb_agg(to_jsonb(g)) from private.bingo_game g)) then
    raise exception 'masking changed protected originals or event state';
  end if;
  if not exists(select 1 from private.operator_access_logs where resource='operator_access_logs' and actor_login='ip-mask-1@example.test') then
    raise exception 'owner read access was not audited';
  end if;
end $$;
rollback;

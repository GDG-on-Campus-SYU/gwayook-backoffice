begin;

insert into auth.users (id, email) values
  ('30000000-0000-0000-0000-000000000001', 'stock-staff@example.test'),
  ('30000000-0000-0000-0000-000000000002', 'stock-member@example.test');
insert into public.members (name, email, role, auth_user_id) values
  ('Stock Staff', 'stock-staff@example.test', 'staff', '30000000-0000-0000-0000-000000000001'),
  ('Stock Member', 'stock-member@example.test', 'participant', '30000000-0000-0000-0000-000000000002');
insert into public.teams (id, name) values
  ('30000000-0000-0000-0000-000000000003', 'Stock Team A'),
  ('30000000-0000-0000-0000-000000000004', 'Stock Team B');

\ir fixtures/consented-members.sql
select pg_temp.consent_fixture_members('{"team":false,"presentation":false,"bingo":false}');

set local role authenticated;
do $$
declare
  staff constant uuid := '30000000-0000-0000-0000-000000000001';
  participant constant uuid := '30000000-0000-0000-0000-000000000002';
  team_a constant uuid := '30000000-0000-0000-0000-000000000003';
  team_b constant uuid := '30000000-0000-0000-0000-000000000004';
  item constant uuid := '30000000-0000-0000-0000-000000000005';
  receipt constant uuid := '30000000-0000-0000-0000-000000000006';
  issued constant uuid := '30000000-0000-0000-0000-000000000007';
  balance public.inventory_item_balances;
begin
  if has_function_privilege('anon', 'public.create_inventory_item(uuid,text,text,text)', 'execute')
    or has_table_privilege('authenticated', 'public.inventory_movements', 'insert') then
    raise exception 'unexpected direct write or anonymous grant';
  end if;
  perform set_config('request.jwt.claim.sub', staff::text, true);
  perform public.create_inventory_item(item, 'Cable', 'Lab', null);
  perform public.create_inventory_item(item, 'Cable', 'Lab', null);
  perform public.record_inventory_movement(receipt, item, 'received', 20, null, null);
  perform public.record_inventory_movement(receipt, item, 'received', 20, null, null);
  perform public.record_inventory_movement(issued, item, 'issued', 12, team_a, null);
  perform public.record_inventory_movement(issued, item, 'issued', 12, team_a, null);

  begin
    perform public.record_inventory_movement(gen_random_uuid(), item, 'issued', 9, team_b, null);
    raise exception 'issued more than on hand';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.record_inventory_movement(gen_random_uuid(), item, 'recovered', 1, team_b, null);
    raise exception 'recovered from the wrong team';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.record_inventory_movement(gen_random_uuid(), item, 'correction', 1, null, null);
    raise exception 'accepted correction without a reason';
  exception when invalid_parameter_value then null;
  end;

  perform public.record_inventory_movement(gen_random_uuid(), item, 'recovered', 5, team_a, null);
  perform public.record_inventory_movement(gen_random_uuid(), item, 'returned', 3, null, null);
  perform public.record_inventory_movement(gen_random_uuid(), item, 'correction', -1, null, 'Damaged');
  select * into strict balance from public.inventory_item_balances where id = item;
  if balance.received <> 20 or balance.team_held <> 7 or balance.on_hand <> 9
    or balance.external_returned <> 3 or balance.external_outstanding <> 17 then
    raise exception 'unexpected balance: %', balance;
  end if;

  perform public.record_inventory_movement(gen_random_uuid(), item, 'correction', 10, null, 'Count reconciliation');
  begin
    perform public.record_inventory_movement(gen_random_uuid(), item, 'returned', 18, null, null);
    raise exception 'returned more than external outstanding';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.record_inventory_movement(gen_random_uuid(), item, 'correction', -20, null, 'Negative');
    raise exception 'correction put stock below zero';
  exception when invalid_parameter_value then null;
  end;

  perform set_config('request.jwt.claim.sub', participant::text, true);
  if exists (select 1 from public.inventory_item_balances) or exists (select 1 from public.inventory_team_balances)
    or exists (select 1 from public.inventory_movements) then
    raise exception 'participant read staff inventory';
  end if;
  begin
    perform public.record_inventory_movement(gen_random_uuid(), item, 'received', 1, null, null);
    raise exception 'participant updated inventory';
  exception when insufficient_privilege then null;
  end;
end;
$$;

select '1..1' as tap;
select 'ok 1 - inventory balances, duplicate requests and staff access' as tap;
rollback;

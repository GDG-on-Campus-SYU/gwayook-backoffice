create table public.inventory_items (
  id uuid primary key,
  name text not null check (name = btrim(name) and char_length(name) between 1 and 100),
  source text not null check (source = btrim(source) and char_length(source) between 1 and 100),
  memo text check (char_length(memo) <= 500),
  updated_at timestamptz not null default now()
);
create unique index inventory_item_name_source on public.inventory_items (lower(name), lower(source));

create table public.inventory_movements (
  id uuid primary key,
  item_id uuid not null references public.inventory_items (id),
  kind text not null check (kind in ('received', 'issued', 'recovered', 'returned', 'correction')),
  quantity integer not null check (quantity between -10000 and 10000 and quantity <> 0),
  team_id uuid references public.teams (id),
  actor_id uuid not null references public.members (id),
  reason text check (char_length(reason) <= 500),
  created_at timestamptz not null default clock_timestamp(),
  check (kind = 'correction' or quantity > 0),
  check (kind <> 'correction' or coalesce(char_length(btrim(reason)), 0) > 0),
  check ((kind in ('issued', 'recovered')) = (team_id is not null))
);
create index inventory_movements_item_time on public.inventory_movements (item_id, created_at desc);

alter table public.inventory_items enable row level security;
alter table public.inventory_movements enable row level security;
create policy read_inventory_items on public.inventory_items for select to authenticated
  using ((select (private.current_member()).role) in ('staff', 'owner'));
create policy read_inventory_movements on public.inventory_movements for select to authenticated
  using ((select (private.current_member()).role) in ('staff', 'owner'));

create view public.inventory_item_balances with (security_invoker = true) as
select i.id, i.name, i.source, i.memo,
  coalesce(sum(m.quantity) filter (where m.kind = 'received'), 0) as received,
  coalesce(sum(m.quantity) filter (where m.kind = 'returned'), 0) as external_returned,
  coalesce(sum(case m.kind when 'received' then m.quantity when 'returned' then -m.quantity end), 0) as external_outstanding,
  coalesce(sum(case m.kind when 'issued' then m.quantity when 'recovered' then -m.quantity end), 0) as team_held,
  coalesce(sum(case when m.kind in ('received', 'recovered', 'correction') then m.quantity else -m.quantity end), 0) as on_hand
from public.inventory_items i left join public.inventory_movements m on m.item_id = i.id
group by i.id;

create view public.inventory_team_balances with (security_invoker = true) as
select item_id, team_id, sum(case when kind = 'issued' then quantity else -quantity end) as held
from public.inventory_movements where team_id is not null group by item_id, team_id;

revoke all on public.inventory_items, public.inventory_movements, public.inventory_item_balances,
  public.inventory_team_balances from public, anon, authenticated;
grant select on public.inventory_items, public.inventory_movements, public.inventory_item_balances,
  public.inventory_team_balances to authenticated;

create function private.create_inventory_item(p_id uuid, p_name text, p_source text, p_memo text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := private.require_staff();
begin
  p_name := btrim(p_name);
  p_source := btrim(p_source);
  p_memo := nullif(btrim(p_memo), '');
  if p_id is null or p_name is null or char_length(p_name) not between 1 and 100
    or p_source is null or char_length(p_source) not between 1 and 100 or char_length(p_memo) > 500 then
    raise exception '품목, 차용처, 메모를 확인해 주세요.' using errcode = '22023';
  end if;

  insert into public.inventory_items (id, name, source, memo)
  values (p_id, p_name, p_source, p_memo) on conflict (id) do nothing;
  if found then
    insert into public.audit_logs (actor_id, action, target_id, details)
    values (actor, 'inventory_item_created', p_id, jsonb_build_object('name', p_name));
  elsif not exists (select 1 from public.inventory_items i where i.id = p_id
    and i.name = p_name and i.source = p_source and i.memo is not distinct from p_memo) then
    raise exception '요청이 이미 처리되었습니다. 화면을 새로고침해 주세요.' using errcode = '22023';
  end if;
exception when unique_violation then
  raise exception '같은 품목과 차용처가 이미 등록되어 있습니다.' using errcode = '22023';
end;
$$;

create function private.record_inventory_movement(
  p_id uuid, p_item uuid, p_kind text, p_quantity integer, p_team uuid, p_reason text
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := private.require_staff();
  balance public.inventory_item_balances;
  team_held bigint;
  previous public.inventory_movements;
begin
  p_reason := nullif(btrim(p_reason), '');
  if p_id is null or p_item is null or p_kind is null
    or p_kind not in ('received', 'issued', 'recovered', 'returned', 'correction')
    or p_quantity is null or p_quantity not between -10000 and 10000 or p_quantity = 0
    or (p_kind <> 'correction' and p_quantity < 0)
    or ((p_kind in ('issued', 'recovered')) <> (p_team is not null))
    or (p_kind = 'correction' and p_reason is null) or char_length(p_reason) > 500 then
    raise exception '처리 종류, 수량, 대상 팀, 사유를 확인해 주세요.' using errcode = '22023';
  end if;

  -- Serialize movements for this item before reading its ledger.
  perform id from public.inventory_items where id = p_item for no key update;
  if not found then raise exception '품목을 다시 선택해 주세요.' using errcode = '22023'; end if;
  actor := private.require_staff();

  select * into previous from public.inventory_movements where id = p_id;
  if found then
    if previous.item_id = p_item and previous.actor_id = actor and previous.kind = p_kind
      and previous.quantity = p_quantity and previous.team_id is not distinct from p_team
      and previous.reason is not distinct from p_reason then return; end if;
    raise exception '요청이 이미 처리되었습니다. 화면을 새로고침해 주세요.' using errcode = '22023';
  end if;

  select * into balance from public.inventory_item_balances where id = p_item;
  if p_kind in ('issued', 'returned') and p_quantity > balance.on_hand then
    raise exception '운영진 보관 수량을 넘을 수 없습니다.' using errcode = '22023';
  end if;
  if p_kind = 'returned' and p_quantity > balance.external_outstanding then
    raise exception '차용처에 남은 반납 수량을 넘을 수 없습니다.' using errcode = '22023';
  end if;
  if p_kind = 'correction' and balance.on_hand + p_quantity < 0 then
    raise exception '정정 후 운영진 보관 수량이 0보다 작을 수 없습니다.' using errcode = '22023';
  end if;
  if p_kind = 'recovered' then
    select held into team_held from public.inventory_team_balances where item_id = p_item and team_id = p_team;
    if p_quantity > coalesce(team_held, 0) then
      raise exception '선택한 팀이 보유한 수량을 넘을 수 없습니다.' using errcode = '22023';
    end if;
  end if;

  insert into public.inventory_movements (id, item_id, kind, quantity, team_id, actor_id, reason)
  values (p_id, p_item, p_kind, p_quantity, p_team, actor, p_reason);
  update public.inventory_items set updated_at = clock_timestamp() where id = p_item;
  if p_kind = 'correction' then
    insert into public.audit_logs (actor_id, action, target_id, details)
    values (actor, 'inventory_correction', p_item, jsonb_build_object('quantity', p_quantity, 'reason', p_reason));
  end if;
exception
  when foreign_key_violation then raise exception '대상 팀을 다시 선택해 주세요.' using errcode = '22023';
  when unique_violation then raise exception '요청이 이미 처리되었습니다. 화면을 새로고침해 주세요.' using errcode = '22023';
end;
$$;

create function public.create_inventory_item(p_id uuid, p_name text, p_source text, p_memo text) returns void
language sql security invoker set search_path = '' as $$
  select private.create_inventory_item(p_id, p_name, p_source, p_memo);
$$;

create function public.record_inventory_movement(
  p_id uuid, p_item uuid, p_kind text, p_quantity integer, p_team uuid, p_reason text
) returns void language sql security invoker set search_path = '' as $$
  select private.record_inventory_movement(p_id, p_item, p_kind, p_quantity, p_team, p_reason);
$$;

revoke all on function private.create_inventory_item(uuid, text, text, text),
  public.create_inventory_item(uuid, text, text, text),
  private.record_inventory_movement(uuid, uuid, text, integer, uuid, text),
  public.record_inventory_movement(uuid, uuid, text, integer, uuid, text) from public, anon, authenticated;
grant execute on function private.create_inventory_item(uuid, text, text, text),
  public.create_inventory_item(uuid, text, text, text),
  private.record_inventory_movement(uuid, uuid, text, integer, uuid, text),
  public.record_inventory_movement(uuid, uuid, text, integer, uuid, text) to authenticated;

import Link from "next/link";
import { requireStaff } from "@/lib/auth";
import { ItemForm, MovementForm } from "./forms";
import { movementLabels, type InventoryTeam, type MovementKind } from "./types";

export const metadata = { title: "물품 관리" };

type ItemBalance = {
  id: string;
  name: string;
  source: string;
  memo: string | null;
  received: number;
  team_held: number;
  on_hand: number;
  external_returned: number;
  external_outstanding: number;
};

type Movement = {
  id: string;
  kind: MovementKind;
  quantity: number;
  team_id: string | null;
  reason: string | null;
  created_at: string;
  actor: { name: string } | null;
};

const time = new Intl.DateTimeFormat("ko-KR", {
  month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit", timeZone: "Asia/Seoul",
});
const number = new Intl.NumberFormat("ko-KR");

export default async function InventoryPage({ searchParams }: { searchParams: Promise<{ item?: string | string[] }> }) {
  const [{ supabase }, { item }] = await Promise.all([requireStaff(), searchParams]);
  const { data, error } = await supabase.from("inventory_item_balances")
    .select("id,name,source,memo,received,team_held,on_hand,external_returned,external_outstanding").order("name").order("source")
    .overrideTypes<ItemBalance[], { merge: false }>();
  if (error) throw new Error("Could not load inventory balances");
  const items = data ?? [];
  const selected = items.find(({ id }) => id === item);

  return <>
    <header className="stack compact">
      <h1>물품 관리</h1>
      <p className="muted">빌린 물품을 등록하고 팀 지급과 차용처 반납 수량을 확인하세요.</p>
    </header>
    <section className="panel stack" aria-labelledby="inventory-list">
      <h2 id="inventory-list">품목별 수량</h2>
      {items.length ? <div className="table-wrap" tabIndex={0} role="region" aria-label="품목별 수량 표">
        <p className="table-scroll-hint">표가 잘리면 좌우로 밀어 확인하세요.</p>
        <table>
          <thead><tr>
            <th scope="col">품목</th><th scope="col">차용처</th><th scope="col">수령</th><th scope="col">팀 보유</th>
            <th scope="col">운영진 보관</th><th scope="col">외부 반납</th><th scope="col">외부 미반납</th><th scope="col">관리</th>
          </tr></thead>
          <tbody>{items.map((entry) => <tr key={entry.id}>
            <th scope="row">{entry.name}</th><td>{entry.source}</td><td>{number.format(entry.received)}</td>
            <td>{number.format(entry.team_held)}</td><td>{number.format(entry.on_hand)}</td>
            <td>{number.format(entry.external_returned)}</td><td>{number.format(entry.external_outstanding)}</td>
            <td><Link className="text-link" href={`/admin/inventory?item=${entry.id}#item-details`}
              aria-label={`${entry.name} (${entry.source}) 수량 처리`}>수량 처리</Link></td>
          </tr>)}</tbody>
        </table>
      </div> : <p className="muted">등록된 물품이 없습니다. 아래에서 첫 품목을 등록하세요.</p>}
    </section>
    {selected && <ItemDetails key={selected.id} item={selected} />}
    <section className="panel stack" aria-labelledby="register-item">
      <h2 id="register-item">새 품목 등록</h2>
      <ItemForm requestId={crypto.randomUUID()} />
    </section>
  </>;
}

async function ItemDetails({ item }: { item: ItemBalance }) {
  const { supabase } = await requireStaff();
  const [teams, balances, movements] = await Promise.all([
    supabase.from("teams").select("id,name").order("name").overrideTypes<InventoryTeam[], { merge: false }>(),
    supabase.from("inventory_team_balances").select("team_id,held").eq("item_id", item.id).gt("held", 0),
    supabase.rpc("get_inventory_history", { p_item_id: item.id }),
  ]);
  if (teams.error || balances.error || movements.error) throw new Error("Could not load item history");
  const movementRows = movements.data as Movement[];
  const teamNames = new Map(teams.data.map(({ id, name }) => [id, name]));

  return <section id="item-details" className="panel stack" aria-labelledby="item-name">
    <header className="stack compact">
      <h2 id="item-name">{item.name}</h2>
      <p className="muted">차용처 {item.source} · 운영진 보관 {number.format(item.on_hand)}개 · 외부 미반납 {number.format(item.external_outstanding)}개</p>
      {item.memo && <p className="preserve-lines">{item.memo}</p>}
    </header>
    <MovementForm item={item.id} teams={teams.data} requestId={crypto.randomUUID()} />
    <section className="stack compact" aria-labelledby="team-balances">
      <h3 id="team-balances">팀별 미회수</h3>
      {balances.data.length ? <ul className="team-list">{balances.data.map(({ team_id, held }) => <li key={team_id}>
        <span>{teamNames.get(team_id) ?? "팀"}</span><strong>{number.format(held)}개</strong>
      </li>)}</ul> : <p className="muted">회수할 물품이 없습니다.</p>}
    </section>
    <section className="stack compact" aria-labelledby="movement-history">
      <h3 id="movement-history">최근 처리 기록</h3>
      {movementRows.length ? <div className="table-wrap" tabIndex={0} role="region" aria-label="최근 처리 기록 표">
        <p className="table-scroll-hint">표가 잘리면 좌우로 밀어 확인하세요.</p>
        <table>
          <thead><tr><th scope="col">시각</th><th scope="col">처리</th><th scope="col">수량</th><th scope="col">대상 팀</th><th scope="col">처리자</th><th scope="col">메모</th></tr></thead>
          <tbody>{movementRows.map((movement) => <tr key={movement.id}>
            <td><time dateTime={movement.created_at}>{time.format(new Date(movement.created_at))}</time></td>
            <th scope="row">{movementLabels[movement.kind]}</th>
            <td>{movement.kind === "correction" && movement.quantity > 0 ? "+" : ""}{number.format(movement.quantity)}</td>
            <td>{movement.team_id ? teamNames.get(movement.team_id) : "—"}</td>
            <td>{movement.actor?.name ?? "—"}</td><td className="preserve-lines">{movement.reason || "—"}</td>
          </tr>)}</tbody>
        </table>
      </div> : <p className="muted">아직 처리 기록이 없습니다.</p>}
    </section>
  </section>;
}

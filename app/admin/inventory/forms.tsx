"use client";

import { useActionState, useState } from "react";
import { Button } from "@astryxdesign/core/Button";
import { createItem, recordMovement, type InventoryState } from "./actions";
import { movementLabels, type InventoryTeam, type MovementKind } from "./types";

const initialState: InventoryState = { status: "idle", message: "" };

function Feedback({ state }: { state: InventoryState }) {
  if (!state.message) return null;
  return <p role={state.status === "error" ? "alert" : "status"}>{state.message}</p>;
}

export function ItemForm({ requestId }: { requestId: string }) {
  const [id, setId] = useState(requestId);
  const [name, setName] = useState("");
  const [source, setSource] = useState("");
  const [memo, setMemo] = useState("");
  const [state, action, pending] = useActionState(async (previous: InventoryState, form: FormData) => {
    const result = await createItem(previous, form);
    if (result.status === "saved") {
      setId(crypto.randomUUID());
      setName("");
      setSource("");
      setMemo("");
    }
    return result;
  }, initialState);

  return <form className="stack" action={action} aria-label="새 품목 등록">
    <input type="hidden" name="request_id" value={id} />
    <fieldset className="stack" disabled={pending}>
      <label className="field">품목명
        <input name="name" maxLength={100} value={name} onChange={(event) => setName(event.target.value)} required />
      </label>
      <label className="field">차용처
        <input name="source" maxLength={100} value={source} onChange={(event) => setSource(event.target.value)} required />
      </label>
      <label className="field">메모 (선택)
        <input name="memo" maxLength={500} value={memo} onChange={(event) => setMemo(event.target.value)} />
      </label>
      <div className="action-row"><Button type="submit" variant="primary" label="품목 등록" isLoading={pending} /></div>
    </fieldset>
    <Feedback state={state} />
  </form>;
}

export function MovementForm({ item, teams, requestId }: { item: string; teams: InventoryTeam[]; requestId: string }) {
  const [id, setId] = useState(requestId);
  const [kind, setKind] = useState<MovementKind>("received");
  const [team, setTeam] = useState("");
  const [quantity, setQuantity] = useState("");
  const [reason, setReason] = useState("");
  const needsTeam = kind === "issued" || kind === "recovered";
  const [state, action, pending] = useActionState(async (previous: InventoryState, form: FormData) => {
    const result = await recordMovement(previous, form);
    if (result.status === "saved") {
      setId(crypto.randomUUID());
      setQuantity("");
      setReason("");
    }
    return result;
  }, initialState);

  return <form className="stack" action={action} aria-label="물품 수량 처리">
    <input type="hidden" name="request_id" value={id} />
    <input type="hidden" name="item" value={item} />
    <fieldset className="stack" disabled={pending}>
      <label className="field">처리 종류
        <select name="kind" value={kind} onChange={(event) => setKind(event.target.value as MovementKind)}>
          {Object.entries(movementLabels).map(([value, label]) => <option value={value} key={value}>{label}</option>)}
        </select>
      </label>
      {needsTeam && <label className="field">대상 팀
        <select name="team" value={team} onChange={(event) => setTeam(event.target.value)} required>
          <option value="">팀 선택</option>
          {teams.map(({ id, name }) => <option value={id} key={id}>{name}</option>)}
        </select>
      </label>}
      {needsTeam && teams.length === 0 && <p className="muted">팀을 등록한 뒤 지급·회수를 기록할 수 있습니다.</p>}
      <label className="field">{kind === "correction" ? "정정 수량" : "수량"}
        <input name="quantity" type="number" min={kind === "correction" ? -10000 : 1} max={10000} step={1}
          value={quantity} onChange={(event) => setQuantity(event.target.value)} required />
      </label>
      {kind === "correction" && <p className="muted">운영진 보관 수량을 늘리려면 양수, 줄이려면 음수를 입력하세요. 팀 보유량과 외부 반납 대상 수량은 각각 지급·회수와 외부 반납으로 처리합니다.</p>}
      <label className="field">{kind === "correction" ? "정정 사유" : "메모 (선택)"}
        <input name="reason" maxLength={500} value={reason} onChange={(event) => setReason(event.target.value)} required={kind === "correction"} />
      </label>
      <div className="action-row"><Button type="submit" variant="primary" label="수량 반영" isLoading={pending}
        isDisabled={(needsTeam && teams.length === 0) || Number(quantity) === 0} /></div>
    </fieldset>
    <Feedback state={state} />
  </form>;
}

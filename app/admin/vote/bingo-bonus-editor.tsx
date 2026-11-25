"use client";

import { useActionState, useState } from "react";
import { Button } from "@astryxdesign/core/Button";
import { maxBingoBonus } from "@/lib/bingo";
import type { BingoBonus, VoteActionState } from "../../vote/data";
import { saveBingoBonus } from "./actions";

const initialState: VoteActionState = { status: "idle", message: "" };

function TeamBonusForm({ team }: { team: BingoBonus }) {
  const [draft, setDraft] = useState<{ value: string; expected: number }>();
  const value = draft?.value ?? String(team.bingo_bonus);
  const expected = draft?.expected ?? team.bingo_bonus;
  const stale = expected !== team.bingo_bonus;
  const [state, action, pending] = useActionState(async (previous: VoteActionState, form: FormData) => {
    const result = await saveBingoBonus(previous, form);
    if (result.status === "saved") setDraft(undefined);
    return result;
  }, initialState);

  return <form action={action} className="stack compact" aria-label={`${team.name} 빙고 가산점`}>
    <input type="hidden" name="team_id" value={team.team_id} />
    <input type="hidden" name="expected_points" value={expected} />
    <div className="action-row">
      <label className="field">{team.name} · 빙고 가산점
        <input type="number" name="points" inputMode="numeric" min={0} max={maxBingoBonus} step={1} required disabled={pending}
          value={value} onChange={(event) => setDraft({ value: event.target.value, expected })} />
      </label>
      <Button type="submit" variant="secondary" label="저장" aria-label={`${team.name} 빙고 가산점 저장`}
        isLoading={pending} isDisabled={pending || stale || !value || Number(value) === team.bingo_bonus} />
    </div>
    {stale && <div>
      <Button type="button" variant="secondary" label={`변경된 ${team.bingo_bonus}점 불러오기`} onClick={() => setDraft(undefined)} />
    </div>}
    {state.message && (state.status === "error" || !draft) && <p role={state.status === "error" ? "alert" : "status"}>{state.message}</p>}
  </form>;
}

export function BingoBonusEditor({ teams, locked }: { teams: BingoBonus[]; locked: boolean }) {
  return <section className="panel stack" aria-labelledby="bingo-bonus">
    <h2 id="bingo-bonus">팀별 빙고 가산점</h2>
    {locked
      ? <p className="notice">재투표가 시작되었거나 결과가 공개되어 빙고 가산점이 확정되었습니다.</p>
      : <p className="muted">빙고 기록을 확인한 뒤 팀이 받을 총 가산점을 입력하세요. 0점으로 저장하면 해당 팀의 빙고 가산점이 해제됩니다.</p>}
    {teams.length ? <ul className="team-list" role="list">{teams.map((team) => <li key={team.team_id}>
      {locked ? <><strong>{team.name}</strong><span>{team.bingo_bonus}점</span></> : <TeamBonusForm team={team} />}
    </li>)}</ul> : <p className="muted">등록된 팀이 없습니다.</p>}
  </section>;
}

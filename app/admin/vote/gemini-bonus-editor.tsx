"use client";

import { startTransition, useActionState, useState } from "react";
import { Button } from "@astryxdesign/core/Button";
import { formatEventTime } from "@/lib/event-time";
import type { GeminiBonus, VoteActionState } from "../../vote/data";
import { saveGeminiBonus } from "./actions";
import styles from "./controls.module.css";

const initialState: VoteActionState = { status: "idle", message: "" };

function BonusForm({ team, locked }: { team: GeminiBonus; locked: boolean }) {
  const [draft, setDraft] = useState<{ approved?: boolean; note?: string }>({});
  const approved = draft.approved ?? team.approved;
  const note = draft.note ?? team.note ?? "";
  const changed = approved !== team.approved || note.trim() !== (team.note ?? "");
  const [state, action, pending] = useActionState(async (previous: VoteActionState, form: FormData) => {
    const result = await saveGeminiBonus(previous, form);
    if (result.status === "saved") setDraft({});
    return result;
  }, initialState);
  return <details className="notice">
    <summary>{team.name} · {team.approved ? "Gemini +1점 승인" : "가산점 없음"}</summary>
    <form action={action} className="stack" aria-label={`${team.name} Gemini 가산점`} onSubmit={(event) => {
      event.preventDefault();
      if (pending || locked) return;
      const form = new FormData(event.currentTarget);
      startTransition(() => action(form));
    }}>
      <input type="hidden" name="team_id" value={team.team_id} />
      <input type="hidden" name="approved" value={String(approved)} />
      <fieldset className="stack" disabled={pending || locked} aria-label={`${team.name} 활용 확인`}>
        <label className={styles.choice}>
          <input type="checkbox" checked={approved} onChange={(event) => setDraft((previous) => ({ ...previous, approved: event.target.checked }))} />
          <span>Gemini로 앱 프로토타입 또는 기타 시각적 결과물을 만든 것을 확인했습니다. (+1점)</span>
        </label>
        <label className="field">확인 근거{approved ? " (필수)" : " (선택)"}
          <textarea name="note" value={note} onChange={(event) => setDraft((previous) => ({ ...previous, note: event.target.value }))} maxLength={500} required={approved} placeholder="확인한 결과물과 Gemini 활용 내용을 적어 주세요." />
        </label>
      </fieldset>
      {team.decided_at && <p className="muted">최근 확인 · {team.decided_by_name ?? "운영 기록"} · {formatEventTime(team.decided_at)} · 한국 시간</p>}
      {!locked && <div><Button type="submit" variant="secondary" label="가산점 확인 저장" isLoading={pending} isDisabled={pending || !changed || (approved && !note.trim())} /></div>}
      {state.message && <p role={state.status === "error" ? "alert" : "status"}>{state.message}</p>}
    </form>
  </details>;
}

export function GeminiBonusEditor({ teams, locked }: { teams: GeminiBonus[]; locked: boolean }) {
  return <section className="panel stack" aria-labelledby="gemini-bonus-heading">
    <h2 id="gemini-bonus-heading">Gemini 활용 가산점 · 총관리자 확인</h2>
    <p className="muted">Gemini로 앱 프로토타입 또는 기타 시각적 결과물을 만든 팀에 1점을 더합니다. 팀당 최대 1점이며, 총관리자가 근거를 남겨 승인합니다.</p>
    <p className={locked ? "notice" : "muted"}>{locked ? "재투표가 생성되었거나 결과가 공개되어 가산점이 잠겼습니다. 확인 기록만 볼 수 있습니다." : "첫 재투표를 시작하거나 결과를 공개하면 가산점은 더 이상 수정할 수 없습니다. 그 전에 모든 팀의 확인을 마쳐 주세요."}</p>
    {teams.length ? teams.map((team) => <BonusForm key={team.team_id} team={team} locked={locked} />) : <p className="muted">등록된 팀이 없습니다.</p>}
  </section>;
}

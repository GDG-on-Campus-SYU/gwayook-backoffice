"use client";

import { startTransition, useActionState, useState, type FormEvent, type ReactNode } from "react";
import { Button } from "@astryxdesign/core/Button";
import { manageRunoff, manageVote } from "./actions";
import type { Candidate, Runoff, RunoffGroup, VoteActionState, VoteResult } from "../../vote/data";
import { localEventInput } from "@/lib/event-time";
import styles from "./controls.module.css";

const buttonLabels = { open: "지금 투표 열기", schedule: "투표 예약 확정", cancel: "투표 예약 취소", close: "투표 마감 확정", publish: "수상 결과 공개" } as const;
const initialState: VoteActionState = { status: "idle", message: "" };
const confirmations = {
  open: "지금 후보·유권자와 소속 팀을 확정하고 투표를 시작합니다.",
  schedule: "지금 후보·유권자와 소속 팀을 확정하고 예약 시각에 투표를 시작합니다.",
  cancel: "예약을 취소하고 후보·유권자 명단을 다시 준비하는 것을 확인했습니다.",
  close: "이 시점부터 모든 투표와 변경을 막는 것을 확인했습니다.",
  publish: "득표 집계와 최종 수상 팀을 참가자에게 공개하는 것을 확인했습니다.",
};

function VoteForm({ operation, eligibleCount, children }: { operation: keyof typeof buttonLabels; eligibleCount?: number; children?: ReactNode }) {
  const [state, action, pending] = useActionState(manageVote.bind(null, operation), initialState);
  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (pending) return;
    // Keep the entered award information when the database rejects the submission.
    const form = new FormData(event.currentTarget);
    startTransition(() => action(form));
  }
  return (
    <form action={action} onSubmit={submit} className="panel stack">
      <h2>{buttonLabels[operation]}</h2>
      <fieldset disabled={pending} className="stack" aria-label={`${buttonLabels[operation]} 입력`}>
        {children}
        <label className={styles.choice}>
          <input key={`${operation}:${eligibleCount ?? ""}`} name="confirm" type="checkbox" value={eligibleCount ?? "yes"} required />
          <span>{eligibleCount !== undefined && <><strong>유권자 {eligibleCount}명</strong> · 팀에 배정된 활성 참가자 중 출석·지각으로 체크인한 인원을 확인했습니다. </>}{confirmations[operation]}</span>
        </label>
      </fieldset>
      <div><Button label={buttonLabels[operation]} type="submit" variant="primary" isLoading={pending} isDisabled={pending} /></div>
      {state.message && <p role={state.status === "error" ? "alert" : "status"}>{state.message}</p>}
    </form>
  );
}

export function OpenVote({ candidates, closesAt, eligibleCount }: { candidates: Candidate[]; closesAt: string; eligibleCount: number }) {
  const [mode, setMode] = useState<"schedule" | "open">("schedule");
  return (
    <VoteForm operation={mode} eligibleCount={eligibleCount}>
      <fieldset className="stack compact">
        <legend>시작 방식</legend>
        <label className={styles.choice}><input type="radio" name="mode" value="schedule" checked={mode === "schedule"} onChange={() => setMode("schedule")} /><span>시각을 정해 자동 시작</span></label>
        <label className={styles.choice}><input type="radio" name="mode" value="open" checked={mode === "open"} onChange={() => setMode("open")} /><span>지금 바로 시작</span></label>
      </fieldset>
      {mode === "schedule" && <label className="field">투표 시작 시각 (한국 시간)
        <input name="opens_at" type="datetime-local" required max={localEventInput(closesAt)} />
        <span className="muted">투표 마감 이전으로 입력하세요. 시작 전에는 예약을 취소해 변경할 수 있습니다.</span>
      </label>}
      <p className="muted">활성 참가자가 있는 팀을 후보로 미리 선택했습니다. 유권자는 모든 팀의 현장 체크인을 기준으로 집계합니다. 확정 후에는 출석이나 팀이 바뀌어도 이번 투표의 명단과 소속 팀은 유지됩니다.</p>
      <ul className="team-list">
        {candidates.map((candidate) => <li key={candidate.id}>
          <label className={styles.choice}>
            <input type="checkbox" name="candidate_id" value={candidate.id} defaultChecked={(candidate.active_member_count ?? 0) > 0} />
            <span>{candidate.name}<span className={`${styles.candidateMeta} muted`}>활성 참가자 {candidate.active_member_count ?? 0}명</span></span>
          </label>
        </li>)}
      </ul>
    </VoteForm>
  );
}

export function CancelVoteSchedule() {
  return <VoteForm operation="cancel"><p className="muted">시작 시각·마감·후보·유권자를 바꾸려면 시작 전에 예약을 취소하고 다시 확정하세요. 기존 투표 마감은 유지됩니다.</p></VoteForm>;
}

export function CloseVote({ early }: { early: boolean }) {
  return <VoteForm operation="close">
    <p className="muted">{early ? "설정된 마감 시각 전입니다. 지금 확정하면 즉시 투표가 종료됩니다." : "설정된 마감 시각이 지났습니다. 마감을 확정하면 집계 결과를 볼 수 있습니다."}</p>
  </VoteForm>;
}

export function PublishVote({ results }: { results: VoteResult[] }) {
  const [count, setCount] = useState(Math.min(3, results.length));
  return (
    <VoteForm operation="publish">
      <p className="muted">이번 행사 수상 기준은 3팀입니다. 수상 팀 수와 순위를 확인해 주세요.</p>
      {results.length < 3 && <p className="notice" role="status">현재 후보는 {results.length}팀으로, 수상 기준 3팀에 부족합니다. 결과 공개 전에 운영 기준을 확인해 주세요.</p>}
      <label className="field">수상 팀 수
        <select name="award_count" value={count} onChange={(event) => setCount(Number(event.currentTarget.value))}>
          {results.map((row, index) => <option key={row.team_id} value={index + 1}>{index + 1}팀</option>)}
        </select>
      </label>
      {Array.from({ length: count }, (_, index) => {
        const rank = index + 1;
        const choices = results.filter((row) => row.raw_rank <= rank && rank < row.raw_rank + row.tied_count);
        const tied = choices.length > 1;
        return (
          <div className="notice stack" key={rank}>
            <label className="field">{rank}위 수상 팀
              <select name={`team_${rank}`} required defaultValue={tied ? "" : choices[0]?.team_id}>
                {tied && <option value="" disabled>동점 팀에서 선택</option>}
                {choices.map((row) => <option key={row.team_id} value={row.team_id}>{row.name} · 합계 {row.total_score}점</option>)}
              </select>
            </label>
            <label className="field">수상명 (선택)<input name={`name_${rank}`} maxLength={80} placeholder={`${rank}위`} /></label>
            {tied && <label className="field">동점 결정 사유<input name={`reason_${rank}`} maxLength={500} required /></label>}
          </div>
        );
      })}
    </VoteForm>
  );
}

export function RunoffControls({ groups, runoff }: { groups: RunoffGroup[]; runoff: Runoff | null }) {
  const active = runoff && runoff.status !== "closed";
  const available = groups.filter((group) => !group.completed);
  const [selectedRank, setSelectedRank] = useState(available[0]?.raw_rank ?? 0);
  const selected = available.find((group) => group.raw_rank === selectedRank) ?? available[0];
  const operation = active ? "close" : "start";
  const [state, action, pending] = useActionState(manageRunoff.bind(null, operation), initialState);
  const label = active ? "재투표 마감 확정" : "동점 재투표 시작";
  if (!active && !available.length) return null;
  return <form className="panel stack" action={action} onSubmit={(event) => {
    event.preventDefault();
    if (!pending) {
      const form = new FormData(event.currentTarget);
      startTransition(() => action(form));
    }
  }}>
    <h2>{label}</h2>
    <fieldset className="stack" disabled={pending} aria-label={label}>
      {active ? <>
        <input type="hidden" name="runoff_id" value={runoff.id} />
        <p className="muted">{runoff.status === "open" ? "지금 확정하면 즉시 재투표가 끝납니다." : "시간이 끝났습니다. 마감을 확정해 집계를 확인하세요."} 다시 동점이면 최종 수상에서 결정 사유를 입력합니다.</p>
      </> : <>
        <label className="field">재투표할 동점 그룹
          <select value={selected?.raw_rank ?? ""} onChange={(event) => setSelectedRank(Number(event.currentTarget.value))} required>
            {available.map((group) => <option key={group.raw_rank} value={group.raw_rank}>공동 {group.raw_rank}위 · 합계 {group.main_score}점 · {group.candidates.length}팀</option>)}
          </select>
        </label>
        <ul className="team-list">{selected?.candidates.map((candidate) => <li key={candidate.id}>
          <input type="hidden" name="candidate_id" value={candidate.id} /><span>{candidate.name}</span>
        </li>)}</ul>
        <label className="field">재투표 마감 시각 (한국 시간)<input type="datetime-local" name="closes_at" required /></label>
        <p className="muted">저장 즉시 시작합니다. 본투표·Gemini 가산점·빙고 가산점의 합계가 같은 팀끼리 재투표합니다. 본투표 유권자 중 이 후보팀 소속을 제외한 사람만 참여합니다. 기존 본투표·대표자·마감 설정은 유지됩니다. 첫 재투표부터 두 가산점이 확정됩니다. 같은 동점 그룹은 한 번만 재투표하며, 다시 동점이면 운영진 결정 사유를 남깁니다.</p>
      </>}
      <label className={styles.choice}><input key={operation} type="checkbox" name="confirm" value="yes" required />
        <span>{active ? "재투표를 마감하고 집계를 확정하는 것을 확인했습니다." : "이 동점 그룹 전체로 지금 재투표를 시작하는 것을 확인했습니다."}</span>
      </label>
    </fieldset>
    <div><Button type="submit" label={label} variant="primary" isLoading={pending} isDisabled={pending} /></div>
    {state.message && <p role={state.status === "error" ? "alert" : "status"}>{state.message}</p>}
  </form>;
}

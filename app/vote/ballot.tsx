"use client";

import { useActionState } from "react";
import { Button } from "@astryxdesign/core/Button";
import { saveVote } from "./actions";
import type { Candidate, VoteActionState } from "./data";

const initialState: VoteActionState = { status: "idle", message: "" };

export function Ballot({ candidates, ownTeamId, choiceId, runoffId }: {
  candidates: Candidate[];
  ownTeamId: string | null;
  choiceId: string | null;
  runoffId?: string;
}) {
  const [state, submit, pending] = useActionState(saveVote, initialState);
  return (
    <form className="panel stack" action={submit}>
      {runoffId && <input type="hidden" name="runoff_id" value={runoffId} />}
      <fieldset className="stack compact" disabled={pending}>
        <legend><strong>투표할 팀 한 곳 선택</strong></legend>
        {candidates.map((team) => (
          <label className="action-row notice" key={team.id}>
            <input type="radio" name="team_id" value={team.id} defaultChecked={team.id === choiceId} disabled={team.id === ownTeamId} required />
            <span>{team.name}</span>
            {team.id === ownTeamId && <span className="muted">우리 팀</span>}
          </label>
        ))}
      </fieldset>
      <p className="muted">마감 전에는 선택을 바꿀 수 있습니다. 투표한 팀은 본인만 확인할 수 있습니다.</p>
      <div className="action-row">
        <Button type="submit" label={choiceId ? "선택 변경" : "투표하기"} variant="primary" isLoading={pending} isDisabled={pending} />
        {state.message && <p role={state.status === "error" ? "alert" : "status"}>{state.message}</p>}
      </div>
    </form>
  );
}

"use client";

import { startTransition, useActionState, type FormEvent } from "react";
import { Button } from "@astryxdesign/core/Button";
import type { BingoFeedback } from "../../bingo/data";
import { saveBingo, manageBingo } from "./actions";
import styles from "../../bingo/bingo.module.css";

const initialState: BingoFeedback = { status: "idle", message: "" };

export function BingoConfigForm({ questions, prize }: { questions: string[]; prize: string }) {
  const [state, action, pending] = useActionState(saveBingo, initialState);
  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (pending) return;
    const form = new FormData(event.currentTarget);
    startTransition(() => action(form));
  }
  return <form className="panel stack" action={action} onSubmit={submit}>
    <h2>문항·상품 초안</h2>
    <p className="muted">빈 문항을 남겨 저장할 수 있습니다. 빙고를 열려면 25개를 모두 입력해야 합니다. 참가자마다 같은 문항을 다른 순서로 배치하며, 공개 후에는 변경할 수 없습니다.</p>
    <fieldset disabled={pending} className="stack" aria-label="빙고 초안">
      <div className={styles.questions}>
        {Array.from({ length: 25 }, (_, index) => <label className="field" key={index}>문항 {index + 1}<input name="question" defaultValue={questions[index] ?? ""} maxLength={200} /></label>)}
      </div>
      <label className="field">상품 안내 (선택)<textarea name="prize" maxLength={500} defaultValue={prize} placeholder="3줄 완성 시 받을 상품 또는 수령 방법" /></label>
    </fieldset>
    <div><Button type="submit" variant="secondary" label="초안 저장" isLoading={pending} isDisabled={pending} /></div>
    {state.message && <p role={state.status === "error" ? "alert" : "status"}>{state.message}</p>}
  </form>;
}

export function BingoControl({ operation, roundNo, ready = true }: { operation: "open" | "close" | "restart"; roundNo: number; ready?: boolean }) {
  const [state, action, pending] = useActionState(manageBingo.bind(null, operation), initialState);
  const label = operation === "open" ? "빙고 공개하고 25분 시작" : operation === "restart" ? "새 회차로 25분 다시 시작" : "빙고 지금 종료";
  return <form action={action} className="panel stack">
    <h2>{operation === "open" ? "참가자에게 공개" : operation === "restart" ? "새 회차 시작" : "조기 종료"}</h2>
    <input name="round_no" type="hidden" value={roundNo} />
    <p className="muted">{operation === "open" ? "아래 버튼으로 공개를 확정한 시점부터 25분입니다. 그전에는 참가자에게 메뉴와 준비 중 화면만 보이며, 문항과 QR 참여는 시작 후 열립니다." : operation === "restart" ? `${roundNo}회차의 O표·완성·확인 기록을 보존하고 ${roundNo + 1}회차를 시작합니다. 같은 문항·상품으로 빙고판을 새로 섞고 O표 0개부터 25분간 진행합니다. 이전 QR은 사용할 수 없습니다.` : "예정된 종료 시각 전이라도 확인을 즉시 막습니다. 이미 남은 O표와 기록은 이 회차에 보존됩니다. 이후 새 회차를 시작할 수 있습니다."}</p>
    {!ready && <p className="notice">문항 25개를 모두 입력하고 초안을 저장해 주세요.</p>}
    <label className={styles.choice}>
      <input name="confirm" type="checkbox" value="yes" required disabled={pending || !ready} />
      <span>{operation === "open" ? "저장된 문항·상품을 확인했고, 지금 공개해 25분 동안 진행하겠습니다." : operation === "restart" ? "이전 회차 기록을 보존하고, 새 회차를 지금 공개해 25분 동안 진행하겠습니다." : "현재 회차의 빙고를 지금 종료하는 것을 확인했습니다."}</span>
    </label>
    <div><Button type="submit" variant="primary" label={label} isLoading={pending} isDisabled={pending || !ready} /></div>
    {state.message && <p role={state.status === "error" ? "alert" : "status"}>{state.message}</p>}
  </form>;
}

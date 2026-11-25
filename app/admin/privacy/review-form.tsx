"use client";
import { useActionState } from "react";
import { Button } from "@astryxdesign/core/Button";
import { saveErasureReview } from "./actions";

export function ErasureReviewForm() {
  const [state, action, pending] = useActionState(saveErasureReview, {});
  return <form action={action} className="stack compact">
    <label className="field">파기 검토 기록<textarea name="note" required maxLength={1000} rows={3} placeholder="대상 확인, 외부 사본 담당자, 보존 예외, 실행 예정일 등. 참가자 이름·이메일은 적지 마세요." /></label>
    <p className="muted">현재 대상 건수·기한·검토 담당자·시각을 저장합니다. 데이터 삭제는 실행하지 않습니다.</p>
    {state.error && <p role="alert">{state.error}</p>}{state.saved && <p role="status">검토 기록을 저장했습니다. 실제 파기는 실행되지 않았습니다.</p>}
    <Button type="submit" isDisabled={pending} label={pending ? "저장 중…" : "파기 검토 기록 저장"} />
  </form>;
}

"use client";

import { startTransition, useActionState, useState } from "react";
import { useRouter } from "next/navigation";
import { Button } from "@astryxdesign/core/Button";
import type { MyGsa } from "@/lib/gsa";
import { saveMyGsaEmail, type GsaFeedback } from "./actions";

const initial: GsaFeedback = { status: "idle", message: "" };

export function GsaEmailForm({ record }: { record: MyGsa }) {
  const router = useRouter();
  const [draft, setDraft] = useState<{ email: string; expected: string | null }>();
  const [hideFeedback, setHideFeedback] = useState(false);
  const current = draft ?? { email: record.gsa_email ?? "", expected: record.gsa_updated_at };
  const changed = current.email.trim().toLowerCase() !== (record.gsa_email ?? "");
  const stale = draft !== undefined && current.expected !== record.gsa_updated_at;
  const [state, action, pending] = useActionState(async (previous: GsaFeedback, form: FormData) => {
    const result = await saveMyGsaEmail(previous, form);
    if (result.status === "saved") setDraft(undefined);
    setHideFeedback(false);
    return result;
  }, initial);
  return <form action={action} className="panel stack" aria-label="내 GSA 신청 이메일" onSubmit={(event) => {
    event.preventDefault();
    if (!pending) { const form = new FormData(event.currentTarget);startTransition(() => action(form)); }
  }}>
    <h2>{record.gsa_email ? "신청 이메일 수정" : "신청 이메일 입력"}</h2>
    <input type="hidden" name="expected_updated_at" value={current.expected ?? ""} />
    <label className="field">GSA 신청 이메일<input type="email" name="email" value={current.email} maxLength={254} autoComplete="off" required disabled={pending} placeholder="GSA 신청에 사용한 이메일" onChange={(event) => { setDraft({ email: event.target.value, expected: current.expected });setHideFeedback(true); }} /></label>
    <p className="muted">앱 로그인 이메일과 달라도 됩니다. 이 주소를 저장해도 로그인 계정은 바뀌지 않습니다.</p>
    {record.gsa_email && changed && <p className="notice">이메일을 바꾸어 저장하면 기존 확인이 해제되고 ‘확인 대기’로 돌아갑니다. 저장 전까지 위의 현장 제시 카드에는 이전 이메일이 표시됩니다.</p>}
    {stale && <p className="notice" role="alert">다른 화면에서 신청 이메일이나 확인 상태가 바뀌었습니다. 최신 상태를 불러온 뒤 다시 확인해 주세요.</p>}
    <div className="action-row"><Button type="submit" label={record.gsa_email ? "이메일 변경·재확인 요청" : "신청 이메일 저장"} variant="primary" isLoading={pending} isDisabled={pending || !changed || !current.email.trim() || stale} />
      <Button type="button" label="최신 상태 확인" variant="secondary" isDisabled={pending} onClick={() => { setDraft(undefined);setHideFeedback(true);router.refresh(); }} /></div>
    <p className="muted">최신 상태를 확인하면 저장하지 않은 이메일 수정은 지워집니다.</p>
    {!hideFeedback && state.message && <p role={state.status === "error" ? "alert" : "status"}>{state.message}</p>}
  </form>;
}

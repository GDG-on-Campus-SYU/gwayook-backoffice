"use client";

import Link from "next/link";
import { startTransition, useActionState, useEffect, useRef } from "react";
import { Button } from "@astryxdesign/core/Button";
import { Dialog, DialogHeader } from "@astryxdesign/core/Dialog";
import { confirmBingo } from "../actions";
import type { BingoFeedback } from "../data";
import styles from "../bingo.module.css";

const initialState: BingoFeedback = { status: "idle", message: "" };

export function ConfirmBingoForm({ token, onClose }: { token: string; onClose?: () => void }) {
  const [state, action, pending] = useActionState(confirmBingo, initialState);
  const submitted = useRef<string | null>(null);
  useEffect(() => {
    if (submitted.current === token) return;
    submitted.current = token;
    const form = new FormData();
    form.set("token", token);
    startTransition(() => action(form));
  }, [action, token]);
  const busy = state.status === "idle" || pending;
  const exit = onClose ? <Button type="button" variant="secondary" label="닫기" onClick={onClose} /> : <Link className="text-link" href="/bingo">내 빙고로 돌아가기</Link>;
  const content = busy ? <><p role="status">O표를 저장하고 있어요…</p><noscript>자동 인증하려면 브라우저에서 JavaScript를 켜 주세요.</noscript></> : state.status === "saved" ? <div className="stack">
    <p className={`notice ${styles.complete}`} role="status">{state.message}</p>
    <p className="muted">내 칸에도 O표를 받으려면 내 QR을 상대방에게 보여 주세요.</p>
    {exit}
  </div> : <form action={action} className="stack">
    <input type="hidden" name="token" value={token} />
    <p role="alert">{state.message}</p>
    <div><Button type="submit" variant="secondary" label="다시 시도" /></div>
    {exit}
  </form>;
  if (!onClose) return content;
  return <Dialog isOpen onOpenChange={(open) => { if (!open && !busy) onClose(); }} purpose={busy ? "required" : "info"} width={420} padding={4}>
    <div className="stack">
      <DialogHeader title={busy ? "O표를 저장하고 있어요" : state.status === "saved" ? "O표를 저장했어요" : "확인하지 못했어요"} />
      {content}
    </div>
  </Dialog>;
}

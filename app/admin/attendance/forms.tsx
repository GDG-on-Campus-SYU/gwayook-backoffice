"use client";

import { startTransition, useActionState, useState, type FormEvent } from "react";
import { useRouter } from "next/navigation";
import { Button } from "@astryxdesign/core/Button";
import { attendanceLabels, gsaLabels, type AttendanceStatus, type GsaStatus, type ParticipantOperation } from "@/lib/participant-operations";
import { saveAttendance, saveGsa, type OperationFeedback } from "./actions";
import styles from "./attendance.module.css";

const initial: OperationFeedback = { status: "idle", message: "" };
const timestamp = new Intl.DateTimeFormat("ko-KR", { dateStyle: "medium", timeStyle: "medium", timeZone: "Asia/Seoul" });

function submit(event: FormEvent<HTMLFormElement>, pending: boolean, action: (form: FormData) => void) {
  event.preventDefault();
  if (pending) return;
  const form = new FormData(event.currentTarget);
  startTransition(() => action(form));
}

function Feedback({ state }: { state: OperationFeedback }) {
  return state.message && <p className={styles.feedback} role={state.status === "error" ? "alert" : "status"}>{state.message}</p>;
}

function Updated({ at, by }: { at: string | null; by: string | null }) {
  return <p className="muted">{at ? <>최근 확인 · {by ?? "운영 기록"} · <time dateTime={at}>{timestamp.format(new Date(at))}</time> · 한국 시간</> : "아직 확인 기록이 없습니다."}</p>;
}

function RecordFields({ person, expected }: { person: ParticipantOperation; expected: string | null }) {
  return <><input type="hidden" name="member_id" value={person.member_id} /><input type="hidden" name="expected_updated_at" value={expected ?? ""} /></>;
}

export function QuickAttendance({ person }: { person: ParticipantOperation }) {
  const [state, action, pending] = useActionState(saveAttendance, initial);
  return <form action={action} onSubmit={(event) => submit(event, pending, action)} className="stack compact" aria-label={`${person.name} 빠른 출석`}>
    <RecordFields person={person} expected={person.attendance_updated_at} />
    <input type="hidden" name="status" value="present" /><input type="hidden" name="note" value={person.attendance_note ?? ""} />
    {person.attendance_status === "pending" && <Button type="submit" label="출석 확인" aria-label={`${person.name} 출석 확인`} variant="secondary" isLoading={pending} isDisabled={pending} />}
    {(state.status === "error" || person.attendance_status === "present") && <Feedback state={state} />}
  </form>;
}

type AttendanceDraft = { status: AttendanceStatus; note: string; expected: string | null };

export function AttendanceForm({ person }: { person: ParticipantOperation }) {
  const router = useRouter();
  const [draft, setDraft] = useState<AttendanceDraft>();
  const [hideFeedback, setHideFeedback] = useState(false);
  const current = draft ?? { status: person.attendance_status, note: person.attendance_note ?? "", expected: person.attendance_updated_at };
  const changed = current.status !== person.attendance_status || current.note.trim() !== (person.attendance_note ?? "");
  const stale = draft !== undefined && draft.expected !== person.attendance_updated_at;
  const [state, action, pending] = useActionState(async (previous: OperationFeedback, form: FormData) => {
    const result = await saveAttendance(previous, form);
    if (result.status === "saved") setDraft(undefined);
    setHideFeedback(false);
    return result;
  }, initial);
  function change(values: Partial<AttendanceDraft>) { setDraft({ ...current, ...values });setHideFeedback(true); }
  return <form action={action} onSubmit={(event) => submit(event, pending, action)} className="stack" aria-label={`${person.name} 출석 기록`}>
    <h4 className={styles.formHeading}>현장 출석 기록</h4>
    <RecordFields person={person} expected={current.expected} />
    <fieldset className={`stack ${styles.fields}`} disabled={pending} aria-label="출석 상태와 메모">
      <label className="field">출석 상태<select name="status" value={current.status} onChange={(event) => change({ status: event.target.value as AttendanceStatus })}>
        {Object.entries(attendanceLabels).map(([value, label]) => <option key={value} value={value}>{label}</option>)}
      </select></label>
      <label className="field">출석 메모 (선택)<textarea name="note" maxLength={500} rows={3} value={current.note} onChange={(event) => change({ note: event.target.value })} placeholder="지각·불참 사유나 현장 확인 내용을 적어 주세요." /></label>
    </fieldset>
    <p className="muted">체크인 · {person.checked_in_at ? <time dateTime={person.checked_in_at}>{timestamp.format(new Date(person.checked_in_at))} · 한국 시간</time> : "기록 없음"}</p>
    <p className="muted">출석·지각은 첫 체크인 시각을 유지합니다. 미확인·불참으로 정정하면 현재 체크인 시각은 비워지고 변경 이력은 남습니다.</p>
    <Updated at={person.attendance_updated_at} by={person.attendance_updated_by_name} />
    {stale && <p className="notice" role="alert">편집 중 출석 기록이 변경되었습니다. 최신 기록을 불러와 다시 확인해 주세요.</p>}
    <div className="action-row">
      <Button type="submit" label="출석 기록 저장" variant="secondary" isLoading={pending} isDisabled={pending || !changed || stale} />
      <button className={styles.refresh} type="button" disabled={pending} onClick={() => { setDraft(undefined);setHideFeedback(true);router.refresh(); }}>최신 출석 기록 불러오기</button>
    </div>
    <p className="muted">최신 기록을 불러오면 저장하지 않은 출석 수정은 지워집니다.</p>
    {!hideFeedback && <Feedback state={state} />}
  </form>;
}

type GsaDraft = { status: GsaStatus; email: string; note: string; expected: string | null; plusActive: boolean; emailMatched: boolean };

export function GsaForm({ person }: { person: ParticipantOperation }) {
  const router = useRouter();
  const [draft, setDraft] = useState<GsaDraft>();
  const [hideFeedback, setHideFeedback] = useState(false);
  const current = draft ?? { status: person.gsa_status, email: person.gsa_email ?? "", note: person.gsa_note ?? "", expected: person.gsa_updated_at,
    plusActive: person.gsa_plus_active, emailMatched: person.gsa_email_matched };
  const emailChanged = current.email.trim().toLowerCase() !== (person.gsa_email ?? "");
  const changed = current.status !== person.gsa_status || emailChanged || current.note.trim() !== (person.gsa_note ?? "")
    || current.plusActive !== person.gsa_plus_active || current.emailMatched !== person.gsa_email_matched;
  const stale = draft !== undefined && draft.expected !== person.gsa_updated_at;
  const [state, action, pending] = useActionState(async (previous: OperationFeedback, form: FormData) => {
    const result = await saveGsa(previous, form);
    if (result.status === "saved") setDraft(undefined);
    setHideFeedback(false);
    return result;
  }, initial);
  function change(values: Partial<GsaDraft>) {
    const next = { ...current, ...values };
    if (next.email.trim().toLowerCase() !== (person.gsa_email ?? "")) next.status = "pending";
    if (next.status !== "verified") { next.plusActive = false;next.emailMatched = false; }
    setDraft(next);setHideFeedback(true);
  }
  return <form action={action} onSubmit={(event) => submit(event, pending, action)} className="stack" aria-label={`${person.name} GSA 확인`}>
    <h4 className={styles.formHeading}>GSA·AI Plus 현장 확인</h4>
    <RecordFields person={person} expected={current.expected} />
    <input type="hidden" name="gsa_plus_active" value={String(current.status === "verified" && current.plusActive)} />
    <input type="hidden" name="gsa_email_matched" value={String(current.status === "verified" && current.emailMatched)} />
    <fieldset className={`stack ${styles.fields}`} disabled={pending} aria-label="GSA 상태와 확인 내용">
      <label className="field">GSA 상태<select name="status" value={current.status} onChange={(event) => change({ status: event.target.value as GsaStatus })}>
        {Object.entries(gsaLabels).map(([value, label]) => <option key={value} value={value} disabled={value === "verified" && (emailChanged || !person.gsa_email)}>{label}</option>)}
      </select></label>
      <label className="field">GSA 신청 이메일<input type="email" name="gsa_email" maxLength={254} value={current.email} autoComplete="off" onChange={(event) => change({ email: event.target.value })} placeholder="참가자가 신청 이메일을 입력하거나 운영진이 정정합니다." /></label>
      {emailChanged && <p className="notice">이메일을 바꾸면 확인 대기로 돌아가고 확인 항목은 초기화됩니다. 이메일을 먼저 저장한 뒤 실제 Google 계정을 다시 확인해 주세요.</p>}
      {!person.gsa_email && !emailChanged && <p className="muted">신청 이메일이 저장되어야 확인 완료로 변경할 수 있습니다.</p>}
      {current.status === "verified" && <div className="stack compact">
        <label className={styles.check}><input type="checkbox" checked={current.plusActive} onChange={(event) => change({ plusActive: event.target.checked })} /><span>참가자가 보여 준 실제 Google 계정에서 AI Plus가 활성화된 것을 확인했습니다.</span></label>
        <label className={styles.check}><input type="checkbox" checked={current.emailMatched} onChange={(event) => change({ emailMatched: event.target.checked })} /><span>그 Google 계정의 이메일이 위에 저장된 GSA 신청 이메일과 일치합니다.</span></label>
      </div>}
      <label className="field">내부 확인 메모 (선택)<textarea name="note" maxLength={500} rows={3} value={current.note} onChange={(event) => change({ note: event.target.value })} placeholder="현장에서 확인한 내용이나 재확인이 필요한 이유" /></label>
    </fieldset>
    <p className="muted">참가자의 입력 화면만으로 완료 처리하지 마세요. 실제 계정의 AI Plus 상태와 이메일을 함께 확인합니다. 내부 메모는 참가자에게 보이지 않습니다. 로그인 이메일과 Gemini 가산점은 바뀌지 않습니다.</p>
    <Updated at={person.gsa_updated_at} by={person.gsa_updated_by_name} />
    {stale && <p className="notice" role="alert">편집 중 GSA 기록이 변경되었습니다. 최신 기록을 불러와 다시 확인해 주세요.</p>}
    <div className="action-row">
      <Button type="submit" label="GSA 확인 저장" variant="secondary" isLoading={pending} isDisabled={pending || !changed || stale || (current.status === "verified" && (!current.plusActive || !current.emailMatched))} />
      <button className={styles.refresh} type="button" disabled={pending} onClick={() => { setDraft(undefined);setHideFeedback(true);router.refresh(); }}>최신 GSA 기록 불러오기</button>
    </div>
    <p className="muted">최신 기록을 불러오면 저장하지 않은 GSA 수정은 지워집니다.</p>
    {!hideFeedback && <Feedback state={state} />}
  </form>;
}

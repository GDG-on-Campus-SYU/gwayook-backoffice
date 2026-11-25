"use client";

import { startTransition, useActionState, useState } from "react";
import { Button } from "@astryxdesign/core/Button";
import Link from "next/link";
import { saveSettings, saveStaff, saveVoteDelegate, type SettingsFeedback } from "./actions";
import styles from "./settings.module.css";

const initial = { message: "", failed: false };

function Feedback({ state }: { state: SettingsFeedback }) {
  return state.message && <p role={state.failed ? "alert" : "status"}>{state.message}</p>;
}

const dateFields = [
  ["event_starts_at", "행사 시작"], ["event_ends_at", "행사 종료"],
  ["submission_deadline", "발표자료 제출 마감"], ["vote_closes_at", "투표 마감"],
] as const;

type Dates = Record<(typeof dateFields)[number][0], string>;

export function SettingsForm({ name, eventDate, dates, notice, contact, votingStarted }: {
  name: string; eventDate: string; dates: Dates; notice: string; contact: string; votingStarted: boolean;
}) {
  const saved = { name, event_date: eventDate, ...dates, notice, contact };
  const [draft, setDraft] = useState<Partial<typeof saved>>({});
  const values = { ...saved, ...draft };
  const update = (field: keyof typeof saved, value: string) => setDraft((current) => {
    const next = { ...current };
    if (value === saved[field]) delete next[field];
    else next[field] = value;
    return next;
  });
  const [state, action, pending] = useActionState(async (previous: SettingsFeedback, form: FormData) => {
    // Send only fields edited in this tab, even if newer server props arrived before submit.
    for (const field of Object.keys(saved) as (keyof typeof saved)[]) {
      if (draft[field] === undefined || draft[field] === saved[field]) form.delete(field);
    }
    const result = await saveSettings(previous, form);
    if (!result.failed) setDraft({});
    return result;
  }, initial);
  return <form action={action} className={`stack ${styles.form}`}>
    <fieldset className={styles.group} disabled={pending}>
      <legend>기본 정보</legend>
      <div className="settings-grid">
        <label className="field">행사명<input name="name" value={values.name} onChange={(e) => update("name", e.target.value)} required maxLength={100} /></label>
        <label className="field">행사 날짜<input type="date" name="event_date" value={values.event_date} onChange={(e) => update("event_date", e.target.value)} required /></label>
      </div>
    </fieldset>
    <fieldset className={styles.group} aria-describedby="schedule-help" disabled={pending}>
      <legend>일정과 마감</legend>
      <p id="schedule-help" className="muted">한국 시간 기준입니다. 미정인 시각은 비워둘 수 있습니다.</p>
      <div className="settings-grid">
        {dateFields.map(([field, label]) => <label className="field" key={field}>{label}
          <input type="datetime-local" name={field} value={values[field]} onChange={(e) => update(field, e.target.value)} disabled={field === "vote_closes_at" && votingStarted} />
        </label>)}
      </div>
      <p className="muted"><Link className="text-link" href="/admin/vote">투표 시작 예약과 후보 확인</Link>은 투표·수상 화면에서 진행합니다.</p>
      {votingStarted && <p className="muted">예약이 확정되었거나 시작한 투표의 마감은 바꿀 수 없습니다. 시작 전이라면 투표·수상 화면에서 예약을 취소할 수 있습니다.</p>}
    </fieldset>
    <fieldset className={styles.group} disabled={pending}>
      <legend>참가자 안내</legend>
      <div className="stack">
        <label className="field">공지<textarea name="notice" value={values.notice} onChange={(e) => update("notice", e.target.value)} maxLength={2500} /></label>
        <label className="field">문의처<input name="contact" value={values.contact} onChange={(e) => update("contact", e.target.value)} maxLength={160} /></label>
      </div>
    </fieldset>
    <div><Button type="submit" label="행사 설정 저장" variant="primary" isLoading={pending} isDisabled={pending} /></div>
    <Feedback state={state} />
  </form>;
}

export function AddStaffForm() {
  const [name, setName] = useState("");
  const [email, setEmail] = useState("");
  const [state, action, pending] = useActionState(async (previous: SettingsFeedback, form: FormData) => {
    const result = await saveStaff(previous, form);
    if (!result.failed) {
      setName("");
      setEmail("");
    }
    return result;
  }, initial);
  return <form action={action} className="stack">
    <fieldset className={`settings-grid ${styles.staffFields}`} disabled={pending} aria-label="운영진 등록 정보">
      <label className="field">이름<input name="name" value={name} onChange={(e) => setName(e.target.value)} required maxLength={100} /></label>
      <label className="field">Google 이메일<input name="email" type="email" value={email} onChange={(e) => setEmail(e.target.value)} required maxLength={254} /></label>
    </fieldset>
    <div><Button type="submit" label="운영진 등록" variant="primary" isLoading={pending} isDisabled={pending} /></div>
    <Feedback state={state} />
  </form>;
}

export function StaffStatus({ id, name, active }: { id: string; name: string; active: boolean }) {
  const [state, action, pending] = useActionState(saveStaff, initial);
  return <form action={action} className="stack compact">
    <input type="hidden" name="id" value={id} />
    <input type="hidden" name="active" value={String(!active)} />
    <div><Button type="submit" label={active ? "비활성화" : "다시 활성화"} aria-label={`${name} ${active ? "비활성화" : "다시 활성화"}`} variant="secondary" isLoading={pending} /></div>
    <Feedback state={state} />
  </form>;
}

export function VoteDelegateForm({ memberId, staff }: {
  memberId: string | null; staff: { id: string; name: string; email: string; role: string; active: boolean }[];
}) {
  const [draft, setDraft] = useState<string | undefined>();
  const saved = memberId ?? "";
  const selected = draft ?? saved;
  const eligible = staff.filter((person) => person.role === "staff" && person.active);
  const currentUnavailable = Boolean(memberId && !eligible.some((person) => person.id === memberId));
  const selectedUnavailable = Boolean(selected && !eligible.some((person) => person.id === selected));
  const [state, action, pending] = useActionState(async (previous: SettingsFeedback, form: FormData) => {
    const result = await saveVoteDelegate(previous, form);
    if (!result.failed) setDraft(undefined);
    return result;
  }, initial);
  return <form action={action} className="stack" aria-label="투표 운영 대행자 지정" onSubmit={(event) => {
    event.preventDefault();
    if (pending) return;
    const form = new FormData(event.currentTarget);
    startTransition(() => action(form));
  }}>
    <fieldset className={styles.group} disabled={pending} aria-describedby="vote-delegate-help">
      <legend>투표 운영 대행자</legend>
      <label className="field">대행할 운영진
        <select name="member_id" value={selected} onChange={(event) => setDraft(event.target.value)}>
          <option value="">미지정 · 총관리자만 운영</option>
          {selectedUnavailable && <option value={selected} disabled>{staff.find((person) => person.id === selected)?.name ?? "기존 지정자"} · 현재 대행 불가</option>}
          {eligible.map((person) => <option key={person.id} value={person.id}>{person.name} · {person.email}</option>)}
        </select>
      </label>
      <p id="vote-delegate-help" className="muted">활성 운영진 1명에게 본투표 예약·취소·시작·마감·결과 공개와 재투표 시작·마감 권한을 부여합니다. 행사 설정·Gemini 가산점 승인·빙고 회차 운영·운영진 관리는 총관리자만 할 수 있습니다.</p>
      {!eligible.length && <p className="muted">지정할 활성 운영진이 없습니다. 운영진을 먼저 등록하거나 활성화해 주세요.</p>}
      {currentUnavailable && <p className="notice">기존 지정자가 비활성이거나 운영진 권한이 없어 현재 투표를 운영할 수 없습니다. 다른 운영진을 지정하거나 지정을 해제해 주세요.</p>}
      {selectedUnavailable && !currentUnavailable && <p className="notice">선택한 운영진이 더 이상 대행할 수 없습니다. 활성 운영진을 다시 선택해 주세요.</p>}
    </fieldset>
    <div><Button type="submit" label="투표 대행자 저장" variant="primary" isLoading={pending} isDisabled={pending || selected === saved || selectedUnavailable} /></div>
    <Feedback state={state} />
  </form>;
}

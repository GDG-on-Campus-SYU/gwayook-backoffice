"use client";

import { startTransition, useActionState, useState } from "react";
import { Button } from "@astryxdesign/core/Button";
import { localEventInput } from "@/lib/event-time";
import type { ScheduleAdminItem } from "@/lib/schedule";
import { deleteScheduleItem, publishSchedule, saveScheduleItem, type ScheduleFeedback } from "./actions";
import styles from "./schedule-admin.module.css";

const initial: ScheduleFeedback = { status: "idle", message: "" };
function Feedback({ state }: { state: ScheduleFeedback }) {
  return state.message && <p role={state.status === "error" ? "alert" : "status"}>{state.message}</p>;
}

export function SchedulePublication({ published, version, count }: { published: boolean; version: number; count: number }) {
  const [state, action, pending] = useActionState(publishSchedule, initial);
  return <form action={action} className="stack">
    <input type="hidden" name="published" value={String(!published)} />
    <input type="hidden" name="version" value={version} />
    <p>{published ? `전체 ${count}개 일정을 참가자에게 공개하고 있습니다. 저장한 변경 사항도 바로 공개됩니다.` : `전체 ${count}개 일정을 초안으로 보관 중입니다. 참가자에게는 상세 내용이 보이지 않습니다.`}</p>
    <label className={styles.check}><input key={`${published}:${version}`} type="checkbox" name="confirm" value="yes" required disabled={pending} />
      <span>{published ? "전체 타임테이블을 비공개로 바꾸는 것을 확인했습니다." : "모든 일정의 내용·장소·시각을 검토했고 참가자에게 공개하는 것을 확인했습니다."}</span>
    </label>
    <div><Button type="submit" variant="secondary" label={published ? "타임테이블 비공개" : "전체 일정 공개"} isLoading={pending} isDisabled={pending || (!published && !count)} /></div>
    <Feedback state={state} />
  </form>;
}

export function ScheduleItemEditor({ item, published }: { item?: ScheduleAdminItem; published: boolean }) {
  const saved = { title: item?.title ?? "", description: item?.description ?? "", location: item?.location ?? "",
    starts_at: localEventInput(item?.starts_at ?? null), ends_at: localEventInput(item?.ends_at ?? null) };
  const [draft, setDraft] = useState<{ values: typeof saved; version: number } | null>(null);
  const values = draft?.values ?? saved;
  const expectedVersion = draft?.version ?? item?.version ?? 0;
  const stale = item && expectedVersion !== item.version;
  const changed = Object.entries(values).some(([key, value]) => value !== saved[key as keyof typeof saved]);
  const update = (key: keyof typeof saved, value: string) => setDraft({ values: { ...values, [key]: value }, version: expectedVersion });
  const [state, action, pending] = useActionState(async (previous: ScheduleFeedback, form: FormData) => {
    const result = await saveScheduleItem(previous, form);
    if (result.status === "saved") setDraft(null);
    return result;
  }, initial);
  return <form action={action} className="stack" aria-label={item ? `${item.title} 일정 수정` : "새 일정 추가"} onSubmit={(event) => {
    event.preventDefault();
    if (!pending) { const form = new FormData(event.currentTarget); startTransition(() => action(form)); }
  }}>
    <input type="hidden" name="id" value={item?.id ?? ""} />
    <input type="hidden" name="version" value={expectedVersion} />
    <fieldset className={styles.fields} disabled={pending}>
      <legend>{item ? "일정 수정" : "새 일정"}</legend>
      <label className="field">제목<input name="title" value={values.title} onChange={(event) => update("title", event.target.value)} maxLength={120} required /></label>
      <label className="field">참가자 안내 내용<textarea name="description" value={values.description} onChange={(event) => update("description", event.target.value)} maxLength={2000} /></label>
      <label className="field">장소<input name="location" value={values.location} onChange={(event) => update("location", event.target.value)} maxLength={200} /></label>
      <div className="settings-grid">
        <label className="field">시작 시각 · 한국 시간<input name="starts_at" type="datetime-local" value={values.starts_at} onChange={(event) => update("starts_at", event.target.value)} /></label>
        <label className="field">종료 시각 · 한국 시간<input name="ends_at" type="datetime-local" value={values.ends_at} onChange={(event) => update("ends_at", event.target.value)} /></label>
      </div>
      <p className="muted">미정 시각은 비워둘 수 있습니다. 종료를 입력하려면 시작도 필요합니다. 운영진 담당자·내부 연락처는 참가자 안내에 적지 마세요.</p>
    </fieldset>
    {stale && <p className="notice" role="alert">다른 화면에서 이 일정이 변경되었습니다. 입력한 내용을 확인한 뒤 최신 내용으로 되돌려 다시 수정해 주세요.</p>}
    {published && <p className="muted">현재 공개 중이므로 저장 즉시 참가자 화면에도 반영됩니다.</p>}
    <div className="action-row">
      <Button type="submit" label={item ? "일정 수정 저장" : "일정 추가"} variant="secondary" isLoading={pending} isDisabled={pending || !changed || !values.title.trim() || Boolean(stale)} />
      {draft && <Button type="button" label={stale ? "최신 내용으로 되돌리기" : "입력 취소"} variant="secondary" isDisabled={pending} onClick={() => setDraft(null)} />}
    </div>
    <Feedback state={state} />
  </form>;
}

export function ScheduleItemDelete({ item }: { item: ScheduleAdminItem }) {
  const [state, action, pending] = useActionState(deleteScheduleItem, initial);
  return <details className="notice">
    <summary>이 일정 삭제</summary>
    <form action={action} className="stack" onSubmit={(event) => {
      event.preventDefault();
      if (!pending) { const form = new FormData(event.currentTarget); startTransition(() => action(form)); }
    }}>
      <input type="hidden" name="id" value={item.id} />
      <input type="hidden" name="version" value={item.version} />
      <label className={styles.check}><input key={item.version} type="checkbox" name="confirm" value="yes" required disabled={pending} /><span>‘{item.title}’ 안내 일정 한 개를 삭제합니다. 실제 행사·제출·투표 설정은 유지됩니다.</span></label>
      <div><Button type="submit" label="일정 삭제" variant="secondary" isLoading={pending} isDisabled={pending} /></div>
      <Feedback state={state} />
    </form>
  </details>;
}

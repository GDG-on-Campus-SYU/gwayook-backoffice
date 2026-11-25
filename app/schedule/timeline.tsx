"use client";

import { useEffect, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Button } from "@astryxdesign/core/Button";
import { formatEventTime } from "@/lib/event-time";
import { formatScheduleRange, scheduleItemPhase, scheduleProgress, type ScheduleDetails } from "@/lib/schedule";
import styles from "./schedule.module.css";

const phaseLabels = { current: "진행 예정 시간", upcoming: "예정", finished: "안내 시간 지남", started: "시작 시각 지남", unscheduled: "시각 미정" };

export function ScheduleTimeline({ schedule, serverNow }: { schedule: ScheduleDetails; serverNow: number }) {
  const router = useRouter();
  const [now, setNow] = useState(serverNow);
  const [pending, startTransition] = useTransition();
  useEffect(() => {
    const started = performance.now();
    setNow(serverNow);
    const tick = () => { if (document.visibilityState === "visible") setNow(serverNow + performance.now() - started); };
    const refresh = () => { if (document.visibilityState === "visible") router.refresh(); };
    const resume = () => { tick(); refresh(); };
    const timer = window.setInterval(tick, 1000);
    const reload = window.setInterval(refresh, 60000);
    window.addEventListener("focus", resume);
    document.addEventListener("visibilitychange", resume);
    return () => {
      window.clearInterval(timer); window.clearInterval(reload);
      window.removeEventListener("focus", resume); document.removeEventListener("visibilitychange", resume);
    };
  }, [router, serverNow]);
  const { current, next } = scheduleProgress(schedule.items, now);
  return <div className="stack">
    {schedule.published && schedule.items.length > 0 ? <>
      <section className={styles.progress} aria-labelledby="schedule-progress">
        <h2 id="schedule-progress">지금과 다음 순서</h2>
        <p className="muted">안내 시각 기준이며 실제 진행은 현장 안내를 따라 주세요.</p>
        <div className={styles.progressGrid}>
          <div><h3>현재</h3>{current.length ? current.map((item) => <p key={item.id}><strong>{item.title}</strong><span className="muted">{formatScheduleRange(item)}</span></p>) : <p className="muted">현재 시각에 배정된 일정이 없어요.</p>}</div>
          <div><h3>다음</h3>{next.length ? next.map((item) => <p key={item.id}><strong>{item.title}</strong><span className="muted">{formatScheduleRange(item)}</span></p>) : <p className="muted">이후 예정된 일정이 없어요. 시각 미정 항목은 전체 목록에서 확인해 주세요.</p>}</div>
        </div>
      </section>
      <section aria-labelledby="schedule-full" className="stack">
        <h2 id="schedule-full">전체 일정</h2>
        <ol className={styles.timeline}>
          {schedule.items.map((item) => {
            const phase = scheduleItemPhase(item, now);
            return <li key={item.id} className={styles.item} data-current={phase === "current"}>
              <div className={styles.time}>{formatScheduleRange(item)}<span className="status-tag">{phase === "current" ? "현재 안내 일정" : phaseLabels[phase]}</span></div>
              <div className="stack compact"><h3>{item.title}</h3>{item.description && <p className="preserve-lines">{item.description}</p>}{item.location && <p className="muted">장소 · {item.location}</p>}</div>
            </li>;
          })}
        </ol>
      </section>
    </> : <section className="panel stack"><h2>상세 일정 안내 준비 중</h2><p>공개된 타임테이블이 아직 없습니다. 행사와 제출·투표의 기준 시각은 아래에서 확인하세요.</p></section>}
    <div className="action-row">
      <p className="muted">{schedule.published ? `안내 최종 수정 · ${formatEventTime(schedule.updated_at)}` : "일정이 공개되면 이 화면에 표시됩니다."}</p>
      <Button type="button" label="최신 일정 확인" variant="secondary" isLoading={pending} isDisabled={pending} onClick={() => startTransition(() => router.refresh())} />
    </div>
  </div>;
}

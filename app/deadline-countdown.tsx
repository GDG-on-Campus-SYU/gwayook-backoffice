"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { getCountdown, type CountdownPhase } from "@/lib/countdown";
import { formatEventTime } from "@/lib/event-time";
import styles from "./deadline-countdown.module.css";

let lastRefreshAt: number | undefined;

export function DeadlineCountdown({ label, deadline, serverNow, state = "open", href, opensAt }: {
  label: string; deadline: string | null; serverNow: number; state?: CountdownPhase; href?: string; opensAt?: string | null;
}) {
  if (state === "scheduled") {
    label = "투표 시작";
    deadline = opensAt ?? null;
  }
  const router = useRouter();
  const [now, setNow] = useState(serverNow);
  const countdown = getCountdown(deadline, now, state);

  useEffect(() => {
    const started = performance.now();
    lastRefreshAt ??= started;
    let previous = getCountdown(deadline, serverNow, state);
    setNow(serverNow);
    function refresh(force = false) {
      const elapsed = performance.now();
      // One refresh per page even when the submission and voting clocks update together.
      if (document.visibilityState !== "visible" || elapsed - (lastRefreshAt ?? 0) < (force ? 1000 : 60000)) return;
      lastRefreshAt = elapsed;
      router.refresh();
    }
    function tick() {
      const current = serverNow + performance.now() - started;
      setNow(current);
      const next = getCountdown(deadline, current, state);
      refresh(next.status === "starting" || (previous.status === "counting" && next.status === "closed"));
      previous = next;
    }
    function resume() {
      tick();
      refresh(true);
    }
    const interval = window.setInterval(tick, 1000);
    window.addEventListener("focus", resume);
    document.addEventListener("visibilitychange", resume);
    return () => {
      window.clearInterval(interval);
      window.removeEventListener("focus", resume);
      document.removeEventListener("visibilitychange", resume);
    };
  }, [deadline, router, serverNow, state]);

  const validDeadline = deadline && Number.isFinite(Date.parse(deadline)) ? deadline : null;
  return <section className={styles.card} aria-label={label} data-state={countdown.status}>
    <div className={styles.heading}>
      <h2>{href ? <Link href={href}>{label}<span aria-hidden="true">↗</span></Link> : label}</h2>
      <span className={styles.caption}>{countdown.status === "counting" ? "남은 시간" : state === "scheduled" ? "예약 상태" : "마감 상태"}</span>
    </div>
    <p className={styles.value} role="timer" aria-live="off" aria-atomic="true" aria-label={`${label}: ${countdown.text}`}>
      {countdown.text}
    </p>
    <p className={styles.date}>
      {validDeadline ? <time dateTime={validDeadline}>{formatEventTime(validDeadline)} · 한국 시간</time> : "마감이 설정되면 남은 시간을 표시합니다."}
    </p>
  </section>;
}

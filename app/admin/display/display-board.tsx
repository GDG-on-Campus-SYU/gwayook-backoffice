"use client";

import Link from "next/link";
import { useEffect, useRef, useState } from "react";
import { Button } from "@astryxdesign/core/Button";
import { getCountdown, type CountdownPhase } from "@/lib/countdown";
import { displayTeams, loadDisplaySnapshot, type DisplaySnapshot } from "@/lib/display";
import { formatEventDate, formatEventTime } from "@/lib/event-time";
import { ManualTimer } from "./manual-timer";
import styles from "./display.module.css";

const time = new Intl.DateTimeFormat("ko-KR", { timeZone: "Asia/Seoul", hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false });

function BoardTimer({ label, deadline, now, phase = "open", primary = false }: {
  label: string; deadline: string | null; now: number; phase?: CountdownPhase; primary?: boolean;
}) {
  const countdown = getCountdown(deadline, now, phase);
  const urgent = phase !== "scheduled" && countdown.status === "counting" && countdown.seconds <= 300;
  return <section className={`${styles.timer} ${primary ? styles.primaryTimer : ""}`} data-urgent={urgent} aria-label={label}>
    <h2>{label}</h2>
    <p className={styles.clock} data-counting={countdown.status === "counting"} role="timer" aria-live="off" aria-label={`${label}: ${countdown.text}`}>
      {countdown.text}
    </p>
    <p className={styles.timerDate}>{deadline ? <time dateTime={deadline}>{formatEventTime(deadline)} · 한국 시간</time> : "마감 시각이 아직 정해지지 않았습니다."}</p>
    {urgent && <p className={styles.urgent}>마감까지 5분 이내</p>}
  </section>;
}

export function DisplayBoard({ initial }: { initial: DisplaySnapshot }) {
  const [snapshot, setSnapshot] = useState(initial);
  const [now, setNow] = useState(initial.serverNow);
  const [failed, setFailed] = useState(false);
  const [denied, setDenied] = useState(false);
  const [fullscreen, setFullscreen] = useState(false);
  const [fullscreenAvailable, setFullscreenAvailable] = useState(false);
  const [fullscreenError, setFullscreenError] = useState("");
  const board = useRef<HTMLElement>(null);
  const requestRefresh = useRef<() => void>(() => {});
  const { missing, submitted } = displayTeams(snapshot.teams);
  const stale = now - snapshot.serverNow > 45_000;
  const startReached = snapshot.vote.status === "scheduled" && Boolean(snapshot.vote.opensAt) && now >= Date.parse(snapshot.vote.opensAt!);

  useEffect(() => {
    let disposed = false;
    let busy = false;
    let activeController: AbortController | undefined;
    let anchor = { server: initial.serverNow, monotonic: performance.now() };
    setSnapshot(initial);
    setNow(initial.serverNow);

    async function refresh() {
      if (busy || document.visibilityState !== "visible") return;
      busy = true;
      const controller = new AbortController();
      activeController = controller;
      const timeout = window.setTimeout(() => controller.abort(), 10_000);
      const result = await loadDisplaySnapshot(controller.signal);
      window.clearTimeout(timeout);
      if (!disposed) {
        if (result.kind === "updated") {
          anchor = { server: result.data.serverNow, monotonic: performance.now() };
          setSnapshot(result.data);
          setNow(result.data.serverNow);
          setFailed(false);
          setDenied(false);
        } else if (result.kind === "denied") {
          setDenied(true);
        } else {
          setFailed(true);
        }
      }
      busy = false;
    }
    const tick = window.setInterval(() => setNow(anchor.server + performance.now() - anchor.monotonic), 1000);
    const polling = window.setInterval(() => void refresh(), 15_000);
    const resume = () => { void refresh(); };
    requestRefresh.current = resume;
    window.addEventListener("focus", resume);
    document.addEventListener("visibilitychange", resume);
    return () => {
      disposed = true;
      activeController?.abort();
      window.clearInterval(tick);
      window.clearInterval(polling);
      window.removeEventListener("focus", resume);
      document.removeEventListener("visibilitychange", resume);
    };
  }, [initial]);

  useEffect(() => {
    if (startReached) requestRefresh.current();
  }, [startReached]);

  useEffect(() => {
    setFullscreenAvailable(Boolean(document.fullscreenEnabled && board.current?.requestFullscreen));
    const update = () => setFullscreen(document.fullscreenElement === board.current);
    document.addEventListener("fullscreenchange", update);
    return () => document.removeEventListener("fullscreenchange", update);
  }, []);

  async function toggleFullscreen() {
    setFullscreenError("");
    try {
      if (document.fullscreenElement === board.current) await document.exitFullscreen();
      else await board.current?.requestFullscreen();
    } catch {
      setFullscreenError("전체 화면으로 전환하지 못했습니다. 브라우저의 전체 화면 기능을 사용해 주세요.");
    }
  }

  return <section ref={board} className={styles.board} aria-label="운영 현황판">
    <header className={styles.header}>
      <div className={styles.identity}>
        <img src="/brand/mark.png" width={64} height={64} alt="" />
        <div><p className={styles.event}>{snapshot.event.name} · {formatEventDate(snapshot.event.date)}</p><h1 className={styles.title}>운영 현황판</h1></div>
      </div>
      <div className={styles.controls}>
        <Button label="지금 갱신" variant="secondary" onClick={() => requestRefresh.current()} />
        {fullscreenAvailable && <Button label={fullscreen ? "전체 화면 닫기" : "전체 화면"} variant="secondary" onClick={() => void toggleFullscreen()} />}
      </div>
    </header>
    {fullscreenError && <p className={styles.warning} role="alert">{fullscreenError}</p>}
    {denied ? <div className={styles.accessError} role="alert">
      <h2>운영진 로그인을 확인해 주세요</h2><p>세션이 만료되었거나 현황판에 접근할 수 없는 계정입니다.</p>
      <Link href="/login">로그인 화면으로 이동</Link>
    </div> : <>
      {(failed || stale) && <p className={styles.warning} role="alert">현황 갱신이 지연되고 있습니다. 마지막으로 확인한 내용이며, 연결이 복구되면 자동으로 갱신합니다.</p>}
      <ManualTimer />
      <div className={styles.timers}>
        <BoardTimer label="발표자료 제출까지" deadline={snapshot.event.submissionDeadline} now={now} primary />
        <div className={styles.vote}>
          <BoardTimer label={snapshot.vote.isRunoff ? "동점 재투표 마감까지" : snapshot.vote.status === "scheduled" ? "투표 시작까지" : "투표 마감까지"} deadline={snapshot.vote.status === "scheduled" ? snapshot.vote.opensAt : snapshot.vote.deadline} now={now} phase={snapshot.vote.status} />
          <p className={styles.voteCount}>{snapshot.vote.status === "draft" ? "투표가 열리면 참여 현황을 표시합니다." : <>{snapshot.vote.isRunoff ? "재투표 참여" : "투표 참여"} <strong>{snapshot.vote.voted}</strong> / {snapshot.vote.eligible}명</>}</p>
        </div>
      </div>
      <section className={styles.summary} aria-labelledby="display-progress">
        <div><h2 id="display-progress">발표자료 제출</h2><p><strong>{submitted.length}</strong><span> / {snapshot.teams.length}팀</span></p></div>
        <div className={styles.progress}>
          <p>{snapshot.teams.length === 0 ? "등록된 팀이 없습니다." : missing.length ? <><strong>{missing.length}팀</strong>의 제출을 기다리고 있습니다.</> : "모든 팀이 제출했습니다."}</p>
          <progress max={Math.max(snapshot.teams.length, 1)} value={submitted.length} aria-label={`전체 ${snapshot.teams.length}팀 중 ${submitted.length}팀 제출`} />
        </div>
      </section>
      <div className={styles.teams}>
        <section className={styles.teamPanel} aria-labelledby="display-missing">
          <header><h2 id="display-missing">미제출 팀</h2><span className={styles.missingCount}>{missing.length}팀</span></header>
          {missing.length ? <ul className={styles.teamList} role="list">{missing.map((team) => <li key={team.id} className={styles.missingTeam}><strong>{team.name}</strong><span>미제출</span></li>)}</ul>
            : <p className={styles.empty}>{snapshot.teams.length ? "미제출 팀이 없습니다." : "팀을 등록하면 제출 현황이 표시됩니다."}</p>}
        </section>
        <section className={styles.teamPanel} aria-labelledby="display-submitted">
          <header><h2 id="display-submitted">제출 완료</h2><span>{submitted.length}팀</span></header>
          {submitted.length ? <ul className={styles.teamList} role="list">{submitted.map((team) => <li key={team.id}><strong>{team.name}</strong><span>완료 · <time dateTime={team.submittedAt!}>{time.format(new Date(team.submittedAt!))}</time></span></li>)}</ul>
            : <p className={styles.empty}>아직 제출한 팀이 없습니다.</p>}
        </section>
      </div>
    </>}
    <footer className={styles.footer}>
      <p>15초마다 갱신 · 마지막 확인 <time dateTime={new Date(snapshot.serverNow).toISOString()}>{time.format(snapshot.serverNow)}</time></p>
      <Link href="/admin/presentations">발표자료 관리로 이동 <span aria-hidden="true">↗</span></Link>
    </footer>
  </section>;
}

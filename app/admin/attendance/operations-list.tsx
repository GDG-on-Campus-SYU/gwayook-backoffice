"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Button } from "@astryxdesign/core/Button";
import { attendanceLabels, gsaLabels, matchesParticipantOperations, type AttendanceStatus, type GsaStatus, type ParticipantOperation } from "@/lib/participant-operations";
import { AttendanceForm, GsaForm, QuickAttendance } from "./forms";
import styles from "./attendance.module.css";

export function OperationsList({ participants }: { participants: ParticipantOperation[] }) {
  const router = useRouter();
  const [refreshing, refresh] = useTransition();
  const [search, setSearch] = useState("");
  const [attendance, setAttendance] = useState<AttendanceStatus | "all">("all");
  const [gsa, setGsa] = useState<GsaStatus | "all">("all");
  const visible = participants.filter((person) => matchesParticipantOperations(person, search, attendance, gsa));
  const arrived = participants.filter((person) => person.attendance_status === "present" || person.attendance_status === "late").length;
  const verified = participants.filter((person) => person.gsa_status === "verified").length;

  return <section className="panel stack" aria-labelledby="operations-heading">
    <div className={styles.header}>
      <div className="stack compact"><h2 id="operations-heading">참가자 현장 확인</h2><p className="muted">전체 {participants.length}명 · 출석·지각 {arrived}명 · GSA 확인 완료 {verified}명</p></div>
      <Button type="button" label="목록 새로고침" variant="secondary" isLoading={refreshing} isDisabled={refreshing} onClick={() => refresh(() => router.refresh())} />
    </div>
    <div className={styles.filters}>
      <label className="field">참가자 검색<input type="search" value={search} maxLength={100} onChange={(event) => setSearch(event.target.value)} placeholder="이름, 이메일, 학교 또는 팀명" /></label>
      <label className="field">출석 필터<select value={attendance} onChange={(event) => setAttendance(event.target.value as AttendanceStatus | "all")}><option value="all">출석 전체</option>{Object.entries(attendanceLabels).map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></label>
      <label className="field">GSA 필터<select value={gsa} onChange={(event) => setGsa(event.target.value as GsaStatus | "all")}><option value="all">GSA 전체</option>{Object.entries(gsaLabels).map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></label>
    </div>
    <div className={styles.header}>
      <p className="muted" role="status">{visible.length}명 표시</p>
      {(search || attendance !== "all" || gsa !== "all") && <button className={styles.refresh} type="button" onClick={() => { setSearch("");setAttendance("all");setGsa("all"); }}>검색·필터 초기화</button>}
    </div>
    <p className="muted">미확인 참가자는 ‘출석 확인’으로 바로 체크인합니다. 지각·불참 정정과 GSA 확인은 각 참가자의 ‘상세 기록 수정’에서 따로 저장합니다. 다른 운영진의 기록을 보려면 목록을 새로고침해 주세요.</p>
    {visible.length ? <ul className={styles.list}>
      {visible.map((person) => <li key={person.member_id} className={`stack ${styles.person}`}>
        <div className={styles.personHeader}>
          <div className={`stack compact ${styles.identity}`}><h3>{person.name} <span className="muted">· {person.team_name ?? "미배정"}{!person.active && " · 비활성 계정"}</span></h3><p className="muted">학교 · {person.school ?? "미등록"}</p><p className="muted">로그인 · {person.email}</p></div>
          <QuickAttendance person={person} />
        </div>
        <div className={styles.statuses}><span className="status-tag">출석 · {attendanceLabels[person.attendance_status]}</span><span className="status-tag">GSA · {gsaLabels[person.gsa_status]}</span></div>
        <details><summary>{person.name} 상세 기록 수정</summary><div className={styles.editors}><AttendanceForm person={person} /><GsaForm person={person} /></div></details>
      </li>)}
    </ul> : <p className="notice">{participants.length ? "검색·필터에 맞는 참가자가 없습니다." : "등록된 참가자가 없습니다. 참가자·팀에서 명단을 먼저 등록해 주세요."}</p>}
  </section>;
}

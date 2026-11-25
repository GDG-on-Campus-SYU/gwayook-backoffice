"use client";

import { useState } from "react";
import Link from "next/link";
import type { Participant, Team } from "./editors";
import styles from "./members.module.css";

function GoogleStatus({ linked }: { linked: boolean }) {
  return <span className={`${styles.status} ${linked ? styles.linked : ""}`}>{linked ? "연결됨" : "미연결"}</span>;
}

export function ParticipantTable({ participants, teams }: { participants: Participant[]; teams: Team[] }) {
  const [search, setSearch] = useState("");
  const [schoolFilter, setSchoolFilter] = useState("");
  const schools = [...new Set(participants.flatMap((person) => person.school ? [person.school] : []))].sort((a, b) => a.localeCompare(b, "ko"));
  const query = search.trim().toLocaleLowerCase();
  const teamsById = new Map(teams.map((team) => [team.id, team]));
  const visibleParticipants = participants.filter((person) => {
    const team = person.team_id ? teamsById.get(person.team_id) : undefined;
    return (!schoolFilter || schoolFilter === (person.school ? `school:${person.school}` : "unregistered")) &&
      [person.name, person.email, person.school, team?.name].some((value) => value?.toLocaleLowerCase().includes(query));
  });

  return (
    <>
      {participants.length > 0 && (
        <div className={styles.filters}>
          <label className={`field ${styles.search}`}>
            참가자 검색
            <input
              type="search"
              placeholder="이름, 이메일, 학교 또는 팀명"
              value={search}
              onChange={(event) => setSearch(event.target.value)}
              maxLength={100}
            />
          </label>
          <label className="field">
            학교 필터
            <select value={schoolFilter} onChange={(event) => setSchoolFilter(event.target.value)}>
              <option value="">학교 전체</option>
              <option value="unregistered">학교 미등록</option>
              {schools.map((school) => <option key={school} value={`school:${school}`}>{school}</option>)}
            </select>
          </label>
        </div>
      )}
      {participants.length > 0 && <p className="muted" role="status">{visibleParticipants.length}명 표시</p>}
      {visibleParticipants.length > 0 ? (
        <div className={`table-wrap ${styles.participantTable}`} tabIndex={0} role="region" aria-label="참가자 명단 표">
          <p className="table-scroll-hint">표가 잘리면 좌우로 밀어 확인하세요.</p>
          <table aria-label="참가자 명단">
            <thead>
              <tr>
                <th scope="col">이름</th>
                <th scope="col">로그인 이메일</th>
                <th scope="col" className={styles.desktopColumn}>학교</th>
                <th scope="col" className={styles.desktopColumn}>Google 계정</th>
                <th scope="col" className={styles.desktopColumn}>팀</th>
                <th scope="col" className={styles.desktopColumn}>상태</th>
                <th scope="col">관리</th>
              </tr>
            </thead>
            <tbody>
              {visibleParticipants.map((person) => {
                const team = person.team_id ? teamsById.get(person.team_id) : undefined;
                const teamLabel = `${team?.name ?? "미배정"}${team?.representative_id === person.id ? " · 대표자" : ""}`;
                const stateLabel = person.active ? "활성" : "비활성";
                return (
                  <tr key={person.id}>
                    <th scope="row">
                      {person.name}
                      <span className={styles.mobileMeta}>{person.school ?? "학교 미등록"}</span>
                      <span className={styles.mobileMeta}>{teamLabel} · {stateLabel}</span>
                    </th>
                    <td>
                      {person.email}
                      <span className={styles.mobileMeta}>Google <GoogleStatus linked={person.googleLinked} /></span>
                    </td>
                    <td className={styles.desktopColumn}>{person.school ?? "미등록"}</td>
                    <td className={styles.desktopColumn}><GoogleStatus linked={person.googleLinked} /></td>
                    <td className={styles.desktopColumn}>{teamLabel}</td>
                    <td className={styles.desktopColumn}>{stateLabel}</td>
                    <td>
                      <Link className={styles.editLink} href={`/admin/members?person=${person.id}#person-editor`} aria-label={`${person.name} 참가자 수정`}>
                        수정
                      </Link>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      ) : (
        <p className="muted" role="status">
          {query || schoolFilter ? "검색·학교 필터에 맞는 참가자가 없습니다." : "등록된 참가자가 없습니다."}
        </p>
      )}
    </>
  );
}

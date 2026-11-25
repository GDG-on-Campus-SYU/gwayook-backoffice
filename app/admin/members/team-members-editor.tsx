"use client";

import { useActionState, useId, useState } from "react";
import { Button } from "@astryxdesign/core/Button";
import type { TeamAssignmentMember } from "@/lib/team-assignment";
import { assignTeamMembers, removeTeamMembers, type SaveState } from "./actions";
import type { Participant, Team } from "./editors";
import styles from "./members.module.css";

export function TeamMembersEditor({ team, teams, participants }: { team: Team; teams: Team[]; participants: Participant[] }) {
  const [query, setQuery] = useState("");
  const [selected, setSelected] = useState<TeamAssignmentMember[]>([]);
  const [confirmed, setConfirmed] = useState(false);
  const feedbackId = useId();
  const [state, formAction, pending] = useActionState(async (previous: SaveState, form: FormData) => {
    const result = await assignTeamMembers(previous, form);
    if (result.status === "saved") {
      setSelected([]);
      setConfirmed(false);
    }
    return result;
  }, { status: "idle", message: "" });
  const teamsById = new Map(teams.map((item) => [item.id, item]));
  const selectedIds = new Set(selected.map((person) => person.id));
  const selectedPeople = participants.filter((person) => selectedIds.has(person.id));
  const movingCount = selected.filter((person) => person.expected_team_id !== null && person.expected_team_id !== team.id).length;
  const search = query.trim().toLocaleLowerCase();
  const visible = participants.filter((person) => [person.name, person.email, person.school].some((value) => value?.toLocaleLowerCase().includes(search)));

  function toggle(person: Participant) {
    setSelected((previous) => previous.some((item) => item.id === person.id)
      ? previous.filter((item) => item.id !== person.id)
      : [...previous, { id: person.id, expected_team_id: person.team_id }]);
    setConfirmed(false);
  }

  return (
    <section id="team-members-editor" className={`${styles.teamMembers} stack`} aria-labelledby="team-members-heading" tabIndex={-1}>
      <div className="stack compact">
        <h4 id="team-members-heading">{team.name}에 참가자 추가</h4>
        <p className="muted">이름이나 학교로 검색해 여러 명을 선택하세요. 동명이인은 학교·이메일과 현재 팀으로 구분할 수 있습니다.</p>
      </div>
      <form action={formAction} className="stack" aria-label={`${team.name} 참가자 일괄 추가`} aria-describedby={state.message ? feedbackId : undefined}>
        <input type="hidden" name="team_id" value={team.id} />
        <input type="hidden" name="members" value={JSON.stringify(selected)} />
        <fieldset disabled={pending} className={`${styles.assignmentFields} stack`}>
          <legend className={styles.assignmentLegend}>추가할 참가자 선택</legend>
          <label className={`field ${styles.search}`}>
            이름·학교·이메일 검색
            <input type="search" value={query} onChange={(event) => setQuery(event.target.value)} placeholder="이름, 학교 또는 로그인 이메일" maxLength={100} />
          </label>
          <p className="muted" role="status">검색 결과 {visible.length}명 · 선택 {selected.length}명</p>
          {visible.length ? (
            <ul className={styles.assignmentList} aria-label="참가자 검색 결과">
              {visible.map((person) => {
                const currentTeam = person.team_id ? teamsById.get(person.team_id) : undefined;
                const blocked = !person.active ? "비활성 참가자" : person.team_id === team.id ? "이미 소속됨"
                  : currentTeam?.representative_id === person.id ? "다른 팀 대표자 · 대표자 재설정 필요" : "";
                return (
                  <li key={person.id}>
                    <label className={styles.assignmentPerson} data-disabled={Boolean(blocked)}>
                      <input type="checkbox" checked={selectedIds.has(person.id)} disabled={Boolean(blocked) || (!selectedIds.has(person.id) && selected.length >= 200)} onChange={() => toggle(person)} />
                      <span className={styles.assignmentIdentity}>
                        <strong>{person.name}</strong>
                        <span>{person.school ?? "학교 미등록"}</span>
                        <span>{person.email}</span>
                        <span>현재 팀: {currentTeam?.name ?? "미배정"}{blocked ? ` · ${blocked}` : ""}</span>
                      </span>
                    </label>
                  </li>
                );
              })}
            </ul>
          ) : <p className="muted">검색 조건에 맞는 참가자가 없습니다.</p>}
          {selectedPeople.length > 0 && (
            <div className={`${styles.assignmentSelection} stack compact`}>
              <h5>선택한 참가자 {selected.length}명</h5>
              <ul className={styles.selectionList} aria-label="선택한 참가자">
                {selectedPeople.map((person) => (
                  <li key={person.id}>
                    <span><strong>{person.name}</strong> · {person.school ?? "학교 미등록"} · {person.email}<br />{person.team_id ? teamsById.get(person.team_id)?.name : "미배정"} → {team.name}</span>
                    <button type="button" onClick={() => toggle(person)} aria-label={`${person.name} ${person.email} 선택 해제`}>해제</button>
                  </li>
                ))}
              </ul>
            </div>
          )}
          {movingCount > 0 && (
            <label className={styles.confirmation}>
              <input type="checkbox" name="confirm_move" checked={confirmed} onChange={(event) => setConfirmed(event.target.checked)} required />
              <span>다른 팀에 소속된 {movingCount}명을 기존 팀에서 빼고 {team.name}으로 이동합니다.</span>
            </label>
          )}
          <div className="action-row">
            <Button type="submit" variant="primary" label={`선택한 ${selected.length}명 추가`} isLoading={pending} isDisabled={pending || selected.length === 0 || (movingCount > 0 && !confirmed)} />
          </div>
        </fieldset>
        {state.message && <p id={feedbackId} className={styles.feedback} role={state.status === "error" ? "alert" : "status"}>{state.message}</p>}
      </form>
    </section>
  );
}

export function TeamMembersRemoval({ team, participants }: { team: Team; participants: Participant[] }) {
  const [selected, setSelected] = useState<TeamAssignmentMember[]>([]);
  const [confirmedRepresentativeId, setConfirmedRepresentativeId] = useState<string | null>(null);
  const feedbackId = useId();
  const [state, formAction, pending] = useActionState(async (previous: SaveState, form: FormData) => {
    const result = await removeTeamMembers(previous, form);
    if (result.status === "saved") { setSelected([]); setConfirmedRepresentativeId(null); }
    return result;
  }, { status: "idle", message: "" });
  const currentMembers = participants.filter((person) => person.team_id === team.id);
  const selectedIds = new Set(selected.map((person) => person.id));
  const removesRepresentative = Boolean(team.representative_id && selectedIds.has(team.representative_id));
  const confirmed = team.representative_id !== null && confirmedRepresentativeId === team.representative_id;

  return <section id="team-members-removal" className={`${styles.teamMembers} stack`} aria-labelledby="team-removal-heading" tabIndex={-1}>
    <div className="stack compact">
      <h4 id="team-removal-heading">{team.name}에서 팀원 제거</h4>
      <p className="muted">선택한 팀원은 미배정으로 바뀝니다. 참가자 계정과 활동 기록은 유지되며 다른 팀에 다시 배정할 수 있습니다. 이미 확정된 투표 명단은 바뀌지 않습니다.</p>
    </div>
    <form action={formAction} className="stack" aria-label={`${team.name} 팀원 제거`} aria-describedby={state.message ? feedbackId : undefined}>
      <input type="hidden" name="team_id" value={team.id} />
      <input type="hidden" name="members" value={JSON.stringify(selected)} />
      <input type="hidden" name="expected_representative_id" value={team.representative_id ?? ""} />
      <fieldset disabled={pending} className={`${styles.assignmentFields} stack`}>
        <legend className={styles.assignmentLegend}>제거할 팀원 선택</legend>
        {currentMembers.length ? <ul className={styles.assignmentList} aria-label="현재 팀원">
          {currentMembers.map((person) => <li key={person.id}>
            <label className={styles.assignmentPerson}>
              <input type="checkbox" checked={selectedIds.has(person.id)} disabled={!selectedIds.has(person.id) && selected.length >= 200} onChange={() => {
                setSelected((previous) => previous.some((item) => item.id === person.id)
                  ? previous.filter((item) => item.id !== person.id)
                  : [...previous, { id: person.id, expected_team_id: person.team_id }]);
                setConfirmedRepresentativeId(null);
              }} />
              <span className={styles.assignmentIdentity}><strong>{person.name}{person.id === team.representative_id ? " · 대표자" : ""}</strong><span>{person.school ?? "학교 미등록"}</span><span>{person.email}{person.active ? "" : " · 비활성"}</span></span>
            </label>
          </li>)}
        </ul> : <p className="muted">이 팀에 배정된 참가자가 없습니다.</p>}
        {removesRepresentative && <label className={styles.confirmation}>
          <input type="checkbox" name="confirm_representative" checked={confirmed} onChange={(event) => setConfirmedRepresentativeId(event.target.checked ? team.representative_id : null)} required />
          <span>선택한 대표자를 팀에서 제거하고 대표자 지정도 해제합니다. 새 대표자는 별도로 지정해야 합니다.</span>
        </label>}
        <div className="action-row">
          <Button type="submit" variant="secondary" label={`선택한 ${selected.length}명 팀에서 제거`} isLoading={pending} isDisabled={pending || selected.length === 0 || (removesRepresentative && !confirmed)} />
        </div>
      </fieldset>
      {state.message && <p id={feedbackId} className={styles.feedback} role={state.status === "error" ? "alert" : "status"}>{state.message}</p>}
    </form>
  </section>;
}

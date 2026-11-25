"use client";

import { useActionState, useId, useState } from "react";
import { Button } from "@astryxdesign/core/Button";
import { saveRoster, type SaveState } from "./actions";
import styles from "./members.module.css";

export type Team = {
  id: string;
  name: string;
  presentation_order: number | null;
  representative_id: string | null;
};

export type Participant = {
  id: string;
  name: string;
  email: string;
  school: string | null;
  team_id: string | null;
  active: boolean;
  googleLinked: boolean;
};

const initialState: SaveState = { status: "idle", message: "" };

function Feedback({ state, id }: { state: SaveState; id?: string }) {
  if (!state.message) return null;
  return <p id={id} className={styles.feedback} role={state.status === "error" ? "alert" : "status"}>{state.message}</p>;
}

export function AddParticipantForm({ teams }: { teams: Team[] }) {
  const [name, setName] = useState("");
  const [email, setEmail] = useState("");
  const [school, setSchool] = useState("");
  const [teamId, setTeamId] = useState("");
  const feedbackId = useId();
  const [state, formAction, pending] = useActionState(async (previous: SaveState, form: FormData) => {
    const result = await saveRoster("create_member", previous, form);
    if (result.status === "saved") {
      setName("");
      setEmail("");
      setSchool("");
      setTeamId("");
    }
    return result;
  }, initialState);

  return (
    <form className="stack" action={formAction} aria-label="참가자 수동 추가">
      <div className={styles.addFields}>
        <label className="field">
          이름
          <input
            name="name" value={name} onChange={(event) => setName(event.target.value)} required maxLength={100}
            aria-invalid={state.field === "name" || undefined}
            aria-describedby={state.field === "name" ? feedbackId : undefined}
          />
        </label>
        <label className="field">
          로그인용 Google 이메일
          <input
            name="email" type="email" value={email} onChange={(event) => setEmail(event.target.value)} required maxLength={254}
            autoComplete="off" spellCheck={false}
            aria-invalid={state.field === "email" || undefined}
            aria-describedby={state.field === "email" ? feedbackId : undefined}
          />
        </label>
        <label className="field">
          학교 (선택)
          <input name="school" list={`${feedbackId}-schools`} value={school} onChange={(event) => setSchool(event.target.value)} maxLength={100}
            placeholder="학교 선택 또는 직접 입력" autoComplete="off"
            aria-invalid={state.field === "school" || undefined} aria-describedby={state.field === "school" ? feedbackId : undefined} />
          <datalist id={`${feedbackId}-schools`}><option value="서울과학기술대학교" /><option value="삼육대학교" /></datalist>
        </label>
        <label className="field">
          소속 팀 (선택)
          <select
            name="team_id" value={teamId} onChange={(event) => setTeamId(event.target.value)}
            aria-invalid={state.field === "team_id" || undefined}
            aria-describedby={state.field === "team_id" ? feedbackId : undefined}
          >
            <option value="">미배정</option>
            {teams.map((team) => <option key={team.id} value={team.id}>{team.name}</option>)}
          </select>
        </label>
      </div>
      <p className="muted">학교를 모르면 비워 두세요. 학교 정보는 운영진의 명단·현장 확인에 사용합니다.</p>
      <div className="action-row">
        <Button type="submit" variant="primary" label="참가자 추가" isLoading={pending} isDisabled={pending} />
      </div>
      <Feedback id={feedbackId} state={state} />
    </form>
  );
}

export function ParticipantEmailEditor({ person }: { person: Participant }) {
  const [expectedEmail, setExpectedEmail] = useState(person.email);
  const [email, setEmail] = useState("");
  const [confirmed, setConfirmed] = useState(false);
  const feedbackId = useId();
  const [state, formAction, pending] = useActionState(async (previous: SaveState, form: FormData) => {
    const result = await saveRoster("update_member_email", previous, form);
    if (result.status === "saved") {
      setExpectedEmail(String(form.get("email")).trim().toLowerCase());
      setEmail("");
      setConfirmed(false);
    }
    return result;
  }, initialState);

  return (
    <form className="stack" action={formAction} aria-label="로그인 이메일 정정">
      <input type="hidden" name="id" value={person.id} />
      <input type="hidden" name="expected_email" value={expectedEmail} />
      <p className={styles.currentEmail}>현재 이메일 <strong>{expectedEmail}</strong></p>
      <label className="field">
        새 로그인용 Google 이메일
        <input
          name="email" type="email" value={email} onChange={(event) => setEmail(event.target.value)} required maxLength={254}
          autoComplete="off" spellCheck={false}
          aria-invalid={state.field === "email" || undefined}
          aria-describedby={state.field === "email" ? feedbackId : undefined}
        />
      </label>
      {person.googleLinked && (
        <label className={styles.confirmation}>
          <input
            type="checkbox" name="confirm_disconnect" required={email.trim().toLowerCase() !== expectedEmail} checked={confirmed}
            onChange={(event) => setConfirmed(event.target.checked)}
          />
          <span>기존 Google 계정의 연결을 해제합니다. 참가자는 새 주소로 다시 로그인해야 합니다.</span>
        </label>
      )}
      <div className="action-row">
        <Button type="submit" variant="primary" label="이메일 정정 저장" isLoading={pending} isDisabled={pending} />
      </div>
      <Feedback id={feedbackId} state={state} />
    </form>
  );
}

export function TeamEditor({ team }: { team?: Team }) {
  const [name, setName] = useState(team?.name ?? "");
  const [order, setOrder] = useState(team?.presentation_order?.toString() ?? "");
  const [state, formAction, pending] = useActionState(async (previous: SaveState, form: FormData) => {
    const result = await saveRoster(team ? "update_team" : "create_team", previous, form);
    if (!team && result.status === "saved") {
      setName("");
      setOrder("");
    }
    return result;
  }, initialState);

  return (
    <form className="stack" action={formAction} aria-label={team ? "팀 정보 수정" : "팀 추가"}>
      {team && <input type="hidden" name="id" value={team.id} />}
      <label className="field">
        팀명
        <input name="name" value={name} onChange={(event) => setName(event.target.value)} maxLength={100} required />
      </label>
      <label className="field">
        발표 순서 (선택)
        <input
          name="presentation_order"
          type="number"
          min={1}
          max={200}
          step={1}
          value={order}
          onChange={(event) => setOrder(event.target.value)}
        />
      </label>
      <div className="action-row">
        <Button type="submit" variant="primary" label={team ? "팀 정보 저장" : "팀 추가"} isLoading={pending} />
      </div>
      <Feedback state={state} />
    </form>
  );
}

export function RepresentativeEditor({ team, eligible }: { team: Team; eligible: Participant[] }) {
  const [representative, setRepresentative] = useState(team.representative_id ?? "");
  const [state, formAction, pending] = useActionState(saveRoster.bind(null, "set_representative"), initialState);

  return (
    <form className="stack" action={formAction} aria-label="대표자 지정">
      <input type="hidden" name="id" value={team.id} />
      <label className="field">
        팀 대표자
        <select
          name="representative_id"
          value={representative}
          onChange={(event) => setRepresentative(event.target.value)}
        >
          <option value="">미지정</option>
          {eligible.map((person) => (
            <option key={person.id} value={person.id}>{person.name} · {person.email}</option>
          ))}
        </select>
      </label>
      {eligible.length === 0 && <p className="muted">팀에 활성 참가자를 배정하면 대표자를 지정할 수 있습니다.</p>}
      <div className="action-row">
        <Button
          type="submit"
          label="대표자 저장"
          isLoading={pending}
          isDisabled={representative === (team.representative_id ?? "")}
        />
      </div>
      <Feedback state={state} />
    </form>
  );
}

export function ParticipantEditor({ person, teams }: { person: Participant; teams: Team[] }) {
  const [name, setName] = useState(person.name);
  const [school, setSchool] = useState(person.school ?? "");
  const feedbackId = useId();
  const [teamId, setTeamId] = useState(person.team_id ?? "");
  const [active, setActive] = useState(person.active);
  const [state, formAction, pending] = useActionState(saveRoster.bind(null, "update_member"), initialState);
  const currentTeam = teams.find((team) => team.id === person.team_id);
  const clearsRepresentative = currentTeam?.representative_id === person.id && (!active || teamId !== person.team_id);

  return (
    <form className="stack" action={formAction} aria-label="참가자 수정">
      <input type="hidden" name="id" value={person.id} />
      <label className="field">
        참가자 이름
        <input name="name" value={name} onChange={(event) => setName(event.target.value)} maxLength={100} required />
      </label>
      <label className="field">
        학교 (선택)
        <input name="school" list={`${feedbackId}-schools`} value={school} onChange={(event) => setSchool(event.target.value)} maxLength={100}
          placeholder="학교 선택 또는 직접 입력" autoComplete="off"
          aria-invalid={state.field === "school" || undefined} aria-describedby={state.field === "school" ? feedbackId : `${feedbackId}-school-help`} />
        <datalist id={`${feedbackId}-schools`}><option value="서울과학기술대학교" /><option value="삼육대학교" /></datalist>
        <span id={`${feedbackId}-school-help`} className="muted">비우고 저장하면 학교 정보가 미등록으로 변경됩니다.</span>
      </label>
      <label className="field">
        소속 팀
        <select name="team_id" value={teamId} onChange={(event) => setTeamId(event.target.value)}>
          <option value="">미배정</option>
          {teams.map((team) => <option key={team.id} value={team.id}>{team.name}</option>)}
        </select>
      </label>
      <label className="field">
        참가 상태
        <select name="active" value={String(active)} onChange={(event) => setActive(event.target.value === "true")}>
          <option value="true">활성</option>
          <option value="false">비활성</option>
        </select>
      </label>
      {clearsRepresentative && <p>저장하면 기존 팀의 대표자 지정도 해제됩니다.</p>}
      <div className="action-row">
        <Button type="submit" variant="primary" label="참가자 정보 저장" isLoading={pending} />
      </div>
      <Feedback id={feedbackId} state={state} />
    </form>
  );
}

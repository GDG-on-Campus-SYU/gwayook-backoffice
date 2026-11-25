import Link from "next/link";
import { Button } from "@astryxdesign/core/Button";
import { requireStaff } from "@/lib/auth";
import {
  AddParticipantForm, ParticipantEditor, ParticipantEmailEditor, RepresentativeEditor, TeamEditor,
  type Participant, type Team,
} from "./editors";
import { ParticipantTable } from "./participant-table";
import { TeamMembersEditor, TeamMembersRemoval } from "./team-members-editor";
import styles from "./members.module.css";

export const metadata = { title: "참가자·팀" };

type Query = { person?: string | string[]; team?: string | string[] };

export default async function MembersPage({ searchParams }: { searchParams: Promise<Query> }) {
  const [{ supabase, member }, params] = await Promise.all([requireStaff(), searchParams]);
  const [membersResult, teamsResult] = await Promise.all([
    supabase.rpc("get_staff_members", { p_scope: "participants" }),
    supabase.from("teams").select("id, name, presentation_order, representative_id")
      .order("presentation_order", { nullsFirst: false }).order("name"),
  ]);

  if (membersResult.error || teamsResult.error) {
    return (
      <div className="stack">
        <h1>참가자·팀</h1>
        <p role="alert">명단을 불러오지 못했습니다. 화면을 새로고침해 다시 시도해 주세요.</p>
      </div>
    );
  }

  const participants: Participant[] = ((membersResult.data ?? []) as (Omit<Participant, "googleLinked"> & { auth_user_id: string | null })[]).map(({ auth_user_id, ...person }) => ({
    ...person, googleLinked: Boolean(auth_user_id),
  }));
  const teams: Team[] = teamsResult.data ?? [];
  const selectedPerson = participants.find((person) => person.id === params.person);
  const selectedTeam = teams.find((team) => team.id === params.team);
  const peopleById = new Map(participants.map((person) => [person.id, person]));

  return (
    <div className="stack">
      <header className={styles.pageHeader}>
        <div className="stack compact">
          <h1>참가자·팀</h1>
          <p className="muted">참가자 명단과 Google 계정 연결, 팀 대표자를 관리합니다.</p>
        </div>
        <div className="action-row">
          <Button label="출석·GSA" href="/admin/attendance" variant="secondary" />
          <Button label="엑셀 가져오기" href="/admin/import" variant="secondary" />
          <Button label="참가자 수동 추가" href="#add-participant" variant="primary" />
        </div>
      </header>

      <section className="panel stack" aria-labelledby="participants-heading">
        <div className={styles.listHeader}>
          <h2 id="participants-heading">참가자 명단</h2>
          <p className="muted">총 {participants.length}명</p>
        </div>
        <ParticipantTable participants={participants} teams={teams} />
        {selectedPerson && (
          <section id="person-editor" className={`${styles.personEditor} stack`} aria-labelledby="person-editor-heading" tabIndex={-1}>
            <div className={styles.listHeader}>
              <h3 id="person-editor-heading">{selectedPerson.name} 수정</h3>
              <Link className="text-link" href="/admin/members#participants-heading">수정 닫기</Link>
            </div>
            <div className={styles.editFields}>
              <ParticipantEditor key={selectedPerson.id} person={selectedPerson} teams={teams} />
              <section className="stack" aria-labelledby="email-editor-heading">
                <h4 id="email-editor-heading" className={styles.editorHeading}>로그인 이메일 정정</h4>
                {selectedPerson.googleLinked && member.role !== "owner" ? (
                  <p className="muted">연결된 참가자의 이메일 정정은 총관리자에게 요청해 주세요.</p>
                ) : (
                  <ParticipantEmailEditor key={selectedPerson.id} person={selectedPerson} />
                )}
              </section>
            </div>
          </section>
        )}
      </section>

      <section id="add-participant" className="panel stack" aria-labelledby="add-participant-heading" tabIndex={-1}>
        <div className="stack compact">
          <h2 id="add-participant-heading">참가자 수동 추가</h2>
          <p className="muted">참가자가 Google 로그인에 사용할 주소를 입력해 주세요.</p>
        </div>
        <AddParticipantForm teams={teams} />
      </section>

      <section className="panel stack" aria-labelledby="teams-heading">
        <h2 id="teams-heading">팀과 대표자</h2>
        {teams.length > 0 ? (
          <div className="table-wrap" tabIndex={0} role="region" aria-label="팀과 대표자 명단 표">
            <p className="table-scroll-hint">표가 잘리면 좌우로 밀어 확인하세요.</p>
            <table aria-label="팀과 대표자 명단">
              <thead>
                <tr>
                  <th scope="col">팀</th>
                  <th scope="col">발표 순서</th>
                  <th scope="col">대표자</th>
                  <th scope="col">관리</th>
                </tr>
              </thead>
              <tbody>
                {teams.map((team) => (
                  <tr key={team.id}>
                    <th scope="row">{team.name}</th>
                    <td>{team.presentation_order ?? "미정"}</td>
                    <td>{(team.representative_id && peopleById.get(team.representative_id)?.name) || "미지정"}</td>
                    <td>
                      <div className="action-row">
                        <Link className="text-link" href={`/admin/members?team=${team.id}#team-editor`} aria-label={`${team.name} 팀과 대표자 수정`}>수정</Link>
                        <Link className="text-link" href={`/admin/members?team=${team.id}#team-members-editor`} aria-label={`${team.name}에 참가자 추가`}>참가자 추가</Link>
                        <Link className="text-link" href={`/admin/members?team=${team.id}#team-members-removal`} aria-label={`${team.name}에서 팀원 제거`}>팀원 제거</Link>
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <p className="muted">등록된 팀이 없습니다. 명단을 가져오거나 팀을 직접 추가할 수 있습니다.</p>
        )}
        {selectedTeam && (
          <section id="team-editor" className="stack" aria-labelledby="team-editor-heading" tabIndex={-1}>
            <h3 id="team-editor-heading">{selectedTeam.name} 수정</h3>
            <TeamEditor key={selectedTeam.id} team={selectedTeam} />
            <RepresentativeEditor
              key={selectedTeam.id}
              team={selectedTeam}
              eligible={participants.filter((person) => person.active && person.team_id === selectedTeam.id)}
            />
            <TeamMembersEditor key={`members-${selectedTeam.id}`} team={selectedTeam} teams={teams} participants={participants} />
            <TeamMembersRemoval key={`removal-${selectedTeam.id}`} team={selectedTeam} participants={participants} />
          </section>
        )}
        <details>
          <summary>새 팀 등록</summary>
          <TeamEditor />
        </details>
      </section>
    </div>
  );
}

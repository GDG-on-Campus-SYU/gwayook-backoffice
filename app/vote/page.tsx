import { requireMember } from "@/lib/auth";
import { Header } from "../ui";
import { Ballot } from "./ballot";
import type { Runoff, VoteDetails } from "./data";
import { Results, RunoffResults } from "./results";
import { DeadlineCountdown } from "../deadline-countdown";
import { listPresentations } from "../presentations/data";

export const metadata = { title: "투표" };

function MainVoteContent({ vote }: { vote: VoteDetails }) {
  switch (vote.status) {
    case "published":
      return <><Results results={vote.results} /><RunoffResults rounds={vote.runoff_history} /></>;
    case "draft":
      return <p className="panel">투표 준비 중입니다. 유권자 명단을 확정하기 전에 현장에서 체크인하고 소속 팀을 확인해 주세요.</p>;
    case "scheduled":
      return <p className="panel">예약된 시각에 자동으로 투표가 열립니다. 시작 전에는 투표할 수 없습니다.</p>;
    case "open":
      if (!vote.eligible) {
        return <p className="panel">이번 투표의 유권자 명단에 포함되어 있지 않습니다. 명단을 확정하기 전에 현장 체크인과 팀 배정을 마쳤다면 운영진에게 알려 주세요.</p>;
      }
      return <Ballot key={vote.choice_id ?? "new"} candidates={vote.candidates} ownTeamId={vote.own_team_id} choiceId={vote.choice_id} />;
    default:
      return <p className="panel">투표 시간이 끝났습니다. 결과가 공개되면 이 화면에서 확인할 수 있습니다.</p>;
  }
}

function RunoffVoteContent({ runoff }: { runoff: Runoff }) {
  if (runoff.status !== "open") {
    return <p className="panel">재투표 시간이 끝났습니다. 최종 결과 공개를 기다려 주세요.</p>;
  }
  if (!runoff.eligible) {
    return <p className="panel">이번 재투표 대상이 아닙니다. 동점 후보팀 소속 참가자는 재투표에 참여하지 않습니다.</p>;
  }
  return <Ballot key={`${runoff.id}:${runoff.choice_id ?? "new"}`} candidates={runoff.candidates} ownTeamId={null} choiceId={runoff.choice_id} runoffId={runoff.id} />;
}

export default async function VotePage() {
  const { supabase, member } = await requireMember();
  const [{ data, error }, teams] = await Promise.all([
    supabase.rpc("get_vote_details"), listPresentations(supabase),
  ]);
  if (error || !data) throw new Error("Could not load the vote");
  const vote = data as VoteDetails;
  const runoff = vote.status !== "published" ? vote.runoff : null;

  return <>
    <Header admin={member.role !== "participant"} />
    <main id="participant-main" tabIndex={-1} className="content stack">
      <header className="stack compact">
        <h1>{runoff ? "동점 재투표" : "수상 투표"}</h1>
        <p className="muted">{runoff ? "본투표 유권자 중 동점 후보팀 소속을 제외하고 참여합니다. 본투표 때의 소속 팀을 기준으로 합니다." : "우리 팀을 제외한 한 팀에 투표하세요."} 선택한 팀은 본인만 볼 수 있습니다.</p>
        <a className="text-link" href="#vote-presentations">팀별 발표자료 보기</a>
      </header>
      <DeadlineCountdown label={runoff ? "재투표 마감" : "투표 마감"} deadline={runoff?.closes_at ?? vote.closes_at} opensAt={runoff?.opens_at ?? vote.opens_at} state={runoff?.status ?? vote.status} serverNow={Date.now()} />

      {vote.voted && vote.status === "open" && <p className="notice" role="status">투표를 완료했습니다.</p>}
      {runoff?.voted && <p className="notice" role="status">재투표를 완료했습니다.</p>}
      {runoff ? <RunoffVoteContent runoff={runoff} /> : <MainVoteContent vote={vote} />}
      <section className="panel stack" aria-labelledby="vote-presentations">
        <h2 id="vote-presentations">팀별 발표자료</h2>
        <p className="muted">각 팀의 최종 발표자료를 확인할 수 있습니다. 자료는 새 탭에서 열립니다.</p>
        {teams.length ? <div className="table-wrap" tabIndex={0} role="region" aria-label="팀별 발표자료 표">
          <p className="table-scroll-hint">표가 잘리면 좌우로 밀어 확인하세요.</p>
          <table>
            <thead><tr><th scope="col">순서</th><th scope="col">팀</th><th scope="col">발표자료</th></tr></thead>
            <tbody>{teams.map((team) => <tr key={team.id}>
              <td>{team.presentation_order ?? "미정"}</td>
              <th scope="row">{team.name}</th>
              <td>{team.submission ? <div className="stack compact">
                <span>{team.submission.file_name}</span>
                <div className="action-row">
                  <a className="text-link" href={`/presentations/${team.id}/download?view=1`} target="_blank" rel="noreferrer" aria-label={`${team.name} ${team.submission.file_name} 열기 (새 탭)`}>열기 (새 탭)</a>
                  <a className="text-link" href={`/presentations/${team.id}/download`} aria-label={`${team.name} ${team.submission.file_name} 다운로드`}>다운로드</a>
                </div>
              </div> : <span className="muted">공유된 자료 없음</span>}</td>
            </tr>)}</tbody>
          </table>
        </div> : <p className="muted">등록된 팀이 없습니다.</p>}
      </section>
    </main>
  </>;
}

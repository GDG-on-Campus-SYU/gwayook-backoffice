import type { Runoff, VoteResult } from "./data";

export function Results({ results, showReasons = false }: { results: VoteResult[]; showReasons?: boolean }) {
  const winners = results.filter((row) => row.final_rank !== null)
    .sort((left, right) => left.final_rank! - right.final_rank!);

  return <>
    {winners.length > 0 && (
      <section className="panel stack" aria-labelledby="winners-heading">
        <h2 id="winners-heading">수상 팀</h2>
        <ol className="team-list" role="list">
          {winners.map((row) => (
            <li key={row.team_id}>
              <span className="status-tag">{row.final_rank}위</span>
              <strong>{row.name}</strong><span>{row.award_name}</span>
              {showReasons && row.tie_reason && <span className="muted">{row.tie_reason}</span>}
            </li>
          ))}
        </ol>
      </section>
    )}
    <section className="panel stack" aria-labelledby="tally-heading">
      <h2 id="tally-heading">점수 집계</h2>
      <p className="muted">본투표 1표는 1점입니다. 여기에 Gemini 활용 가산점(최대 1점)과 운영진이 입력한 팀별 빙고 가산점을 더합니다.</p>
      {results.some((row) => row.runoff_vote_count != null) && <p className="muted">합계 점수순을 유지하며, 같은 점수 안에서는 재투표 결과를 반영했습니다.</p>}
      <div className="table-wrap" tabIndex={0} role="region" aria-label="점수 집계 표">
        <p className="table-scroll-hint">표가 잘리면 좌우로 밀어 확인하세요.</p>
        <table>
          <thead><tr><th scope="col">팀</th><th scope="col">본투표</th><th scope="col">Gemini 가산점</th><th scope="col">빙고 가산점</th><th scope="col">합계</th><th scope="col">재투표</th><th scope="col">반영 순위</th></tr></thead>
          <tbody>
            {results.map((row) => (
              <tr key={row.team_id}>
                <th scope="row">{row.name}</th><td>{row.vote_count}표</td>
                <td>+{row.gemini_bonus}점</td>
                <td>+{row.bingo_bonus}점</td>
                <td style={{ whiteSpace: "nowrap" }}>{row.total_score}점{(row.main_tied_count ?? row.tied_count) > 1 && <span className="muted"> · 공동 {row.main_rank ?? row.raw_rank}위</span>}</td>
                <td>{row.runoff_vote_count == null ? "—" : `${row.runoff_vote_count}표`}</td>
                <td style={{ whiteSpace: "nowrap" }}>{row.tied_count > 1 ? "공동 " : ""}{row.raw_rank}위</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  </>;
}

export function RunoffResults({ rounds }: { rounds: Runoff[] }) {
  if (!rounds.length) return null;
  return <section className="panel stack" aria-labelledby="runoff-history-heading">
    <h2 id="runoff-history-heading">재투표 기록</h2>
    {rounds.map((round) => <div className="stack compact" key={round.id}>
      <h3>합계 {round.main_score}점 동점 그룹</h3>
      <ul className="team-list">{round.results.map((row) => <li key={row.team_id}>
        <strong>{row.name}</strong><span>재투표 {row.vote_count}표 · {row.tied_count > 1 ? "공동 " : ""}{row.raw_rank}위</span>
      </li>)}</ul>
    </div>)}
  </section>;
}

import Link from "next/link";
import { getVoteManagement } from "@/lib/auth";
import { voteStatusLabels, voteTime, type BingoBonus, type GeminiBonus, type VoteDetails } from "../../vote/data";
import { Results, RunoffResults } from "../../vote/results";
import { CancelVoteSchedule, CloseVote, OpenVote, PublishVote, RunoffControls } from "./controls";
import { DeadlineCountdown } from "../../deadline-countdown";
import { GeminiBonusEditor } from "./gemini-bonus-editor";
import { BingoBonusEditor } from "./bingo-bonus-editor";

export const metadata = { title: "투표·수상" };

export default async function AdminVotePage() {
  const { supabase, member, canManageVote, votePermissionError } = await getVoteManagement();
  if (votePermissionError) throw new Error("Could not load vote permissions");
  const owner = member.role === "owner";
  const [{ data, error }, bonusResponse, bingoResponse] = await Promise.all([
    supabase.rpc("get_vote_details"),
    owner ? supabase.rpc("get_gemini_bonuses") : Promise.resolve(null),
    supabase.rpc("get_bingo_bonuses"),
  ]);
  if (error || !data || bonusResponse?.error || (owner && !bonusResponse?.data)) throw new Error("Could not load vote administration");
  const vote = data as VoteDetails;
  const bonuses = bonusResponse?.data as { locked: boolean; teams: GeminiBonus[] } | undefined;
  if (bingoResponse.error || !bingoResponse.data) throw new Error("Could not load bingo bonuses");
  const bingo = bingoResponse.data as { locked: boolean; teams: BingoBonus[] };
  const closeTime = vote.closes_at && new Date(vote.closes_at);
  const deadlineReady = Boolean(closeTime && closeTime.getTime() > Date.now());
  const eligibleCount = vote.eligible_count ?? 0;
  const runoff = vote.status !== "published" ? vote.runoff : null;
  const activeRunoff = runoff && runoff.status !== "closed";

  return <>
    <h1>투표·수상</h1>
    <p className="muted">수상 기준은 3팀입니다. 최종 순위와 동점 처리 내용을 확인한 뒤 결과를 공개하세요.</p>
    <p className="muted">본투표 득표수에 Gemini 가산점(팀당 최대 1점)과 빙고 가산점을 더해 순위를 정합니다. 첫 재투표를 시작하거나 결과를 공개하기 전에 두 가산점을 확인해 주세요.</p>
    {!owner && <p className="notice">{canManageVote ? "투표 운영 대행자로 지정되어 본투표와 재투표를 운영할 수 있습니다. 행사 일정·마감 설정 변경은 총관리자에게 요청해 주세요." : "투표 현황을 확인하고 팀별 빙고 가산점을 입력할 수 있습니다. 투표 운영은 총관리자 또는 지정된 대행자가 진행합니다."}</p>}
    <DeadlineCountdown label={runoff ? "재투표 마감" : "투표 마감"} deadline={runoff?.closes_at ?? vote.closes_at} opensAt={runoff?.opens_at ?? vote.opens_at} state={runoff?.status ?? vote.status} serverNow={Date.now()} />
    {runoff && <section className="panel stack" aria-labelledby="runoff-status-heading">
      <h2 id="runoff-status-heading">동점 재투표 · {voteStatusLabels[runoff.status]}</h2>
      <p>투표 {runoff.voted_count ?? 0}명 / 유권자 {runoff.eligible_count ?? 0}명</p>
      <p className="muted">합계 {runoff.main_score}점 동점 그룹 · 마감 {voteTime.format(new Date(runoff.closes_at))}</p>
      <ul className="team-list">{runoff.candidates.map((candidate) => <li key={candidate.id}>{candidate.name}</li>)}</ul>
    </section>}
    <section className="panel stack" aria-labelledby="vote-status-heading">
      <h2 id="vote-status-heading">본투표 · {voteStatusLabels[vote.status]}</h2>
      <p>투표 {vote.voted_count ?? 0}명 / 유권자 {vote.eligible_count ?? 0}명</p>
      <p className="muted">시작 {vote.opens_at ? voteTime.format(new Date(vote.opens_at)) : "미정"}</p>
      <p className="muted">마감 {closeTime ? voteTime.format(closeTime) : "미정"}</p>
      {vote.status === "open" && <p className="muted">마감을 확정하면 득표 집계를 확인할 수 있습니다.</p>}
    </section>

    {vote.status === "draft" && <section className="panel stack" aria-labelledby="vote-readiness-heading">
      <h2 id="vote-readiness-heading">투표 시작 준비</h2>
      <ul className="team-list">
        <li><strong>후보 팀 2개 이상</strong><span>현재 {vote.candidates.length}팀 · {vote.candidates.length > 1 ? "준비 완료" : "팀 추가 필요"}</span></li>
        <li><strong>팀에 배정된 활성 참가자 중 현장 체크인 완료(출석·지각)</strong><span>현재 {eligibleCount}명 · {eligibleCount > 0 ? "준비 완료" : "팀 배정과 출석 상태를 확인해 주세요"}</span></li>
        <li><strong>현재 시각 이후의 투표 마감</strong><span>{closeTime ? voteTime.format(closeTime) : "미정"} · {deadlineReady ? "준비 완료" : "마감 시각 설정 필요"}</span></li>
      </ul>
      <p className="muted">위 조건을 갖추면 총관리자와 지정된 투표 대행자에게 시작 시각 예약·즉시 시작 설정이 표시됩니다. 발표자료 PDF 제출은 투표 시작의 필수 조건이 아닙니다.</p>
      <Link href="/admin/members" className="text-link">참가자·팀 설정</Link>
      <Link href="/admin/attendance" className="text-link">현장 체크인 확인</Link>
      {owner ? <Link href="/admin/settings" className="text-link">투표 마감 시각 설정</Link> : <p className="muted">마감 시각 설정은 총관리자에게 요청해 주세요.</p>}
    </section>}

    {bonuses && <GeminiBonusEditor teams={bonuses.teams} locked={bonuses.locked} />}
    <BingoBonusEditor teams={bingo.teams} locked={bingo.locked} />

    {vote.status === "draft" && (
      canManageVote && vote.candidates.length > 1 && deadlineReady && eligibleCount > 0
        ? <OpenVote candidates={vote.candidates} closesAt={vote.closes_at!} eligibleCount={eligibleCount} />
        : <section className="panel stack">
          <h2>후보 팀</h2>
          {vote.candidates.length ? <ul className="team-list">{vote.candidates.map((team) => <li key={team.id}>{team.name}</li>)}</ul> : <p>등록된 팀이 없습니다.</p>}
        </section>
    )}
    {vote.status === "scheduled" && <section className="panel stack">
      <h2>확정된 후보 팀</h2>
      <p className="muted">예약 시각에 자동으로 시작합니다. 시작 전 투표 요청은 차단됩니다.</p>
      <ul className="team-list">{vote.candidates.map((team) => <li key={team.id}>{team.name}</li>)}</ul>
    </section>}
    {canManageVote && vote.status === "scheduled" && <CancelVoteSchedule />}
    {canManageVote && (vote.status === "open" || vote.status === "expired") && <CloseVote early={vote.status === "open"} />}
    {(vote.status === "closed" || vote.status === "published") && <Results results={vote.results} showReasons />}
    <RunoffResults rounds={vote.runoff_history} />
    {canManageVote && vote.status === "closed" && <RunoffControls key={runoff?.id ?? "first"} groups={vote.runoff_groups} runoff={runoff} />}
    {canManageVote && vote.status === "closed" && !activeRunoff && <PublishVote key={`${vote.runoff_history.length}-${vote.results.map((row) => `${row.team_id}:${row.total_score}`).join(",")}`} results={vote.results} />}
  </>;
}

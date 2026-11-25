import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { requireStaff } from "@/lib/auth";
import { bingoEndTime, formatBingoElapsed, parseBingoRound } from "@/lib/bingo";
import { formatEventTime } from "@/lib/event-time";
import { DeadlineCountdown } from "../../deadline-countdown";
import type { BingoDetails } from "../../bingo/data";
import { BingoRefresh } from "../../bingo/refresh";
import { BingoConfigForm, BingoControl } from "./controls";
import { BingoRoundNav } from "../../bingo/round-nav";
import styles from "../../bingo/bingo.module.css";

export const metadata = { title: "빙고 운영" };

const completionTime = new Intl.DateTimeFormat("ko-KR", {
  timeZone: "Asia/Seoul", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit",
  second: "2-digit", fractionalSecondDigits: 3, hour12: false,
});

export default async function AdminBingoPage({ searchParams }: { searchParams: Promise<{ round?: string | string[] }> }) {
  const { supabase, member } = await requireStaff();
  const params = await searchParams;
  const round = parseBingoRound(params.round);
  if (params.round !== undefined && round === null) notFound();
  const { data, error } = round ? await supabase.rpc("get_bingo_round", { p_round_no: round }) : await supabase.rpc("get_bingo");
  if (round && (error?.code === "22023" || !error && !data)) notFound();
  if (error || !data) throw new Error("Could not load bingo administration");
  const bingo = data as BingoDetails;
  if (round && bingo.is_current) redirect("/admin/bingo");
  const endsAt = bingoEndTime(bingo.closes_at, bingo.closed_at);
  const owner = member.role === "owner";
  const questions = bingo.questions ?? [];
  const participants = bingo.participants ?? [];
  const completed = participants.filter((participant) => participant.completed_at);
  const flags = bingo.flags ?? [];
  const ready = questions.length === 25 && questions.every((question) => question.trim());
  return <>
    <h1>QR 빙고 운영</h1>
    <BingoRefresh active={bingo.is_current && bingo.status !== "draft"} />
    <BingoRoundNav rounds={bingo.rounds} selected={bingo.round_no} admin />
    {!bingo.is_current && <p className="notice">이전 회차의 기록입니다. 이 화면에서는 변경할 수 없습니다.<br /><Link href="/admin/bingo" className="text-link">현재 빙고로 이동</Link></p>}
    <section className="panel stack">
      <h2>{bingo.round_no}회차 · {bingo.status === "draft" ? "준비 중 · 문항 비공개" : bingo.status === "open" ? "빙고 진행 중" : "빙고 종료"}</h2>
      <p>5 × 5 · 3줄 완성 · 공개 후 {bingo.opens_at && bingo.closes_at ? Math.round((Date.parse(bingo.closes_at) - Date.parse(bingo.opens_at)) / 60000) : 25}분</p>
      <p className="muted">참가자가 해당하는 사람과 대화한 뒤, 상대방이 일회용 QR을 스캔하고 확인합니다. 같은 사람은 한 빙고판에서 한 칸만 확인할 수 있습니다.</p>
      <p className="muted">QR은 참가자가 칸을 선택해 직접 만듭니다. 로그인한 상대방이 QR을 스캔하거나 12자리 코드를 입력하면 확인자·시각·O표가 회차별로 바로 저장됩니다. 앱 안에서는 화면 이동 없이 결과 창으로 알려드립니다.</p>
      <p className="preserve-lines">상품 · {bingo.prize || "미정"}</p>
      <Link href="/admin/vote#bingo-bonus" className="text-link">팀별 빙고 가산점 관리</Link>
      {bingo.status === "draft" && <p className="muted">저장된 문항 {questions.filter((question) => question.trim()).length}개 / 25개</p>}
      {!owner && <p className="muted">문항·상품 설정과 공개·종료·새 회차 시작은 총관리자만 할 수 있습니다.</p>}
    </section>
    {bingo.status !== "draft" && (bingo.is_current ? <DeadlineCountdown label={`${bingo.round_no}회차 빙고 종료`} deadline={endsAt} state={bingo.status} serverNow={Date.now()} /> : <p className="muted">종료 · {endsAt ? formatEventTime(endsAt) : "미정"}</p>)}
    {owner && bingo.is_current && bingo.status === "draft" && <>
      <BingoConfigForm questions={questions} prize={bingo.prize} />
      <BingoControl key={`${bingo.round_no}:open`} operation="open" roundNo={bingo.round_no} ready={ready} />
    </>}
    {owner && bingo.is_current && bingo.status === "open" && <BingoControl key={`${bingo.round_no}:close`} operation="close" roundNo={bingo.round_no} />}
    {owner && bingo.is_current && bingo.status === "closed" && <BingoControl key={`${bingo.round_no}:restart`} operation="restart" roundNo={bingo.round_no} />}
    {bingo.status !== "draft" && <>
      <section className="panel stack" aria-labelledby="bingo-completion-ranking">
        <h2 id="bingo-completion-ranking">{bingo.round_no}회차 · 3줄 완성 순위</h2>
        <p className="muted">서버에 처음 3줄이 저장된 정밀 시각 순서입니다. 표시 시각은 밀리초까지만 나오며, 서버 시각까지 같을 때 공동 순위입니다. 운영진은 완성 당시 팀과 확인 기록을 대조해 팀별 가산점을 입력합니다.</p>
        {completed.length ? <div className="table-wrap" tabIndex={0} role="region" aria-label="3줄 완성 순위 표">
          <p className="table-scroll-hint">표가 잘리면 좌우로 밀어 확인하세요.</p>
          <table>
            <thead><tr><th scope="col">순위</th><th scope="col">참가자</th><th scope="col">완성 당시 팀</th><th scope="col">완성 시각 · 한국 시간</th><th scope="col">시작 후 소요 시간</th><th scope="col">확인 필요</th></tr></thead>
            <tbody>{completed.map((participant) => <tr key={participant.member_id}>
              <td>{participant.completion_tied_count > 1 ? "공동 " : ""}{participant.completion_rank ?? "—"}위</td>
              <th scope="row">{participant.name}</th>
              <td>{participant.completed_team_name ?? "기존 소속 기록 없음"}</td>
              <td><time dateTime={participant.completed_at!}>{completionTime.format(new Date(participant.completed_at!))}</time></td>
              <td>{formatBingoElapsed(participant.completion_elapsed_seconds)}</td>
              <td>{participant.suspicious_count > 0 ? <span className="status-tag">검토 필요 · {participant.suspicious_count}건</span> : "표시된 이상 없음"}</td>
            </tr>)}</tbody>
          </table>
        </div> : <p className="muted">아직 3줄을 완성한 참가자가 없습니다.</p>}
      </section>
      <section className="panel stack">
        <h2>참여 현황</h2>
        <p className="muted">참가자는 완료한 칸에서 확인자와 시각을 볼 수 있습니다. 운영진은 이 화면에서 참여·완성 현황과 아래의 빠른 연속 확인 기록을 확인합니다. 이전 기록은 회차를 선택해 볼 수 있습니다.</p>
        <div className={styles.stats}><p><strong>{participants.length}</strong>명 참여</p><p><strong>{participants.filter((participant) => participant.completed_at).length}</strong>명 3줄 완성</p><p><strong>{participants.filter((participant) => participant.suspicious_count > 0).length}</strong>명 확인 필요</p></div>
        {participants.length ? <ul className={styles.reviewList}>{participants.map((participant) => <li key={participant.member_id}>
          <h3>{participant.name}</h3>
          <p className="muted">{participant.email}</p>
          <p>O표 {participant.marked_count}칸 · {participant.completed_lines}줄{participant.completed_at ? " · 3줄 완성" : ""}</p>
          {participant.completed_at && <p className="muted">완성 {formatEventTime(participant.completed_at)}</p>}
          {participant.suspicious_count > 0 && <p className="status-tag">운영진 확인 필요 · {participant.suspicious_count}건</p>}
        </li>)}</ul> : <p className="muted">아직 빙고판을 연 참가자가 없습니다.</p>}
      </section>
      <section className="panel stack">
        <h2>빠른 연속 확인 기록</h2>
        <p className="muted">10초 안에 3건 이상 확인된 경우를 표시합니다. 자동 탈락 처리하지 않으며, 대화 여부와 상황을 확인한 뒤 판단해 주세요.</p>
        <p className="muted">최근 100건을 표시합니다.</p>
        {flags.length ? <ul className={styles.reviewList}>{flags.map((flag, index) => <li key={`${flag.confirmed_at}-${index}`}>
          <h3>{flag.requester_name} ← {flag.confirmer_name}</h3>
          <p className="muted">요청 · {flag.requester_email}<br />확인 · {flag.confirmer_email}</p>
          <p className="preserve-lines">{flag.cell + 1}번 · {flag.question}</p>
          <p className="muted">{formatEventTime(flag.confirmed_at)} · {flag.reason}</p>
        </li>)}</ul> : <p className="muted">확인이 필요한 기록이 없습니다.</p>}
      </section>
    </>}
    {(!owner || bingo.status !== "draft") && <details className="panel"><summary>저장된 문항 보기</summary><ol className="stack compact">{questions.map((question, index) => <li key={index} className="preserve-lines">{question || "미정"}</li>)}</ol></details>}
  </>;
}

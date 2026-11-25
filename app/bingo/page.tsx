import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { requireMember, getConsent } from "@/lib/auth";
import { bingoEndTime, parseBingoRound } from "@/lib/bingo";
import { formatEventTime } from "@/lib/event-time";
import { Header } from "../ui";
import { DeadlineCountdown } from "../deadline-countdown";
import { BingoBoard } from "./board";
import { BingoScanner } from "./scanner";
import type { BingoResponse } from "./data";
import { BingoRoundNav } from "./round-nav";
import { BingoRefresh } from "./refresh";
import styles from "./bingo.module.css";

export const metadata = { title: "QR 빙고" };

export default async function BingoPage({ searchParams }: { searchParams: Promise<{ round?: string | string[] }> }) {
  const { supabase, member } = await requireMember();
  const params = await searchParams;
  const round = parseBingoRound(params.round);
  if (params.round !== undefined && round === null) notFound();
  const consent = await getConsent();
  if (member.role === "participant" && consent.enforced && !consent.bingo) return <><Header /><main id="participant-main" className="content stack"><h1>QR 빙고</h1><section className="panel stack"><h2>상대방과 공유할 정보를 확인해 주세요</h2><p>빙고에 참여하면 인증 상대방에게 이름·문항·확인 시각을 공유합니다. 선택 동의 후 참여할 수 있고 다른 행사 기능에는 영향이 없습니다.</p><Link href="/consent?next=%2Fbingo" className="text-link">빙고 공유 설정하기</Link></section></main></>;
  const { data, error } = round ? await supabase.rpc("get_bingo_round", { p_round_no: round }) : await supabase.rpc("get_bingo");
  if (round && (error?.code === "22023" || !error && !data)) notFound();
  if (error || !data) throw new Error("Could not load bingo");
  const bingo = data as BingoResponse;
  if (bingo.status === "hidden") return <>
    <Header admin={member.role !== "participant"} />
    <main id="participant-main" tabIndex={-1} className="content stack">
      <header className="stack compact"><h1>만나서 반가워요, QR 빙고</h1><p className="muted">대화를 나누며 서로를 알아가는 시간이에요.</p></header>
      <section className="panel stack" aria-labelledby="bingo-waiting-title">
        <p><span className="status-tag">준비 중</span></p>
        <h2 id="bingo-waiting-title">빙고를 준비하고 있어요</h2>
        <p>운영진이 시작하면 이 화면에 문항과 빙고판이 열립니다. 시작 후 25분 동안 가로·세로·대각선 중 3줄을 완성해 주세요.</p>
        <p>문항에 해당하는 사람과 대화한 뒤, 상대방이 내 일회용 QR을 스캔하거나 12자리 코드를 입력하면 바로 O표가 남아요.</p>
        <p className="muted">시작 여부는 15초마다 자동으로 확인합니다. 다른 화면에서 돌아오면 최신 상태를 불러옵니다.</p>
        <Link href="/guide" className="text-link">참가자 사용안내 보기</Link>
        {member.role !== "participant" && <Link href="/admin/bingo" className="text-link">빙고 운영 화면</Link>}
      </section>
      <BingoRefresh active />
    </main>
  </>;
  if (round && bingo.is_current) redirect("/bingo");
  const endsAt = bingoEndTime(bingo.closes_at, bingo.closed_at);
  return <>
    <Header admin={member.role !== "participant"} />
    <main id="participant-main" tabIndex={-1} className="content stack">
      <header className="stack compact"><h1>만나서 반가워요, QR 빙고</h1><p className="muted">문항에 해당하는 사람과 대화하고 O표를 모으세요. 가로·세로·대각선 중 3줄을 완성하면 성공입니다.</p></header>
      {member.role === "participant" && bingo.is_current && bingo.status === "open" && <BingoScanner key={bingo.round_no} />}
      <BingoRoundNav rounds={bingo.rounds} selected={bingo.round_no} />
      <p className="notice">{bingo.round_no}회차{bingo.is_current ? " · 현재 회차" : " · 이전 기록 · 읽기 전용"}{!bingo.is_current && <><br /><Link href="/bingo" prefetch={false} className="text-link">현재 빙고로 이동</Link></>}</p>
      {member.role !== "participant" ? <p className="panel">운영진은 진행 상황을 확인할 수 있습니다. <Link href={bingo.is_current ? "/admin/bingo" : `/admin/bingo?round=${bingo.round_no}`} className="text-link">빙고 운영 화면</Link></p> : <>
        {bingo.is_current ? <DeadlineCountdown label={`${bingo.round_no}회차 빙고 종료`} deadline={endsAt} state={bingo.status} serverNow={Date.now()} /> : <p className="muted">종료 · {endsAt ? formatEventTime(endsAt) : "미정"}</p>}
        <section className={`notice stack compact ${bingo.completed_at ? styles.complete : ""}`} aria-label="빙고 진행 상황">
          <p><strong>{bingo.completed_lines}줄 / 3줄</strong> · O표 {bingo.board.filter((cell) => cell.confirmed_at).length}칸 / 25칸</p>
          {bingo.completed_at && <p role="status">3줄 완성! 상품 안내를 확인하고 운영진에게 보여 주세요.</p>}
          <p className="preserve-lines">상품 · {bingo.prize || "추후 안내"}</p>
        </section>
        {bingo.board.length ? <BingoBoard key={bingo.round_no} bingo={bingo} serverNow={Date.now()} /> : <><BingoRefresh active={bingo.is_current} /><p className="panel">이 회차에는 내 참여 기록이 없습니다.</p></>}
        <p className="muted">상대방의 확인은 서로의 신뢰를 바탕으로 합니다. 지나치게 빠른 연속 확인은 운영진 확인 대상으로 기록됩니다.</p>
      </>}
    </main>
  </>;
}

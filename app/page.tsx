import Link from "next/link";
import { requireMember } from "@/lib/auth";
import { formatEventDate, formatEventTime } from "@/lib/event-time";
import { Header } from "./ui";
import { DeadlineCountdown } from "./deadline-countdown";
import { currentVote, type VoteOverview } from "@/lib/vote-overview";
import { getBingoStatus } from "./bingo-status";
import { EventPoster } from "./brand";
import { WelcomeGuide } from "./guide/welcome";

export default async function Home() {
  const { supabase, member } = await requireMember();
  const [settings, submission, voting, bingo] = await Promise.all([
    supabase.from("event_settings").select("name,event_date,notice,contact,event_starts_at,event_ends_at,submission_deadline").single(),
    member.team_id ? supabase.from("submissions").select("team_id").eq("team_id", member.team_id).maybeSingle() : null,
    supabase.rpc("get_vote_overview"),
    getBingoStatus(),
  ]);
  if (settings.error || submission?.error || voting.error) throw new Error("Could not load event overview");
  const event = settings.data;
  const vote = currentVote(voting.data as VoteOverview);
  const serverNow = Date.now();

  return <>
    <Header admin={member.role !== "participant"} />
    <main id="participant-main" tabIndex={-1} className="content stack">
      <header className="home-heading">
        <div className="stack compact"><p className="eyebrow">{formatEventDate(event.event_date)}</p><h1>{event.name}</h1></div>
        <p className="muted">{member.name}님<br />{member.role === "participant" ? "참가자 공간" : "운영진으로 참여 중"}</p>
      </header>
      {member.role === "participant" && <WelcomeGuide memberId={member.id} audience="participant" />}
      <section className="event-hero" aria-labelledby="event-slogan">
        <div className="stack compact"><p className="brand-eyebrow">2026 GWAYOOK-THON</p><h2 id="event-slogan">상상을 맺고,<br />가치를 수확하다.</h2><p>오늘의 아이디어를 함께 나누고 완성해요.</p></div>
        <EventPoster />
      </section>
      <div className="deadline-grid">
        <DeadlineCountdown label="발표자료 제출 마감" deadline={event.submission_deadline} serverNow={serverNow} href="/presentations" />
        <DeadlineCountdown label={vote.isRunoff ? "동점 재투표 마감" : "투표 마감"} deadline={vote.closes_at} opensAt={vote.opens_at} serverNow={serverNow} state={vote.status} href="/vote" />
        {bingo.status !== "hidden" && <DeadlineCountdown label="QR 빙고 종료" deadline={bingo.closes_at ?? null} serverNow={serverNow} state={bingo.status} href="/bingo" />}
      </div>
      <div className="home-grid">
      <section className="stack" aria-labelledby="my-event">
        <div className="home-welcome stack compact"><h2 id="my-event">나의 참여 현황</h2><p className="muted">{member.team_id ? "우리 팀과 발표 대표자를 확인하세요." : "팀이 아직 배정되지 않았습니다."}</p></div>
        <div className="home-links">
          {member.role === "participant" && <Link href="/gsa"><div>GSA 현장 확인<span>신청 이메일 등록 · 체크인 때 보여 주세요</span></div></Link>}
          <Link href="/team"><div>우리 팀 확인<span>팀원 · 대표자 · 발표 순서</span></div></Link>
          <Link href="/presentations"><div>발표자료<span>{member.role !== "participant" ? "팀별 제출 현황을 관리하세요" : member.team_id ? (submission?.data ? "우리 팀 제출 완료 · 최종본 확인" : "제출·공유 여부는 대표자에게 확인해 주세요") : "팀 배정 후 자료를 제출할 수 있어요"}</span></div></Link>
          <Link href="/vote"><div>{vote.isRunoff ? "동점 재투표" : "수상 투표"}<span>{vote.voted ? "투표 완료 · 팀별 자료 보기" : vote.status === "open" && vote.eligible ? "팀별 자료 확인 · 투표할 수 있어요" : "팀별 자료 · 투표 진행과 결과 확인"}</span></div></Link>
          <Link href="/bingo" prefetch={false}><div>QR 빙고<span>{bingo.status === "hidden" ? "준비 중 · 시작하면 참여할 수 있어요" : bingo.status === "open" ? "서로 대화하고 3줄을 완성하세요" : "빙고가 끝났어요 · 내 결과 보기"}</span></div></Link>
        </div>
      </section>
      <section className="panel stack" aria-labelledby="event-schedule">
        <h2 id="event-schedule">행사 일정</h2>
        <Link className="text-link" href="/schedule">오늘의 타임테이블 보기</Link>
        <dl className="schedule-list">
          <div><dt>행사 시작</dt><dd>{formatEventTime(event.event_starts_at)}</dd></div>
          <div><dt>행사 종료</dt><dd>{formatEventTime(event.event_ends_at)}</dd></div>
          <div><dt>{vote.isRunoff ? "재투표 시작" : "투표 시작"}</dt><dd>{formatEventTime(vote.opens_at)}</dd></div>
          <div><dt><Link className="text-link" href="/presentations">발표자료 제출 마감</Link></dt><dd>{formatEventTime(event.submission_deadline)}{member.team_id && <span className="status-tag">{submission?.data ? "자료 열람 가능" : "공유 자료 없음"}</span>}</dd></div>
          <div><dt><Link className="text-link" href="/vote">{vote.isRunoff ? "재투표 마감" : "투표 마감"}</Link></dt><dd>{formatEventTime(vote.closes_at)}{vote.voted ? <span className="status-tag">투표 완료</span> : vote.status === "open" && vote.eligible ? <span className="status-tag">투표 가능</span> : null}</dd></div>
        </dl>
      </section>
      </div>
      {event.notice && <section className="panel stack"><h2>공지</h2><p className="preserve-lines">{event.notice}</p></section>}
      {event.contact && <p className="home-contact">문의 · {event.contact}</p>}
    </main>
  </>;
}

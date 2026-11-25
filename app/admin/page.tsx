import Link from "next/link";
import { Button } from "@astryxdesign/core/Button";
import { requireStaff } from "@/lib/auth";
import { formatEventDate, formatEventTime } from "@/lib/event-time";
import { voteStatusLabels } from "../vote/data";
import { currentVote, type VoteOverview } from "@/lib/vote-overview";
import { DeadlineCountdown } from "../deadline-countdown";
import styles from "./admin.module.css";
import { WelcomeGuide } from "../guide/welcome";

export const metadata = { title: "운영 현황" };

const number = new Intl.NumberFormat("ko-KR");

export default async function AdminHome() {
  const { supabase, member } = await requireStaff();
  const [counts, teams, submissions, votes, inventory, settings] = await Promise.all([
    supabase.rpc("get_staff_members", { p_scope: "counts" }),
    supabase.from("teams").select("id,representative_id"),
    supabase.rpc("get_presentation_list"),
    supabase.rpc("get_vote_overview"),
    supabase.from("inventory_item_balances").select("external_outstanding"),
    supabase.from("event_settings").select("name,event_date,event_starts_at,event_ends_at,submission_deadline").single(),
  ]);
  if (counts.error || !counts.data) throw new Error("Could not load member counts");
  if (teams.error || submissions.error || votes.error || inventory.error || settings.error) {
    throw new Error("Could not load event overview");
  }

  const event = settings.data;
  const participantCount = counts.data.active ?? 0;
  const vote = currentVote(votes.data as VoteOverview);
  const teamCount = teams.data.length;
  const submittedCount = submissions.data?.length ?? 0;
  const voteCount = vote.voted_count ?? 0;
  const serverNow = Date.now();
  const stats = [
    { label: "활성 참가자", value: number.format(participantCount), unit: "명", href: "/admin/members" },
    { label: "등록된 팀", value: number.format(teamCount), unit: "팀", href: "/admin/members#teams-heading" },
    { label: "발표자료 제출", value: number.format(submittedCount), unit: `/ ${number.format(teamCount)}팀`, href: "/admin/presentations" },
    { label: vote.isRunoff ? "재투표 참여" : "투표 참여", value: vote.status === "draft" ? voteStatusLabels.draft : number.format(voteCount),
      unit: vote.status === "draft" ? null : `/ ${number.format(vote.eligible_count ?? 0)}명`, href: "/admin/vote" },
  ];

  const checks = [
    { label: "팀 미배정 참가자", count: counts.data.unassigned ?? 0, unit: "명", href: "/admin/members#participants-heading" },
    { label: "대표자 미지정 팀", count: teams.data.filter((team) => !team.representative_id).length, unit: "팀", href: "/admin/members#teams-heading" },
    { label: "발표자료 미제출 팀", count: teamCount - submittedCount, unit: "팀", href: "/admin/presentations?missing=1" },
    { label: "차용처에 반납할 물품", count: inventory.data.reduce((total, item) => total + Number(item.external_outstanding), 0), unit: "개", href: "/admin/inventory" },
  ].filter(({ count }) => count > 0);
  const schedule = [
    ["행사 시작", event.event_starts_at], ["행사 종료", event.event_ends_at],
    ["발표자료 제출 마감", event.submission_deadline], [vote.isRunoff ? "재투표 시작" : "투표 시작", vote.opens_at], [vote.isRunoff ? "재투표 마감" : "투표 마감", vote.closes_at],
  ];

  return <>
    <header className={styles.pageHeader}>
      <div className="stack compact">
        <p className={styles.eventIdentity}>{event.name}<span aria-hidden="true">·</span><time dateTime={event.event_date}>{formatEventDate(event.event_date)}</time></p>
        <h1>운영 현황</h1>
      </div>
      <div className="action-row">
        <Button label="현황판 열기" href="/admin/display" variant="secondary" />
        <Button label="엑셀 가져오기" href="/admin/import" variant="secondary" />
        <Button label="참가자 추가" href="/admin/members#add-participant" variant="primary" />
      </div>
    </header>
    <WelcomeGuide memberId={member.id} audience="staff" />

    <div className={styles.deadlineStrip}>
      <DeadlineCountdown label="발표자료 제출 마감" deadline={event.submission_deadline} serverNow={serverNow} href="/admin/presentations" />
      <DeadlineCountdown label={vote.isRunoff ? "동점 재투표 마감" : "투표 마감"} deadline={vote.closes_at} opensAt={vote.opens_at} serverNow={serverNow} state={vote.status} href="/admin/vote" />
    </div>

    <dl className={styles.stats} aria-label="운영 요약">
      {stats.map(({ label, value, unit, href }) => <div className={styles.stat} key={label}>
        <dt><Link href={href}>{label}</Link></dt>
        <dd className={unit ? undefined : styles.statStatus}>{value}{unit && <span>{unit}</span>}</dd>
      </div>)}
    </dl>

    <div className={styles.overviewGrid}>
      <section className={styles.overviewPanel} aria-labelledby="overview-checks">
        <header className={styles.sectionHeader}><h2 id="overview-checks">확인할 항목</h2><span>{checks.length}건</span></header>
        {checks.length > 0 ? <ul role="list" className={styles.checks}>
          {checks.map(({ label, count, unit, href }) => <li key={label}>
            <Link href={href}><span>{label}</span><strong>{number.format(count)}{unit}</strong><span aria-hidden="true">›</span></Link>
          </li>)}
        </ul> : <p className={styles.empty}>{participantCount ? "현재 확인할 항목이 없습니다." : "참가자를 등록하면 팀 배정과 제출 현황을 확인할 수 있어요."}</p>}
      </section>
      <section className={styles.overviewPanel} aria-labelledby="overview-schedule">
        <header className={styles.sectionHeader}><h2 id="overview-schedule">행사 일정</h2><span>한국 시간</span></header>
        <Link className={styles.weakLink} href="/schedule">참가자 타임테이블 보기<span aria-hidden="true">›</span></Link>
        <dl className={styles.agenda}>
          {schedule.map(([label, time]) => <div key={label}>
            <dt>{label}</dt><dd>{time ? <time dateTime={time}>{formatEventTime(time)}</time> : <span>미정</span>}</dd>
          </div>)}
        </dl>
        {member.role === "owner" && <Link className={styles.weakLink} href="/admin/settings#event-settings">행사 일정 설정<span aria-hidden="true">›</span></Link>}
      </section>
    </div>
    <section className={styles.quickSection} aria-labelledby="quick-actions">
      <h2 id="quick-actions">운영 바로가기</h2>
      <div className={styles.quickLinks}>
        <Link href="/admin/members"><strong>참가자·팀 관리<span aria-hidden="true">›</span></strong><span>팀 배정과 대표자를 확인하세요.</span></Link>
        <Link href="/admin/presentations"><strong>발표자료 수합<span aria-hidden="true">›</span></strong><span>팀별 최종본을 모아 확인하세요.</span></Link>
        <Link href="/admin/inventory"><strong>물품 수량 처리<span aria-hidden="true">›</span></strong><span>팀 지급과 차용처 반납을 기록하세요.</span></Link>
        <Link href="/admin/bingo"><strong>QR 빙고<span aria-hidden="true">›</span></strong><span>문항·상품 설정과 참가 현황을 확인하세요.</span></Link>
      </div>
    </section>
  </>;
}

import Link from "next/link";
import { formatEventTime } from "@/lib/event-time";
import type { ScheduleTiming } from "@/lib/schedule";

export function ScheduleBaselines({ settings }: { settings: ScheduleTiming }) {
  return <section className="panel stack" aria-labelledby="schedule-baselines">
    <div className="stack compact">
      <h2 id="schedule-baselines">행사·마감 기준 시각</h2>
      <p className="muted">타임테이블과 별도로 설정된 시각입니다. 발표자료 제출과 투표는 해당 화면의 상태와 아래 마감을 따릅니다. 타임테이블을 수정해도 이 시각이나 빙고 제한 시간은 바뀌지 않습니다.</p>
    </div>
    <dl className="schedule-list">
      <div><dt>행사 시작</dt><dd>{formatEventTime(settings.event_starts_at)}</dd></div>
      <div><dt>행사 종료</dt><dd>{formatEventTime(settings.event_ends_at)}</dd></div>
      <div><dt><Link className="text-link" href="/presentations">발표자료 제출 마감</Link></dt><dd>{formatEventTime(settings.submission_deadline)}</dd></div>
      <div><dt>본투표 시작</dt><dd>{formatEventTime(settings.vote_opens_at)}</dd></div>
      <div><dt><Link className="text-link" href="/vote">본투표 마감</Link></dt><dd>{formatEventTime(settings.vote_closes_at)}</dd></div>
    </dl>
    <p className="muted">모든 시각은 한국 시간입니다. 재투표가 진행되면 투표 화면의 별도 마감을 확인해 주세요.</p>
  </section>;
}

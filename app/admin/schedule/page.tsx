import Link from "next/link";
import { requireOwner } from "@/lib/auth";
import { formatEventTime } from "@/lib/event-time";
import { formatScheduleRange, type ScheduleAdmin } from "@/lib/schedule";
import { ScheduleBaselines } from "../../schedule/baselines";
import { ScheduleItemDelete, ScheduleItemEditor, SchedulePublication } from "./forms";

export const metadata = { title: "타임테이블 관리" };

export default async function AdminSchedulePage() {
  const { supabase } = await requireOwner();
  const [result, settings] = await Promise.all([
    supabase.rpc("get_schedule_admin"),
    supabase.from("event_settings").select("event_starts_at,event_ends_at,submission_deadline,vote_opens_at,vote_closes_at").single(),
  ]);
  if (result.error || !result.data || settings.error) throw new Error("Could not load timetable administration");
  const schedule = result.data as ScheduleAdmin;
  return <>
    <header className="stack compact"><h1>타임테이블 관리</h1><p className="muted">총관리자가 참가자에게 보여줄 시간표를 관리합니다. 시작 시각순으로 표시되며 시각 미정 항목은 마지막에 나옵니다.</p><Link className="text-link" href="/schedule">참가자 시간표 보기</Link></header>
    <section className="panel stack" aria-labelledby="schedule-publication"><h2 id="schedule-publication">공개 상태 · {schedule.published ? "공개 중" : "비공개 초안"}</h2>
      <SchedulePublication published={schedule.published} version={schedule.version} count={schedule.items.length} />
      <p className="muted">최종 수정 · {formatEventTime(schedule.updated_at)}</p>
    </section>
    <ScheduleBaselines settings={settings.data} />
    <section className="stack" aria-labelledby="schedule-edit-items"><h2 id="schedule-edit-items">등록된 일정 · {schedule.items.length}개</h2>
      {schedule.items.length ? schedule.items.map((item) => <details className="panel" key={item.id}>
        <summary>{formatScheduleRange(item)} · {item.title}</summary>
        <div className="stack"><ScheduleItemEditor item={item} published={schedule.published} /><ScheduleItemDelete item={item} /></div>
      </details>) : <p className="muted">아래에서 첫 일정을 추가해 주세요.</p>}
    </section>
    <section className="panel stack" aria-labelledby="schedule-add"><h2 id="schedule-add">일정 추가</h2><ScheduleItemEditor published={schedule.published} /></section>
  </>;
}

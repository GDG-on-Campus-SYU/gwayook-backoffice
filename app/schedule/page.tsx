import Link from "next/link";
import { requireMember } from "@/lib/auth";
import { formatEventDate } from "@/lib/event-time";
import type { ScheduleDetails } from "@/lib/schedule";
import { Header } from "../ui";
import { ScheduleBaselines } from "./baselines";
import { ScheduleTimeline } from "./timeline";

export const metadata = { title: "타임테이블" };

export default async function SchedulePage() {
  const { supabase, member } = await requireMember();
  const [schedule, settings] = await Promise.all([
    supabase.rpc("get_event_schedule"),
    supabase.from("event_settings").select("event_date,event_starts_at,event_ends_at,submission_deadline,vote_opens_at,vote_closes_at").single(),
  ]);
  if (schedule.error || !schedule.data || settings.error) throw new Error("Could not load event timetable");
  return <>
    <Header admin={member.role !== "participant"} />
    <main id="participant-main" tabIndex={-1} className="content stack">
      <header className="stack compact">
        <p className="eyebrow">{formatEventDate(settings.data.event_date)} · 한국 시간</p>
        <h1>오늘의 타임테이블</h1>
        <p className="muted">행사의 흐름과 다음 순서를 확인하세요. 현장 진행에 따라 안내가 바뀔 수 있어요.</p>
        {member.role === "owner" && <Link className="text-link" href="/admin/schedule">타임테이블 관리</Link>}
      </header>
      <ScheduleTimeline schedule={schedule.data as ScheduleDetails} serverNow={Date.now()} />
      <ScheduleBaselines settings={settings.data} />
    </main>
  </>;
}

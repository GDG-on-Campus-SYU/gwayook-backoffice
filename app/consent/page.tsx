import { redirect } from "next/navigation";
import { getMembership } from "@/lib/auth";
import type { ConsentState } from "@/lib/privacy";
import { loginNext } from "@/lib/login-next";
import { Header } from "../ui";
import { ConsentForm } from "./form";
import { formatEventTime } from "@/lib/event-time";

export const metadata = { title: "약관·공유 설정" };
const labels: Record<string, string> = { terms: "이용약관", team: "팀원에게 내 이름 공유", presentation: "발표자료 공유", bingo: "빙고 상호 확인" };
export default async function ConsentPage({ searchParams }: { searchParams: Promise<{ next?: string }> }) {
  const membership = await getMembership();
  if (membership.status !== "active") redirect("/login");
  const { data, error } = await membership.supabase.rpc("get_my_consents");
  if (error || !data) throw new Error("Could not load consent preferences");
  const consent = data as ConsentState;
  return <><Header eventNav={false} /><main id="participant-main" className="content stack">
    <header><p className="eyebrow">GWAYOOK-THON 2026</p><h1>약관·공유 설정</h1><p>{membership.member.name}님의 선택을 서버 시각과 안내 버전으로 기록합니다.</p></header>
    <ConsentForm consent={consent} participant={membership.member.role === "participant"} next={loginNext((await searchParams).next) ?? undefined} />
    <details className="panel"><summary>내 동의 기록</summary><ul>{consent.history.map((record, index) => <li key={index}>{formatEventTime(record.recorded_at)} · {labels[record.kind]} · {record.accepted ? "동의" : "미동의·철회"} · {record.version}</li>)}</ul>{!consent.history.length && <p>아직 저장한 동의가 없습니다.</p>}</details>
  </main></>;
}

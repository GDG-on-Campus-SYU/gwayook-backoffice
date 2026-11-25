import { redirect } from "next/navigation";
import { requireMember } from "@/lib/auth";
import { formatEventTime } from "@/lib/event-time";
import type { MyGsa } from "@/lib/gsa";
import { Header } from "../ui";
import { GsaEmailForm } from "./forms";
import styles from "./gsa.module.css";

export const metadata = { title: "GSA 현장 확인" };

export default async function GsaPage() {
  const { supabase, member } = await requireMember();
  if (member.role !== "participant") redirect("/admin/attendance");
  const { data, error } = await supabase.rpc("get_my_gsa");
  const record = data as MyGsa | null;
  return <><Header /><main id="participant-main" tabIndex={-1} className="content stack">
    <header className="stack compact"><h1>GSA 현장 확인</h1><p className="muted">신청 이메일을 저장한 뒤, 현장에서 본인의 Google 계정 화면과 함께 보여 주세요.</p></header>
    {error || !record ? <p role="alert">GSA 확인 상태를 불러오지 못했습니다. 화면을 새로고침해 다시 시도해 주세요.</p> : <>
      <section className={`stack ${styles.identity}`} aria-labelledby="gsa-presentation">
        <div className="stack compact"><p className="eyebrow">{member.name}님의 현장 제시 카드</p><h2 id="gsa-presentation">저장된 신청 이메일</h2></div>
        <p className={styles.email}>{record.gsa_email ?? "아직 입력하지 않았어요"}</p>
        <p><span className="status-tag">{record.gsa_status === "verified" ? "현장 확인 완료" : record.gsa_status === "failed" ? "현장 재확인 필요" : record.gsa_email ? "운영진 확인 대기" : "이메일 입력 전"}</span></p>
        <p>{record.gsa_status === "verified" ? "운영진의 현장 확인이 완료되었습니다." : record.gsa_status === "failed" ? "본인의 Google 계정에서 AI Plus 활성 상태와 이메일을 다시 확인한 뒤 운영진에게 보여 주세요." : "이메일 저장만으로 확인이 완료되지 않습니다. 운영진의 현장 확인을 받아 주세요."}</p>
        {record.gsa_updated_at && <p className="muted">상태 갱신 · <time dateTime={record.gsa_updated_at}>{formatEventTime(record.gsa_updated_at)}</time> · 한국 시간</p>}
      </section>
      <section className="panel stack" aria-labelledby="gsa-guide"><h2 id="gsa-guide">현장에서 이렇게 확인해요</h2>
        <ol className={styles.steps}><li>GSA 신청에 사용한 이메일을 아래에 입력하고 저장하세요.</li><li>본인의 실제 Google 계정에서 AI Plus 활성 상태와 계정 이메일을 운영진에게 보여 주세요.</li><li>운영진이 활성 상태와 저장된 신청 이메일의 일치를 확인하면 이 화면이 ‘현장 확인 완료’로 바뀝니다. ‘최신 상태 확인’으로 결과를 불러올 수 있어요.</li></ol>
        <p><a className="text-link" href="https://one.google.com/" target="_blank" rel="noreferrer">Google One에서 내 멤버십 확인 (새 탭)</a></p>
        <p className="muted">이 카드는 직접 입력한 이메일과 운영진의 확인 결과를 보여 줍니다. 앱이 Google 계정이나 구독 정보를 자동 조회하지 않으며, 스크린샷을 올릴 필요도 없습니다.</p>
      </section>
      <GsaEmailForm record={record} />
    </>}
  </main></>;
}

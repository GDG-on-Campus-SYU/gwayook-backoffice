import { Button } from "@astryxdesign/core/Button";
import { requireStaff } from "@/lib/auth";
import type { ParticipantOperation } from "@/lib/participant-operations";
import { OperationsList } from "./operations-list";
import styles from "./attendance.module.css";

export const metadata = { title: "출석·GSA" };

export default async function AttendancePage() {
  const { supabase } = await requireStaff();
  const { data, error } = await supabase.rpc("get_participant_operations");
  return <div className="stack">
    <header className={styles.header}><div className="stack compact"><h1>출석·GSA</h1><p className="muted">현장에서 참가자 출석과 신청 이메일·AI Plus 상태를 확인합니다.</p></div><Button href="/admin/members" label="참가자·팀 관리" variant="secondary" /></header>
    <p className="notice">본투표를 예약하거나 시작할 때 팀에 배정된 활성 참가자 중 여기서 출석·지각으로 체크인한 사람에게 투표권을 부여합니다. 이후 출석을 정정해도 확정된 명단과 기존 표는 유지됩니다. 출석·GSA는 운영진이 직접 기록하며 별도 체크인 앱과 자동 연동하지 않습니다. Google 계정 연결과 GSA 가입은 각각 확인해 주세요.</p>
    {error || !Array.isArray(data) ? <p role="alert">출석·GSA 기록을 불러오지 못했습니다. 화면을 새로고침해 다시 시도해 주세요.</p> : <OperationsList participants={data as ParticipantOperation[]} />}
  </div>;
}

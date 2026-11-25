import Link from "next/link";
import { requireOwner } from "@/lib/auth";
import { formatEventTime } from "@/lib/event-time";
import { ErasureReviewForm } from "./review-form";
import styles from "./privacy.module.css";

export const metadata = { title: "개인정보 관리" };
type Snapshot = {
  counts: Record<string, number>; erase_by: string; photos_by: string;
  consents: { id: string; name: string; terms: boolean; team: boolean; presentation: boolean; bingo: boolean }[];
  access_logs: { id: number; actor_login: string; operation: string; resource: string; subject_ids: string[]; source_ip: string | null; gateway_ip: string | null; source_kind: string; created_at: string; retain_until: string }[];
  reviews: { id: string; created_at: string; note: string }[];
};
const countLabels: Record<string, string> = { members: "앱 명단", auth_accounts: "인증 계정 (미연결 포함)", consents: "앱 동의 기록", pdf_objects: "발표자료 PDF", gsa_records: "출석·GSA 기록", bingo_boards: "빙고판", access_logs: "별도 보존 접속기록", teams: "팀", votes: "본투표", runoff_votes: "재투표", bingo_requests: "빙고 인증 요청", bingo_marks: "빙고 확인", audit_logs: "일반 운영 변경기록", inventory_movements: "물품 처리기록" };
export default async function PrivacyOperationsPage() {
  const { supabase } = await requireOwner();
  const { data, error } = await supabase.rpc("get_privacy_operations");
  if (error || !data) throw new Error("Could not load privacy operations");
  const snapshot = data as Snapshot;
  return <>
    <header className="stack compact"><h1>개인정보 관리</h1><p className="muted">동의와 접속기록을 확인하고 파기 전에 보존 예외와 외부 사본을 검토합니다. 총관리자만 볼 수 있습니다.</p></header>
    <p className="notice">GSA 외부 수신자 미정 · 외부 제공 동의는 아직 받지 않습니다. <Link href="/privacy">개인정보 처리방침</Link> · <Link href="/consent">내 약관·공유 설정</Link></p>
    <section className="panel stack"><h2>현재 동의 상태</h2><p className="muted">동의는 현재 로그인 계정과 안내 버전에 연결됩니다. 로그인 이메일을 바꾸어 계정이 재연결되면 새로 동의받습니다.</p>
      <div className="table-wrap" tabIndex={0} role="region" aria-label="현재 동의 상태 표"><table><thead><tr><th>이름</th><th>약관</th><th>팀원 이름</th><th>발표자료</th><th>빙고</th></tr></thead><tbody>{snapshot.consents.map((m) => <tr key={m.id}><th scope="row">{m.name}</th>{(["terms", "team", "presentation", "bingo"] as const).map((kind) => <td key={kind}>{m[kind] ? "동의" : "미동의·철회"}</td>)}</tr>)}</tbody></table></div>
    </section>
    <section className="panel stack"><h2>파기 전 검토</h2><p>일반 기록: 목적 달성 후 지체 없이, 늦어도 <strong>{snapshot.erase_by}</strong>까지. 선택 동의 게시용 사진·해당 동의 증빙: 최대 <strong>{snapshot.photos_by.slice(0, 10)}</strong>까지.</p>
      <dl className={styles.counts}>{Object.entries(snapshot.counts).map(([kind, count]) => <div key={kind}><dt>{countLabels[kind] ?? kind}</dt><dd>{count}건</dd></div>)}</dl>
      <ol className={styles.steps}><li>접수된 삭제·철회 요청과 전체 파기 범위를 확인하고 보존 예외를 분리합니다. 계정·파일·동의·투표·빙고·운영 메모도 대상입니다.</li>
        <li>운영자 접속기록은 생성 후 1년, 권한 부여·변경·말소 기록은 3년 보관합니다. 일반 명단 전체를 함께 보존하지 않습니다.</li>
        <li>Google Form·연결 Sheet·엑셀·CSV·문의 메일·사진 원본 등 외부 사본 담당자에게 삭제를 확인합니다. 사진 동의 증빙만 별도 보존합니다.</li>
        <li>실행 전에 서비스 접근을 중단하고 Storage API로 실제 파일을 삭제한 다음 DB 종속 기록과 Auth 계정을 정리합니다. Google 계정·AI Plus 구독 자체는 삭제하지 않습니다.</li>
        <li>백업·제공자 로그 만료, 복원 시 재삭제 목록, 저장 사본과 휴지통까지 확인한 뒤 처리 건수와 완료 증빙을 남깁니다. 확인되지 않은 단계는 완료로 표시하지 않습니다.</li></ol>
      <p className="notice">이 화면에서 대상 건수를 확인하고 검토 내용을 기록합니다. ZIP 첨부와 내려받은 사본은 별도로 확인하세요. 실제 삭제는 운영팀이 범위를 승인한 뒤 직접 진행합니다.</p>
      <ErasureReviewForm />
      <details><summary>최근 검토 기록</summary><ul>{snapshot.reviews.map((r) => <li key={r.id}>{formatEventTime(r.created_at)} · {r.note}</li>)}</ul></details>
    </section>
    <section className="panel stack"><h2>최근 운영자 접속기록</h2><p className="muted">최근 100건 · 조회·내보내기·파일 접근·운영 변경을 기록합니다. 월 1회 이상 이상 접근과 다운로드 사유를 점검하고 별도 보호된 보관본을 확인하세요. 앱 밖의 Supabase 관리 콘솔 접근은 별도 점검 대상입니다.</p>
      <div className="table-wrap" tabIndex={0} role="region" aria-label="운영자 접속기록 표"><p className="table-scroll-hint">좌우로 밀어 확인하세요.</p><table><thead><tr><th>시각</th><th>접속 계정</th><th>행위·대상</th><th>정보주체</th><th>접속지</th><th>보존 기한</th></tr></thead><tbody>{snapshot.access_logs.map((log) => <tr key={log.id}>
        <td>{formatEventTime(log.created_at)}</td><td>{log.actor_login}</td><td>{log.operation}<br />{log.resource}</td>
        <td><details><summary>{log.subject_ids.length}명</summary><ul>{log.subject_ids.map((id) => <li key={id}>{id}</li>)}</ul></details></td>
        <td>{log.source_ip ?? log.gateway_ip ?? "DB 세션 (IP 미확인)"}<br /><small>{log.source_kind}</small></td><td>{formatEventTime(log.retain_until)}</td>
      </tr>)}</tbody></table></div>
      <p className="muted">접속 IP의 뒤 두 구간은 가립니다(예: 123.45.*.*). IPv6와 확인할 수 없는 주소는 전체를 가립니다. 원본은 보호된 접속기록에 보관하며 앱 조회에는 전달하지 않습니다. 접속지는 앱 전달값과 API 게이트웨이 값을 구분하며 인증·권한 판단에 사용하지 않습니다. 파일 로그는 접근 허가·링크 발급 기록으로, 단말기 저장 완료까지 증명하지 않습니다.</p>
    </section>
  </>;
}

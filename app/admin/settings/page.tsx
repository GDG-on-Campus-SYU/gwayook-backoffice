import { requireOwner } from "@/lib/auth";
import { formatEventTime, localEventInput } from "@/lib/event-time";
import { AddStaffForm, SettingsForm, StaffStatus, VoteDelegateForm } from "./forms";

export const metadata = { title: "설정·기록" };

const logLabels: Record<string, string> = {
  roster_import: "엑셀 명단 적용", create_team: "팀 등록", update_team: "팀 수정",
  create_member: "참가자 수동 등록", update_member: "참가자 수정", update_member_email: "로그인 이메일 정정",
  set_representative: "대표자 변경", event_settings: "행사 설정 변경",
  staff_add: "운영진 추가", staff_activate: "운영진 활성화", staff_deactivate: "운영진 비활성화",
  vote_open: "투표 시작", vote_close: "투표 마감", vote_publish: "수상 결과 공개",
  vote_schedule: "투표 시작 예약", vote_schedule_cancel: "투표 예약 취소", assign_team_members: "팀 참가자 일괄 추가", remove_team_members: "팀원 제거",
  submit_presentation: "발표자료 제출", inventory_item_created: "물품 등록", inventory_correction: "물품 수량 정정",
  runoff_start: "동점 재투표 시작", runoff_close: "재투표 마감 확정",
  vote_delegate_changed: "투표 운영 대행자 변경",
  gemini_bonus_changed: "Gemini 가산점 확인 변경",
  bingo_bonus_changed: "팀별 빙고 가산점 변경",
  participant_gsa_changed: "GSA 가입 확인 변경", participant_attendance_changed: "출석·체크인 변경",
  participant_gsa_email_submitted: "참가자 GSA 신청 이메일 등록·정정",
  schedule_item_saved: "타임테이블 저장", schedule_item_deleted: "타임테이블 항목 삭제", schedule_publication_changed: "타임테이블 공개 변경",
  bingo_config_saved: "빙고 초안 저장", bingo_open: "빙고 공개 시작", bingo_close: "빙고 조기 종료", bingo_restart: "빙고 새 회차 시작",
};

type AuditEntry = { id: string; action: string; created_at: string; actor: { name: string } | null };

export default async function SettingsPage() {
  const { supabase } = await requireOwner();
  const [settings, staff, logs, delegation] = await Promise.all([
    supabase.from("event_settings").select("name,event_date,notice,contact,event_starts_at,event_ends_at,submission_deadline,vote_closes_at,vote_status").single(),
    supabase.rpc("get_staff_members", { p_scope: "staff" }),
    supabase.rpc("get_audit_entries"),
    supabase.rpc("get_vote_delegation"),
  ]);
  if (settings.error || staff.error || logs.error || delegation.error || !delegation.data) throw new Error("Could not load settings");
  const s = settings.data;
  const staffRows = staff.data as { id: string; name: string; email: string; role: string; active: boolean; auth_user_id: string | null }[];
  const auditRows = logs.data as AuditEntry[];
  const delegate = delegation.data as { member_id: string | null };
  return <>
    <header className="stack compact"><h1>설정·기록</h1><p className="muted">행사 일정과 안내를 수정하고 운영 권한과 변경 기록을 확인합니다.</p></header>
    <section className="panel stack" id="event-settings" aria-labelledby="event-settings-title"><h2 id="event-settings-title">행사 설정</h2>
      <SettingsForm name={s.name} eventDate={s.event_date} dates={{ event_starts_at: localEventInput(s.event_starts_at), event_ends_at: localEventInput(s.event_ends_at),
        submission_deadline: localEventInput(s.submission_deadline), vote_closes_at: localEventInput(s.vote_closes_at) }}
        notice={s.notice ?? ""} contact={s.contact ?? ""} votingStarted={s.vote_status !== "draft"} />
    </section>
    <section className="panel stack"><h2>운영진</h2>
      <p className="muted">Google 로그인 이메일을 미리 등록하면 첫 로그인에 연결되고 운영 화면으로 이동합니다. 별도 초대 메일은 보내지 않습니다.</p>
      <details className="role-guide"><summary>운영진과 총관리자의 권한 차이</summary><div className="stack compact">
        <p><strong>운영진</strong> · 명단·팀·대표자 관리, 출석·GSA 확인, CSV 내보내기, 발표자료 수합, 물품 수량 처리, 투표·빙고 현황 조회, 팀별 빙고 가산점 입력</p>
        <p><strong>투표 대행자</strong> · 총관리자가 지정한 운영진 1명은 본투표 예약·취소·시작·마감·결과 공개와 재투표 시작·마감 가능</p>
        <p><strong>총관리자 전용</strong> · 운영진 등록·비활성화, 대행자 지정·해제, 행사 설정·타임테이블 편집과 공개, Gemini 가산점 승인·해제, 빙고 초안·시작·종료·새 회차, 연결된 참가자 이메일 정정</p>
        <p className="muted">여기서 등록하는 계정은 운영진 권한입니다. 이미 참가자로 등록된 이메일은 중복 등록되지 않습니다.</p>
      </div></details>
      <AddStaffForm />
      <div className="table-wrap" tabIndex={0} role="region" aria-label="운영진 명단 표">
        <p className="table-scroll-hint">표가 잘리면 좌우로 밀어 확인하세요.</p>
        <table aria-label="운영진 명단"><thead><tr>
        <th scope="col">이름</th><th scope="col">Google 이메일</th><th scope="col">권한</th><th scope="col">Google 연결</th><th scope="col">상태</th><th scope="col">관리</th>
      </tr></thead><tbody>{staffRows.map((row) => <tr key={row.id}>
        <th scope="row">{row.name}</th><td>{row.email}</td><td>{row.role === "owner" ? "총관리자" : row.id === delegate.member_id && row.active ? "운영진 · 투표 대행" : "운영진"}</td><td>{row.auth_user_id ? "연결됨" : "첫 로그인 대기"}</td><td>{row.active ? "활성" : "비활성"}</td>
        <td>{row.role === "staff" && <StaffStatus id={row.id} name={row.name} active={row.active} />}</td>
      </tr>)}</tbody></table></div>
    </section>
    <section className="panel stack" aria-labelledby="vote-delegation-title">
      <h2 id="vote-delegation-title">투표 운영 대행</h2>
      <VoteDelegateForm memberId={delegate.member_id} staff={staffRows} />
    </section>
    <section className="panel stack"><h2>최근 변경 기록</h2>
      {auditRows.length === 0 ? <p className="muted">아직 기록이 없습니다.</p> : <div className="table-wrap" tabIndex={0} role="region" aria-label="최근 변경 기록 표">
        <p className="table-scroll-hint">표가 잘리면 좌우로 밀어 확인하세요.</p>
        <table aria-label="최근 변경 기록"><thead><tr><th scope="col">시각</th><th scope="col">작업</th><th scope="col">담당자</th></tr></thead>
          <tbody>{auditRows.map((entry) => <tr key={entry.id}>
            <td>{formatEventTime(entry.created_at)}</td><td>{logLabels[entry.action] ?? entry.action}</td><td>{entry.actor?.name ?? "—"}</td>
          </tr>)}</tbody>
        </table>
      </div>}
    </section>
  </>;
}

import { requireStaff } from "@/lib/auth";
import { formatEventTime } from "@/lib/event-time";
import { listPresentations, listZipAttachments } from "../../presentations/data";
import { DeadlineCountdown } from "../../deadline-countdown";

export const metadata = { title: "발표자료 관리" };

export default async function AdminPresentations({ searchParams }: { searchParams: Promise<{ missing?: string }> }) {
  const { supabase } = await requireStaff();
  const [teams, attachments, { data: members, error }, { missing }, settings] = await Promise.all([
    listPresentations(supabase), listZipAttachments(supabase), supabase.rpc("get_staff_members", { p_scope: "names" }), searchParams,
    supabase.from("event_settings").select("submission_deadline").single(),
  ]);
  if (error || settings.error) throw new Error("Could not load presentation submitters");
  const names = new Map((members as { id: string; name: string }[]).map((member) => [member.id, member.name]));
  const missingCount = teams.filter((team) => !team.submission).length;
  const shown = missing === "1" ? teams.filter((team) => !team.submission) : teams;

  return <>
    <header className="stack compact">
      <h1>발표자료 관리</h1>
      <p className="muted">제출 {teams.length - missingCount}팀 · 미제출 {missingCount}팀</p>
    </header>
    <DeadlineCountdown label="발표자료 제출 마감" deadline={settings.data.submission_deadline} serverNow={Date.now()} />
    <section className="panel stack" aria-labelledby="all-submissions">
      <h2 id="all-submissions">팀별 제출 현황</h2>
      <nav className="action-row" aria-label="제출 현황 필터">
        <a className="text-link" href="/admin/presentations" aria-current={missing === "1" ? undefined : "page"}>전체 팀</a>
        <a className="text-link" href="/admin/presentations?missing=1" aria-current={missing === "1" ? "page" : undefined}>미제출 팀</a>
      </nav>
      {shown.length ? <div className="table-wrap" tabIndex={0} role="region" aria-label="팀별 제출 현황 표">
        <p className="table-scroll-hint">표가 잘리면 좌우로 밀어 확인하세요.</p>
        <table>
        <thead><tr><th scope="col">순서</th><th scope="col">팀</th><th scope="col">대표자</th><th scope="col">제출자</th><th scope="col">제출 시각</th><th scope="col">최종 PDF</th><th scope="col">선택 ZIP</th></tr></thead>
        <tbody>{shown.map((team) => <tr key={team.id}>
          <td>{team.presentation_order ?? "미정"}</td>
          <th scope="row">{team.name}</th>
          <td>{team.representative_id ? names.get(team.representative_id) ?? "미지정" : "미지정"}</td>
          <td>{team.submission ? names.get(team.submission.submitted_by) ?? "—" : "—"}</td>
          <td>{team.submission ? formatEventTime(team.submission.submitted_at) : "—"}</td>
          <td>{team.submission
            ? <a className="text-link" href={`/presentations/${team.id}/download`} aria-label={`${team.name} ${team.submission.file_name} 다운로드`}>{team.submission.file_name}</a>
            : <span className="muted">미제출</span>}</td>
          <td>{attachments.get(team.id)?.file_name
            ? <a className="text-link" href={`/presentations/${team.id}/download?file=zip`} aria-label={`${team.name} ZIP 다운로드`}>{attachments.get(team.id)?.file_name}</a>
            : "—"}</td>
        </tr>)}</tbody>
      </table></div> : <p className="muted">{missing === "1" ? "미제출 팀이 없습니다." : "등록된 팀이 없습니다."}</p>}
    </section>
  </>;
}

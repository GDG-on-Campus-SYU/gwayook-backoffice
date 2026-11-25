import Link from "next/link";
import { redirect } from "next/navigation";
import { requireMember } from "@/lib/auth";
import { DeadlineCountdown } from "../deadline-countdown";
import { Header } from "../ui";
import { listPresentations, listZipAttachments } from "./data";
import { PresentationUpload } from "./upload";

export const metadata = { title: "발표자료" };

export default async function Presentations() {
  const { supabase, member } = await requireMember();
  if (member.role !== "participant") redirect("/admin/presentations");
  const [teams, attachments, { data: event, error }] = await Promise.all([
    listPresentations(supabase),
    listZipAttachments(supabase),
    supabase.from("event_settings").select("submission_deadline").single<{ submission_deadline: string | null }>(),
  ]);
  if (error) throw new Error("Could not load submission deadline");
  const deadline = event.submission_deadline;
  const ownTeam = teams.find((team) => team.id === member.team_id);
  const isRepresentative = ownTeam?.representative_id === member.id;
  const attachment = ownTeam && attachments.get(ownTeam.id);
  const canSubmit = !!deadline && new Date(deadline).getTime() > Date.now();

  return <>
    <Header />
    <main id="participant-main" tabIndex={-1} className="content stack">
      <Link className="text-link" href="/">행사 홈</Link>
      <header className="stack compact">
        <h1>발표자료</h1>
        <p className="muted">우리 팀의 발표자료를 제출하고 최종 파일을 확인하세요. 공유에 동의한 다른 팀 자료는 <Link className="text-link" href="/vote">투표 화면</Link>에서 볼 수 있습니다.</p>
        <p className="muted">PDF는 기본적으로 제출자와 운영진이 확인합니다. 참가자에게 공개하려면 <Link className="text-link" href="/consent">발표자료 공유 설정</Link>에 동의해 주세요. 다른 사람의 개인정보는 권한을 확인하거나 제거해야 합니다.</p>
      </header>
      <DeadlineCountdown label="발표자료 제출 마감" deadline={deadline} serverNow={Date.now()} />
      {ownTeam ? <section className="panel stack" aria-labelledby="team-submission">
        <h2 id="team-submission">{ownTeam.name} 제출</h2>
        {ownTeam.submission ? <div className="stack compact">
          <p className="muted">현재 파일 {ownTeam.submission.file_name}</p>
          <div className="action-row">
            <a className="text-link" href={`/presentations/${ownTeam.id}/download?view=1`} target="_blank" rel="noreferrer" aria-label={`${ownTeam.name} ${ownTeam.submission.file_name} 열기 (새 탭)`}>열기 (새 탭)</a>
            <a className="text-link" href={`/presentations/${ownTeam.id}/download`} aria-label={`${ownTeam.name} ${ownTeam.submission.file_name} 다운로드`}>다운로드</a>
          </div>
        </div> : <p className="muted">{isRepresentative ? "아직 제출한 자료가 없습니다." : "열람할 수 있는 자료가 없습니다. 제출·공유 여부는 대표자에게 확인해 주세요."}</p>}
        {!isRepresentative ? <p className="muted">팀 대표자만 자료를 제출할 수 있습니다.</p>
          : !deadline ? <p className="notice">운영진이 제출 마감 시간을 설정하면 제출할 수 있습니다.</p>
            : !canSubmit ? <p className="notice">발표자료 제출이 마감되었습니다.</p>
              : !process.env.SUPABASE_SECRET_KEY ? <p className="notice">제출 설정을 확인하려면 운영진에게 문의해 주세요.</p>
                : <PresentationUpload version={ownTeam.submission?.version ?? 0} />}
        {isRepresentative && <section className="stack" aria-labelledby="zip-attachment">
          <h3 id="zip-attachment">추가 자료 (선택)</h3>
          {attachment?.file_name && <a className="text-link" href={`/presentations/${ownTeam.id}/download?file=zip`}>{attachment.file_name} 다운로드</a>}
          {!attachment ? <p className="muted">발표자료 PDF를 제출하면 ZIP 파일을 추가할 수 있습니다.</p>
            : canSubmit && process.env.SUPABASE_SECRET_KEY && <PresentationUpload kind="zip" version={attachment.version} />}
        </section>}
      </section> : <p className="panel">아직 팀에 배정되지 않았습니다. 운영진에게 팀 배정을 요청해 주세요.</p>}
    </main>
  </>;
}

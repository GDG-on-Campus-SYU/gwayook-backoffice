import { requireStaff } from "@/lib/auth";
import { exportOptions } from "@/lib/csv-export";
import type { VoteDetails } from "../../vote/data";

export const metadata = { title: "CSV 내보내기" };

export default async function ExportPage() {
  const { supabase } = await requireStaff();
  const { data, error } = await supabase.rpc("get_vote_details");
  if (error || !data) throw new Error("Could not load export availability");
  const vote = data as VoteDetails;
  return <>
    <header className="stack compact"><h1>CSV 내보내기</h1><p className="muted">현재 운영 기록을 내려받아 Excel 등에서 확인할 수 있습니다. 시각은 한국 시간입니다.</p></header>
    <p className="notice">명단·출석·GSA 파일에는 참가자 개인정보와 운영 메모가 포함됩니다. 운영 업무에 필요한 사람에게만 공유해 주세요. 투표 파일에는 팀별 집계만 포함하며 개인의 선택은 내보내지 않습니다.</p>
    <p className="notice">GSA 외부 수신자는 미정입니다. 이 내보내기는 내부 운영용이며 외부 제공 동의를 뜻하지 않습니다. 외부 전달 전 수신자·목적·항목·기간을 확정하고 별도 동의를 받아야 합니다. 다운로드가 접속기록에 남으며 사본도 행사 종료 후 30일 이내 파기 대상입니다.</p>
    <section className="panel stack" aria-labelledby="export-heading">
      <h2 id="export-heading">내려받을 자료</h2>
      <ul className="team-list">
        {exportOptions.map((option) => {
          const unavailable = option.kind === "awards" ? vote.status !== "published" : option.kind === "voting" ? !["closed", "published"].includes(vote.status) : false;
          return <li key={option.kind}>
            <div className="stack compact"><strong>{option.label}</strong><p className="muted">{option.description}</p>
              {unavailable ? <p className="muted">{option.kind === "awards" ? "수상 결과를 공개하면 내려받을 수 있습니다." : "본투표 마감을 확정하면 내려받을 수 있습니다."}</p>
                : <a className="text-link" href={`/admin/export/${option.kind}`} download>{option.label} CSV 다운로드</a>}
            </div>
          </li>;
        })}
      </ul>
    </section>
    <p className="muted">내려받는 시점의 기록입니다. 수식으로 해석될 수 있는 텍스트에는 보호 문자가 붙으며, 참가자의 원래 기록은 바뀌지 않습니다.</p>
  </>;
}

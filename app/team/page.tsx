import Link from "next/link";
import { requireMember } from "@/lib/auth";
import { Header } from "../ui";

export const metadata = { title: "우리 팀" };

type Team = {
  id: string;
  name: string;
  representative_id: string | null;
  presentation_order: number | null;
  members: Array<{ id: string; name: string }>;
};

export default async function TeamPage() {
  const { supabase, member } = await requireMember();
  const { data, error } = await supabase.rpc("get_my_team");
  if (error) throw new Error("Could not load team");
  const team = data as Team | null;

  return <>
    <Header admin={member.role !== "participant"} />
    <main id="participant-main" tabIndex={-1} className="content stack">
      <Link className="text-link" href="/">행사 홈</Link>
      <h1>우리 팀</h1>
      {team ? <section className="panel stack">
        <div className="stack compact">
          <h2>{team.name}</h2>
          <p className="muted">발표 순서 {team.presentation_order ?? "미정"}</p>
        </div>
        <ul className="team-list" role="list">
          {team.members.map((person) => <li key={person.id}>
            <span>{person.name}{person.id === member.id ? " (나)" : ""}</span>
            {person.id === team.representative_id && <span className="status-tag">대표자</span>}
          </li>)}
        </ul>
        {!team.representative_id && <p className="muted">아직 대표자가 지정되지 않았습니다.</p>}
        <Link className="text-link" href="/presentations">{team.representative_id === member.id ? "발표자료 제출·확인" : "발표자료 보기"}</Link>
      </section> : <p className="panel">아직 배정된 팀이 없습니다. 운영진에게 문의해 주세요.</p>}
    </main>
  </>;
}

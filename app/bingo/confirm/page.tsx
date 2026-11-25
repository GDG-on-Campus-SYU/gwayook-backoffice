import Link from "next/link";
import { redirect } from "next/navigation";
import { getMembership, getConsent } from "@/lib/auth";
import { normalizeBingoToken } from "@/lib/bingo";
import { Header } from "../../ui";
import { formatEventTime } from "@/lib/event-time";
import type { BingoConfirmation } from "../data";
import { ConfirmBingoForm } from "./form";

export const metadata = { title: "빙고 상대 확인", referrer: "no-referrer" };

export default async function BingoConfirmPage({ searchParams }: { searchParams: Promise<{ token?: string; code?: string }> }) {
  const params = await searchParams;
  const token = normalizeBingoToken(params.token ?? params.code);
  const membership = await getMembership();
  if (membership.status !== "active") {
    const next = token ? `/bingo/confirm?${token.includes("-") ? "token" : "code"}=${encodeURIComponent(token)}` : "/bingo";
    redirect(`/login?next=${encodeURIComponent(next)}`);
  }
  const { supabase, member } = membership;
  const consent = await getConsent();
  if (consent.enforced && (!consent.terms || member.role === "participant" && !consent.bingo)) {
    const next = token ? `/bingo/confirm?${token.includes("-") ? "token" : "code"}=${encodeURIComponent(token)}` : "/bingo";
    redirect(`/consent?next=${encodeURIComponent(next)}`);
  }
  const { data: visibility, error: visibilityError } = await supabase.rpc("get_bingo_status");
  if (visibilityError) throw new Error("Could not load bingo status");
  if (visibility?.status === "hidden") redirect("/bingo");
  let confirmation: BingoConfirmation | null = null;
  let message = "QR이나 일회용 코드를 다시 확인해 주세요.";
  if (member.role !== "participant") message = "등록된 참가자 계정으로 상대방의 빙고를 확인해 주세요.";
  else if (token) {
    const { data, error } = await supabase.rpc("inspect_bingo_confirmation", { p_token: token });
    if (error || data?.error || !data) message = data?.error ?? (error?.code === "22023" || error?.code === "42501" ? error.message : "확인 요청을 불러오지 못했습니다. 새 QR로 다시 시도해 주세요.");
    else confirmation = data as BingoConfirmation;
  }
  return <>
    <Header admin={member.role !== "participant"} />
    <main id="participant-main" tabIndex={-1} className="content stack">
      <header className="stack compact"><h1>상대방 빙고 인증</h1><p className="muted">QR을 읽거나 12자리 코드를 입력하면 상대방의 빙고에 O표가 자동으로 저장됩니다.</p></header>
      {confirmation && token ? <section className="panel stack">
        <p className="eyebrow">{confirmation.round_no}회차 빙고</p>
        <h2>{confirmation.requester_name} 님의 빙고</h2>
        <p className="notice preserve-lines">{confirmation.question}</p>
        <p><strong>확인하는 사람 · {member.name}</strong></p>
        <p className="muted">지금 로그인한 내 이름과 확인 시각이 상대방의 빙고 기록에 남습니다.</p>
        <p className="muted">확인 가능 시각 · {formatEventTime(confirmation.expires_at)}까지</p>
        <ConfirmBingoForm key={token} token={token} />
        <p className="muted">내 칸에도 O표를 받으려면 내 QR을 상대방에게 보여 주세요. 같은 사람의 빙고판에서는 한 칸만 확인할 수 있습니다.</p>
      </section> : <section className="panel stack"><p role="alert">{message}</p><Link href="/bingo" className="text-link">내 빙고로 돌아가기</Link></section>}
    </main>
  </>;
}

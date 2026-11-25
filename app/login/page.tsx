import { redirect } from "next/navigation";
import Link from "next/link";
import { Button } from "@astryxdesign/core/Button";
import { getMembership } from "@/lib/auth";
import { appOrigin } from "@/lib/supabase/config";
import { signIn, signOut } from "./actions";
import { loginNext } from "@/lib/login-next";
import { BrandMark, EventPoster } from "../brand";

export const metadata = { title: "로그인" };

export default async function Login({ searchParams }: { searchParams: Promise<{ reason?: string; next?: string }> }) {
  const { reason, next: requestedNext } = await searchParams;
  const next = loginNext(requestedNext);
  const membership = await getMembership();
  const { status } = membership;
  if (status === "active" && reason !== "signout") redirect(next ?? (membership.member.role === "participant" ? "/" : "/admin"));
  const ready = status !== "setup" && !!appOrigin();
  const message = !ready
    ? "아직 로그인 설정이 완료되지 않았습니다. 운영진에게 문의해 주세요."
    : reason === "unlisted" || status === "unlisted"
      ? "등록된 명단에서 이 계정을 찾지 못했습니다. 운영진에게 등록된 Google 이메일을 확인해 주세요."
      : reason === "signout"
        ? "로그아웃하지 못했습니다. 다시 시도해 주세요."
        : reason === "auth" ? "로그인에 실패했습니다. 다시 시도해 주세요." : null;

  return (
    <main className="login-page"><div className="login-shell">
      <div className="login-intro stack">
        <div className="login-brand"><BrandMark /> 과육톤</div>
        <div className="stack"><p className="brand-eyebrow">2026 GWAYOOK-THON</p><h1>상상을 맺고,<br />가치를 수확하다.</h1><p className="login-description">우리 팀의 아이디어가 결실을 맺는 곳.<br />발표자료를 공유하고, 함께 만든 결과에 한 표를 남기세요.</p></div>
        <section className="stack login-panel" aria-labelledby="login-title">
          <header className="stack compact">
            <h2 id="login-title">행사 로그인</h2>
            <p className="muted">명단에 등록된 Google 계정으로 로그인하세요.</p>
          </header>
          {message && <p className="notice" role="status">{message}</p>}
          {next && <p className="notice">로그인하면 빙고 확인 화면으로 돌아옵니다.</p>}
          {ready && <form action={signIn}>{next && <input type="hidden" name="next" value={next} />}<Button type="submit" label="Google로 로그인" variant="primary" /></form>}
          {(status === "unlisted" || reason === "signout") && (
            <form action={signOut}><Button type="submit" label="로그아웃" variant="secondary" /></form>
          )}
          <p className="login-help">미리 등록된 참가자와 운영진은 첫 로그인에 계정이 연결됩니다. 계정이 확인되지 않으면 운영진에게 문의해 주세요.</p>
          <nav className="action-row muted" aria-label="이용 및 개인정보 안내"><Link className="text-link" href="/terms">이용약관</Link><Link className="text-link" href="/privacy">개인정보 처리방침</Link></nav>
        </section>
      </div>
      <div className="login-art"><EventPoster prominent /><p>GDGOC 서울과학기술대학교 × 삼육대학교</p></div>
    </div></main>
  );
}

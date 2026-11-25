import Link from "next/link";
import { Button } from "@astryxdesign/core/Button";
import { signOut } from "./login/actions";
import { EventNav } from "./event-nav";
import { BrandMark } from "./brand";

export function Header({ admin = false, eventNav = true }: { admin?: boolean; eventNav?: boolean }) {
  return <><a className="skip-link" href="#participant-main">본문으로 건너뛰기</a><header className="site-header">
    <Link href="/" className="brand"><BrandMark /> 과육톤</Link>
    <div className="action-row">
      <Link className="text-link" href="/consent">약관·공유 설정</Link>
      {admin && <Link className="text-link" href="/admin">운영 현황</Link>}
      <form action={signOut}><Button type="submit" label="로그아웃" variant="secondary" /></form>
    </div>
  </header>{eventNav && <EventNav />}</>;
}

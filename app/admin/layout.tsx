import type { ReactNode } from "react";
import Link from "next/link";
import { Button } from "@astryxdesign/core/Button";
import { requireStaff } from "@/lib/auth";
import { signOut } from "../login/actions";
import { AdminNav } from "./nav";
import { BrandMark } from "../brand";
import styles from "./admin.module.css";

export default async function AdminLayout({ children }: { children: ReactNode }) {
  const { member } = await requireStaff();
  const owner = member.role === "owner";
  return <div className={styles.shell}>
    <a className="skip-link" href="#admin-main">본문으로 건너뛰기</a>
    <header className={styles.topbar}>
      <Link href="/admin" className={styles.brand}>
        <BrandMark />
        <span>과육톤</span><small>운영</small>
      </Link>
      <div className={styles.topbarActions}>
        <Link href="/consent" className={styles.participantLink}>약관·공유 설정</Link>
        <Link href="/" className={styles.participantLink}>참가자 화면</Link>
        <div className={styles.account}>
          <strong>{member.name}</strong><span>{owner ? "총관리자" : "운영진"}</span>
        </div>
        <form action={signOut}><Button type="submit" label="로그아웃" variant="secondary" /></form>
      </div>
    </header>
    <AdminNav owner={owner} />
    <main id="admin-main" tabIndex={-1} className={`${styles.content} stack`}>{children}</main>
  </div>;
}

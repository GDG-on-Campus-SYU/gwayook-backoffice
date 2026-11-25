"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import styles from "./admin.module.css";

const links = [
  { href: "/admin", label: "운영 현황" },
  { href: "/admin/display", label: "현황판" },
  { href: "/admin/members", label: "참가자·팀" },
  { href: "/admin/attendance", label: "출석·GSA" },
  { href: "/admin/import", label: "엑셀 가져오기" },
  { href: "/admin/presentations", label: "발표자료" },
  { href: "/admin/vote", label: "투표·수상" },
  { href: "/admin/bingo", label: "QR 빙고" },
  { href: "/admin/inventory", label: "물품" },
  { href: "/admin/export", label: "CSV 내보내기" },
  { href: "/admin/schedule", label: "타임테이블", ownerOnly: true },
  { href: "/admin/settings", label: "설정·기록", ownerOnly: true },
  { href: "/admin/privacy", label: "개인정보 관리", ownerOnly: true },
  { href: "/admin/guide", label: "사용안내" },
];

export function AdminNav({ owner }: { owner: boolean }) {
  const current = usePathname();
  return <nav className={styles.nav} aria-label="운영 메뉴">
    <ul role="list">{links.filter((link) => !link.ownerOnly || owner).map(({ href, label }) => <li key={href}>
      <Link href={href} aria-current={href === current ? "page" : undefined}>{label}</Link>
    </li>)}</ul>
  </nav>;
}

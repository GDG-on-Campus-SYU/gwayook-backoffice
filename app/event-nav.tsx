"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

const links = [["/", "홈"], ["/schedule", "시간표"], ["/gsa", "GSA 확인"], ["/team", "우리 팀"], ["/presentations", "발표자료"], ["/vote", "투표"], ["/bingo", "빙고"], ["/guide", "사용안내"]];

export function EventNav() {
  const path = usePathname();
  return <nav className="event-nav" aria-label="행사 메뉴">
    {links.map(([href, label]) => <Link key={href} href={href} prefetch={href === "/bingo" ? false : undefined} aria-current={path === href || href === "/bingo" && path.startsWith("/bingo/") ? "page" : undefined}>{label}</Link>)}
  </nav>;
}

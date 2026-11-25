import Link from "next/link";
import type { BingoRound } from "./data";
import styles from "./bingo.module.css";

export function BingoRoundNav({ rounds, selected, admin = false }: { rounds: BingoRound[]; selected: number; admin?: boolean }) {
  const path = admin ? "/admin/bingo" : "/bingo";
  return <nav className="stack compact" aria-label="빙고 회차 선택">
    <p className="eyebrow">회차별 기록</p>
    <ul className={styles.rounds}>
      {rounds.map((round) => <li key={round.round_no}>
        <Link href={round.is_current ? path : `${path}?round=${round.round_no}`} prefetch={false} aria-current={round.round_no === selected ? "page" : undefined}>
          {round.round_no}회차 · {round.is_current ? "현재" : "이전 기록"}{round.status === "closed" ? " · 종료" : ""}
        </Link>
      </li>)}
    </ul>
  </nav>;
}

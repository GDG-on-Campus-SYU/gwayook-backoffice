import Link from "next/link";
import type { ReactNode } from "react";
import { BrandMark } from "../brand";
import styles from "./legal.module.css";

export function LegalDocument({ kind, title, description, highlights, contents, children }: {
  kind: "terms" | "privacy";
  title: string;
  description: string;
  highlights: readonly (readonly [string, string])[];
  contents: readonly (readonly [string, string])[];
  children: ReactNode;
}) {
  const date = kind === "privacy" ? "2026.11.17" : "2026.11.16";
  const version = kind === "privacy" ? "2026-11-17.1" : "2026-11-16.1";
  return <div className={styles.page}>
    <a className="skip-link" href="#legal-main">본문으로 건너뛰기</a>
    <header className={styles.header}>
      <Link href="/login" className={styles.brand}><BrandMark /><span>GWAYOOK-THON <span className={styles.year}>2026</span></span></Link>
      <Link href="/login" className={styles.back}>행사 앱으로 <span aria-hidden="true">↗</span></Link>
    </header>
    <div className={styles.tabs}><nav aria-label="약관 및 개인정보 안내">
      <Link href="/terms" aria-current={kind === "terms" ? "page" : undefined}>이용약관</Link>
      <Link href="/privacy" aria-current={kind === "privacy" ? "page" : undefined}>개인정보 처리방침</Link>
    </nav></div>
    <main id="legal-main" tabIndex={-1} className={styles.main}>
      <header className={styles.hero}>
        <p className={styles.eyebrow}>GWAYOOK-THON 2026 · 아카이브 예시</p>
        <div className={styles.titleRow}><h1>{title}</h1><span className={styles.badge}>행사 당시 {date} 적용</span></div>
        <p className={styles.description}>{description}</p>
        <p className={styles.revision}>원문 버전 {version} · 이 예시에서는 담당자 연락처와 행사 배포 환경의 세부 설정을 생략했습니다.</p>
        <dl className={styles.highlights}>{highlights.map(([label, value]) => <div key={label}><dt>{label}</dt><dd>{value}</dd></div>)}</dl>
      </header>
      <div className={styles.reviewNote}><strong>동의와 고지를 구분합니다.</strong><p>이 문서를 보거나 Google로 로그인한 것만으로 동의 처리하지 않습니다. 약관과 앱 내 선택 공유는 별도 화면에서 기록합니다. 국외 처리의 일부 국가·삭제 주기와 GSA 외부 수신자는 아직 확인 중이며, 확인되지 않은 제공에 동의한 것으로 간주하지 않습니다.</p></div>
      <div className={styles.columns}>
        <aside className={styles.toc}><nav aria-label="문서 목차"><h2>이 문서에서</h2><ol>{contents.map(([id, label]) => <li key={id}><a href={`#${id}`}>{label}</a></li>)}</ol></nav></aside>
        <article className={styles.article}>{children}</article>
      </div>
      <section className={styles.contact} aria-labelledby="legal-contact">
        <div>
          <h2 id="legal-contact">개인정보 문의와 권리행사</h2>
          <p>행사 당시에는 운영팀이 이메일로 요청을 받았습니다. 이 코드를 다른 행사에 사용할 때는 해당 운영팀의 담당자와 비공개 접수 방법을 안내해 주세요.</p>
        </div>
      </section>
    </main>
    <footer className={styles.footer}><p>GWAYOOK-THON 2026 운영팀</p><p>GDG on Campus 서울과학기술대학교 · 삼육대학교 챕터 공동 운영</p><a href="#legal-main">맨 위로 ↑</a></footer>
  </div>;
}

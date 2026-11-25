import Link from "next/link";
import type { UserGuide } from "@/lib/user-guides";
import styles from "./guide.module.css";

export function GuideContent({ guide, pdfHref }: { guide: UserGuide; pdfHref: string }) {
  return <>
    <header className={`stack ${styles.intro}`}>
      <div className="stack compact"><p className="eyebrow">GWAYOOK-THON · 사용안내</p><h1>{guide.title}</h1><p>{guide.intro}</p></div>
      <div className="action-row"><a href={pdfHref} target="_blank" rel="noopener noreferrer" className={`text-link ${styles.pdf}`}>PDF로 보기 <span className="muted">(새 탭)</span></a><p className="muted">파일을 받지 않아도 아래에서 읽을 수 있어요.</p></div>
      <p className="muted">안내 기준 · {guide.revision} · PDF 열기 방식은 브라우저 설정에 따라 달라질 수 있습니다.</p>
      <p className="notice">추가 이용 조건 · 로그인 후 약관에 동의하고 팀 이름·PDF·빙고 공유를 각각 선택합니다. 아래 기능 안내와 PDF를 이용할 때도 <Link href="/consent">약관·공유 설정</Link>이 적용됩니다. 미동의·철회한 정보는 다른 참가자에게 공유되지 않습니다.</p>
    </header>
    <div className={styles.sections}>
      {guide.sections.map((section, index) => <details key={section.id} id={section.id} className={styles.section} open={index === 0}>
        <summary><span className={styles.number} aria-hidden="true">{String(index + 1).padStart(2, "0")}</span><h2>{section.title}</h2><span className={styles.expand} aria-hidden="true">+</span></summary>
        <div className={styles.body}><ol>{section.steps.map((step) => <li key={step}>{step}</li>)}</ol>
          {section.href && <Link href={section.href} prefetch={false} className="text-link">{section.linkLabel ?? "해당 화면으로 이동"}</Link>}
        </div>
      </details>)}
    </div>
    <p className="muted">필요할 때 메뉴의 ‘사용안내’에서 다시 볼 수 있습니다. 현재 진행 상태와 마감은 각 화면에서 확인해 주세요.</p>
  </>;
}

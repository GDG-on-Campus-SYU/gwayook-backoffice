import Image from "next/image";

export function BrandMark() {
  return <Image className="brand-mark" src="/brand/mark.png" alt="" width={40} height={40} />;
}

export function EventPoster({ prominent = false }: { prominent?: boolean }) {
  return <a className="event-poster" href="/brand/poster.webp" target="_blank" rel="noreferrer" aria-label="2026 과육톤 공식 포스터 크게 보기 (새 탭)">
    <Image src="/brand/poster.webp" alt="2026 GWAYOOK-THON. 상상을 맺고, 가치를 수확하다. GDGOC 서울과학기술대학교와 삼육대학교 공동 개최 행사 포스터" width={1400} height={1976} sizes={prominent ? "(max-width: 760px) 280px, 440px" : "(max-width: 480px) 100px, 150px"} preload={prominent} />
    <span>포스터 크게 보기 <span aria-hidden="true">↗</span></span>
  </a>;
}

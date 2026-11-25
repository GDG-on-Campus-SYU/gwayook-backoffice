"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { guideRevision } from "@/lib/user-guides";
import styles from "./guide.module.css";

export function WelcomeGuide({ memberId, audience }: { memberId: string; audience: "participant" | "staff" }) {
  const key = `gwayook-guide:${guideRevision}:${audience}:${memberId}`;
  const [visible, setVisible] = useState(false);
  useEffect(() => {
    try { setVisible(localStorage.getItem(key) !== "seen"); }
    catch { setVisible(true); }
  }, [key]);
  if (!visible) return null;
  function dismiss() {
    try { localStorage.setItem(key, "seen"); } catch { /* This visit can still be dismissed when storage is unavailable. */ }
    setVisible(false);
    document.getElementById(audience === "staff" ? "admin-main" : "participant-main")?.focus();
  }
  return <section className={`stack compact ${styles.welcome}`} aria-labelledby={`welcome-${audience}`}>
    <h2 id={`welcome-${audience}`}>{audience === "staff" ? "운영 전에 확인해 주세요" : "처음 오셨다면 여기부터"}</h2>
    {audience === "staff" ? <ul><li>출석·GSA에서 체크인하고 실제 Google 계정의 AI Plus 상태와 이메일을 대조해 주세요.</li><li>팀·대표자와 제출 현황을 확인하고, 투표·빙고를 시작하기 전 담당 권한을 확인해 주세요.</li></ul>
      : <ul><li>GSA 신청 이메일을 등록하고, 체크인 때 AI Plus 활성 상태와 계정 이메일이 보이는 실제 화면을 준비해 주세요.</li><li>우리 팀·대표자를 확인해 주세요. 발표자료는 대표자가 제출하고, 빙고와 투표는 시작 후 참여할 수 있어요.</li></ul>}
    <div className="action-row"><Link className="text-link" href={audience === "staff" ? "/admin/guide" : "/guide"}>사용안내 자세히 보기</Link><button type="button" onClick={dismiss}>이 브라우저에서 안내 닫기</button></div>
  </section>;
}

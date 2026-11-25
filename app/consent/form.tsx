"use client";

import { useActionState } from "react";
import Link from "next/link";
import { Button } from "@astryxdesign/core/Button";
import { agreementVersion, sharingNotices, type ConsentState } from "@/lib/privacy";
import { saveConsent } from "./actions";

export function ConsentForm({ consent, participant, next }: { consent: ConsentState; participant: boolean; next?: string }) {
  const [state, action, pending] = useActionState(saveConsent, {});
  return <form action={action} className="stack">
    <input type="hidden" name="version" value={agreementVersion} /><input type="hidden" name="next" value={next ?? ""} />
    {participant && next && <p className="notice">빙고에 참여하려면 빙고 정보 공유 동의가 필요합니다. 동의하지 않고 저장하면 빙고 참여 안내로 이동하며, 다른 행사 기능은 그대로 이용할 수 있습니다.</p>}
    <section className="panel stack compact"><h2>앱 이용약관</h2>
      <p>약관 버전 {agreementVersion} · 무료 행사 운영 앱의 이용 조건입니다. <Link href="/terms" target="_blank" rel="noopener">이용약관 전문 (새 창)</Link></p>
      <label className="check-row"><input type="checkbox" name="terms" required defaultChecked={consent.terms} />[필수] 앱 이용약관에 동의합니다.</label>
      <p className="muted">로그인만으로 동의 처리하지 않습니다. 앱 이용을 원하지 않으면 로그아웃하고 현장 운영팀에 문의할 수 있습니다.</p>
    </section>
    {participant && <><h2>참가자 간 공유 선택</h2><p>항목별로 선택할 수 있고 이 화면에서 언제든 철회할 수 있습니다. 다른 참가자에게 로그인 이메일·GSA 정보·개별 투표 선택을 공개하지 않습니다.</p>
      {sharingNotices.map((notice) => <section className="panel stack compact" key={notice.key}>
        <h3>{notice.title}</h3><dl><dt>제공받는 자</dt><dd>{notice.recipient}</dd><dt>이용 목적</dt><dd>{notice.purpose}</dd><dt>제공 항목</dt><dd>{notice.fields}</dd><dt>보유·이용 기간</dt><dd>목적 달성 또는 철회 시까지, 최대 행사 종료 후 30일 이내. 행사 밖 재배포·이용은 금지됩니다.</dd></dl>
        <p>{notice.effect}</p><label className="check-row"><input type="checkbox" name={notice.key} defaultChecked={consent[notice.key]} />[선택] {notice.title}에 동의합니다.</label>
      </section>)}
      <p className="muted">철회 후 새 공유는 중단됩니다. 이미 발급된 PDF 링크는 최대 60초 동안 유효하며, 내려받은 사본의 회수·삭제는 운영팀에 요청해 주세요. 사진 게시 동의와 GSA 외부 제공 동의는 여기에 포함되지 않습니다.</p></>}
    <p><Link href="/privacy" target="_blank" rel="noopener">개인정보 처리방침 (새 창)</Link>에서 내부 처리와 권리행사 방법을 확인할 수 있습니다. GSA 외부 수신자는 미정이며, 확정 후 별도로 안내·동의받습니다.</p>
    {state.error && <p role="alert">{state.error}</p>}
    <Button type="submit" isDisabled={pending} label={pending ? "저장 중…" : "선택 저장하고 계속"} />
  </form>;
}

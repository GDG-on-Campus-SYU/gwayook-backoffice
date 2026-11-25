"use client";

import { Button } from "@astryxdesign/core/Button";

export default function ErrorPage({ reset }: { reset: () => void }) {
  return <section className="panel content stack" role="alert">
    <h1>화면을 불러오지 못했습니다</h1>
    <p className="muted">잠시 후 다시 시도해 주세요.</p>
    <div><Button label="다시 시도" onClick={reset} /></div>
  </section>;
}

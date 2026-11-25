"use client";

import { useActionState, useEffect, useRef, useState } from "react";
import { Button } from "@astryxdesign/core/Button";
import { formatEventTime } from "@/lib/event-time";
import { requestConfirmation } from "./actions";
import type { BingoDetails, BingoRequestFeedback } from "./data";
import { BingoRefresh } from "./refresh";
import styles from "./bingo.module.css";

const initialState: BingoRequestFeedback = { status: "idle", message: "" };

export function BingoBoard({ bingo, serverNow }: { bingo: BingoDetails; serverNow: number }) {
  const [selected, setSelected] = useState<number | null>(null);
  const [state, action, pending] = useActionState(requestConfirmation, initialState);
  const [now, setNow] = useState(serverNow);
  const detail = useRef<HTMLHeadingElement>(null);
  const cell = bingo.board.find((row) => row.cell === selected);
  const request = state.request?.cell === selected && state.request.round_no === bingo.round_no ? state.request : undefined;
  const remaining = request ? Math.min(120, Math.max(0, Math.ceil((Date.parse(request.expires_at) - now) / 1000))) : 0;
  const open = bingo.is_current && bingo.status === "open" && !!bingo.closes_at && now < Date.parse(bingo.closes_at);

  useEffect(() => {
    const started = performance.now();
    setNow(serverNow);
    const interval = window.setInterval(() => setNow(serverNow + performance.now() - started), 1000);
    return () => window.clearInterval(interval);
  }, [serverNow]);

  function select(value: number) {
    setSelected(value);
    window.requestAnimationFrame(() => detail.current?.focus());
  }

  return <>
    <BingoRefresh active={bingo.is_current} pending={open && !!state.request && !bingo.board.find((row) => row.cell === state.request?.cell)?.confirmed_at} />
    {open && <section className="notice stack compact" aria-labelledby="bingo-confirmation-guide">
      <h2 id="bingo-confirmation-guide">O표 받는 방법</h2>
      <ol className="stack compact">
        <li>문항에 해당하는 사람과 대화한 뒤, 내 칸을 누르고 <strong>확인용 QR 만들기</strong>를 선택하세요.</li>
        <li>상대방이 빙고 화면 상단의 <strong>QR 스캔</strong>으로 내 QR을 읽거나 <strong>12자리 코드</strong>를 입력합니다.</li>
        <li>별도 확인 버튼 없이 <strong>내 칸에 O표가 저장</strong>됩니다. 문항에 해당하는 사람과 대화한 뒤 인증해 주세요.</li>
      </ol>
      <p className="muted">상대방도 O표를 받으려면 상대방의 QR을 내가 따로 확인해 주세요. 한 번의 확인으로 두 사람의 칸이 함께 채워지지는 않습니다.</p>
    </section>}
    <div className={styles.layout}>
      <section className="stack compact" aria-label="내 빙고판">
        <p className="muted">칸을 누르면 문항 전체와 확인 방법을 볼 수 있습니다. O표는 상대방이 확인한 칸입니다.</p>
        <div className={styles.board}>
          {bingo.board.map((row) => <button key={row.cell} type="button" className={styles.cell} aria-pressed={selected === row.cell} data-marked={!!row.confirmed_at} onClick={() => select(row.cell)} aria-label={`${row.cell + 1}번. ${row.question}${row.confirmed_at ? ". O표 완료" : ". 미완료"}`}>
            <span className={styles.number}>{row.cell + 1}<span className={styles.mark} aria-hidden="true">{row.confirmed_at ? "O" : ""}</span></span>
            <span className={styles.question}>{row.question}</span>
          </button>)}
        </div>
      </section>
      <section className={`panel stack ${styles.selected}`} aria-labelledby="selected-bingo-cell">
        <h2 id="selected-bingo-cell" ref={detail} tabIndex={-1}>{cell ? `${cell.cell + 1}번 문항` : open ? "대화할 사람을 찾아보세요" : "내 빙고 기록"}</h2>
        {!cell ? <p className="muted">{open ? "빙고판에서 한 칸을 선택하고, 그 문항에 해당하는 사람을 만나 대화해 보세요." : "빙고판에서 한 칸을 선택하면 문항과 상대방 확인 기록을 볼 수 있습니다."}</p> : <>
          <p className="preserve-lines">{cell.question}</p>
          {cell.confirmed_at ? <div className={`notice stack compact ${styles.complete}`} role="status">
            <p>O표 완료 · {cell.confirmed_by} 님이 확인했습니다.</p>
            <p className="muted">확인 시각 · <time dateTime={cell.confirmed_at}>{formatEventTime(cell.confirmed_at)}</time> · 한국 시간</p>
            <p className="muted">확인 기록이 저장되었습니다. 다시 접속해도 유지됩니다.</p>
          </div> : !open ? <p className="notice">빙고 시간이 끝났습니다. 더 이상 O표를 받을 수 없습니다.</p> : <>
            <form action={action} className="stack compact">
              <input type="hidden" name="cell" value={cell.cell} />
              <input type="hidden" name="round_no" value={bingo.round_no} />
              <p className="muted">상대방이 빙고 화면의 QR 스캔으로 읽으면 내 칸에 바로 O표가 됩니다. 같은 사람은 내 빙고판에서 한 칸만 확인할 수 있습니다.</p>
              <div><Button type="submit" variant="primary" label={request ? "새 QR 만들기" : "확인용 QR 만들기"} isLoading={pending} isDisabled={pending} /></div>
              {state.message && <p role={state.status === "error" ? "alert" : "status"}>{state.message}</p>}
            </form>
            {request && remaining > 0 ? <div className="stack compact">
              {state.qr && <img className={styles.qr} src={state.qr} width={320} height={320} alt={`${cell.cell + 1}번 문항을 상대방이 확인할 일회용 QR`} />}
              <p role="timer" aria-live="off">QR 유효 시간 {Math.floor(remaining / 60)}분 {String(remaining % 60).padStart(2, "0")}초</p>
              <p className="muted">카메라가 안 되면 상대방의 빙고 화면 상단에 이 12자리 코드를 입력하세요. 입력을 마치면 바로 인증됩니다.</p>
              <p className={styles.code}>{request.code.match(/.{1,4}/g)?.join(" ")}</p>
            </div> : request && <p className="notice" role="status">QR 유효 시간이 끝났습니다. 새 QR을 만들어 주세요.</p>}
          </>}
        </>}
      </section>
    </div>
  </>;
}

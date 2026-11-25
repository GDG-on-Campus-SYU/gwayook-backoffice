"use client";

import { useCallback, useEffect, useId, useRef, useState } from "react";
import { Button } from "@astryxdesign/core/Button";
import { bingoManualCodePath, bingoScanPath } from "@/lib/bingo-scan";
import { ConfirmBingoForm } from "./confirm/form";
import styles from "./scanner.module.css";

function cameraErrorMessage(error: unknown): string {
  const name = error instanceof DOMException ? error.name : "";
  if (name === "NotAllowedError" || name === "SecurityError") return "카메라 접근이 허용되지 않았습니다. 브라우저의 카메라 권한을 확인하거나 아래 코드를 입력해 주세요.";
  if (name === "NotFoundError" || name === "OverconstrainedError") return "사용할 수 있는 카메라가 없습니다. 아래에 상대방의 12자리 코드를 입력해 주세요.";
  if (name === "NotReadableError") return "카메라를 사용할 수 없습니다. 다른 앱에서 사용 중인지 확인하거나 아래 코드를 입력해 주세요.";
  return "카메라를 열지 못했습니다. 다시 시도하거나 아래에 상대방의 12자리 코드를 입력해 주세요.";
}

export function BingoScanner() {
  const id = useId();
  const video = useRef<HTMLVideoElement>(null);
  const stream = useRef<MediaStream | null>(null);
  const timer = useRef<number | null>(null);
  const generation = useRef(0);
  const locked = useRef(false);
  const [phase, setPhase] = useState<"idle" | "starting" | "scanning">("idle");
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [code, setCode] = useState("");
  const [confirmationToken, setConfirmationToken] = useState<string | null>(null);
  const cameraActive = phase !== "idle";
  const compactCode = code.replace(/[ -]/g, "");
  const invalidCode = /[^0-9a-f -]/i.test(code) || compactCode.length > 12;

  const releaseCamera = useCallback(() => {
    generation.current++;
    if (timer.current !== null) window.clearTimeout(timer.current);
    timer.current = null;
    stream.current?.getTracks().forEach((track) => track.stop());
    stream.current = null;
    if (video.current) video.current.srcObject = null;
  }, []);

  const closeCamera = useCallback(() => {
    releaseCamera();
    setPhase("idle");
    setNotice("");
  }, [releaseCamera]);

  useEffect(() => {
    locked.current = false;
    function hideCamera() { if (document.hidden) closeCamera(); }
    document.addEventListener("visibilitychange", hideCamera);
    window.addEventListener("pagehide", closeCamera);
    return () => {
      document.removeEventListener("visibilitychange", hideCamera);
      window.removeEventListener("pagehide", closeCamera);
      releaseCamera();
    };
  }, [closeCamera, releaseCamera]);

  const openConfirmation = useCallback((path: string) => {
    if (locked.current) return;
    locked.current = true;
    releaseCamera();
    setPhase("idle");
    setNotice("");
    const params = new URL(path, window.location.origin).searchParams;
    setConfirmationToken(params.get("token") ?? params.get("code"));
  }, [releaseCamera]);

  function closeConfirmation() {
    setConfirmationToken(null);
    setCode("");
    locked.current = false;
  }

  async function startCamera() {
    if (locked.current) return;
    closeCamera();
    setError("");
    if (!window.isSecureContext) { setError("카메라는 보안 연결(HTTPS)에서 사용할 수 있습니다. 아래에 상대방의 12자리 코드를 입력해 주세요."); return; }
    if (!navigator.mediaDevices?.getUserMedia) { setError("이 브라우저는 카메라 스캔을 지원하지 않습니다. 아래에 상대방의 12자리 코드를 입력해 주세요."); return; }
    const current = generation.current;
    const cancelled = () => current !== generation.current || document.hidden;
    setPhase("starting");
    try {
      const decode = (await import("jsqr")).default;
      if (cancelled()) return;
      const media = await navigator.mediaDevices.getUserMedia({ audio: false, video: { facingMode: { ideal: "environment" } } });
      if (cancelled()) { media.getTracks().forEach((track) => track.stop()); return; }
      stream.current = media;
      const element = video.current;
      if (!element) { closeCamera(); return; }
      element.srcObject = media;
      await element.play();
      if (cancelled()) { media.getTracks().forEach((track) => track.stop()); return; }
      const canvas = document.createElement("canvas");
      const context = canvas.getContext("2d", { willReadFrequently: true });
      if (!context) throw new Error("Canvas unavailable");
      setPhase("scanning");
      setNotice("상대방의 QR 전체가 화면에 들어오도록 맞춰 주세요.");
      function scan() {
        if (cancelled()) return;
        try {
          if (element!.readyState >= 2 && element!.videoWidth && element!.videoHeight) {
            const scale = Math.min(1, 960 / Math.max(element!.videoWidth, element!.videoHeight));
            canvas.width = Math.max(1, Math.round(element!.videoWidth * scale));
            canvas.height = Math.max(1, Math.round(element!.videoHeight * scale));
            context!.drawImage(element!, 0, 0, canvas.width, canvas.height);
            const frame = context!.getImageData(0, 0, canvas.width, canvas.height);
            const result = decode(frame.data, frame.width, frame.height, { inversionAttempts: "dontInvert" });
            if (result) {
              const path = bingoScanPath(result.data, window.location.origin);
              if (path) { openConfirmation(path); return; }
              setNotice("과육톤 빙고 확인용 QR이 아닙니다. 상대방이 이 사이트에서 새로 만든 QR을 비춰 주세요.");
            }
          }
          timer.current = window.setTimeout(scan, 250);
        } catch {
          closeCamera();
          setError("QR을 읽지 못했습니다. 카메라를 다시 열거나 아래에 상대방의 코드를 입력해 주세요.");
        }
      }
      scan();
    } catch (cause) {
      if (cancelled()) return;
      closeCamera();
      setError(cameraErrorMessage(cause));
    }
  }

  function enterCode(value: string) {
    setCode(value.toUpperCase());
    const path = bingoManualCodePath(value);
    if (path) openConfirmation(path);
  }

  return <section className={`panel stack ${styles.scanner}`} aria-labelledby={`${id}-heading`}>
    <header className="stack compact">
      <h2 id={`${id}-heading`}>상대방 QR 확인하기</h2>
      <p className="muted">대화한 상대방의 QR을 읽거나 12자리 코드를 모두 입력하면 상대방 칸에 O표가 바로 저장됩니다.</p>
    </header>
    <div className={styles.layout}>
      <div className="stack compact">
        <div className={styles.controls}><Button type="button" variant="secondary" label={cameraActive ? "카메라 닫기" : "카메라로 QR 스캔"} onClick={cameraActive ? closeCamera : startCamera} /></div>
        <div className={styles.preview} hidden={!cameraActive}>
          <video ref={video} autoPlay playsInline muted aria-label="QR 스캔 카메라 화면" />
        </div>
        {phase === "starting" && <p className="muted" role="status">카메라를 준비하고 있습니다. 권한 요청이 나타나면 허용해 주세요.</p>}
        {notice && <p className="muted" role="status">{notice}</p>}
        {error && <p className={styles.error} role="alert">{error}</p>}
        <p className="muted">카메라 영상은 QR 읽기에만 사용하며 저장하거나 전송하지 않습니다.</p>
      </div>
      <div className="stack compact">
        <label className="field" htmlFor={`${id}-code`}>12자리 일회용 코드
          <input id={`${id}-code`} name="code" value={code} onChange={(event) => enterCode(event.currentTarget.value)} maxLength={32} autoComplete="off" autoCapitalize="characters" spellCheck={false} placeholder="ABCD 1234 EF56" aria-invalid={invalidCode} aria-describedby={`${id}-help${invalidCode ? ` ${id}-error` : ""}`} className={styles.code} />
        </label>
        <p id={`${id}-help`} className="muted">카메라 대신 입력해도 됩니다. 영문 A–F와 숫자 12자리가 완성되면 바로 저장하고 이 화면에서 결과를 알려드려요.</p>
        {invalidCode && <p id={`${id}-error`} className={styles.error} role="alert">상대방이 보여주는 영문 A–F와 숫자 12자리를 확인해 주세요.</p>}
      </div>
    </div>
    {confirmationToken && <ConfirmBingoForm key={confirmationToken} token={confirmationToken} onClose={closeConfirmation} />}
  </section>;
}

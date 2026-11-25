"use client";

import { createBrowserClient } from "@supabase/ssr";
import { Button } from "@astryxdesign/core/Button";
import { useRouter } from "next/navigation";
import { useRef, useState, type FormEvent } from "react";
import { supabaseConfig } from "@/lib/supabase/config";
import { discardPresentation, finishPresentation, preparePresentation } from "./actions";
import { looksLikePdf, MAX_PDF_BYTES, PDF_BUCKET, validPdfFileName } from "./pdf";
import { looksLikeZip, MAX_ZIP_BYTES, ZIP_BUCKET, validZipFileName } from "./zip";

export function PresentationUpload({ version, kind = "pdf" }: { version: number; kind?: "pdf" | "zip" }) {
  const zip = kind === "zip";
  const format = zip ? "ZIP" : "PDF";
  const mime = zip ? "application/zip" : "application/pdf";
  const maximum = zip ? MAX_ZIP_BYTES : MAX_PDF_BYTES;
  const validName = zip ? validZipFileName : validPdfFileName;
  const validate = zip ? looksLikeZip : looksLikePdf;
  const router = useRouter();
  const input = useRef<HTMLInputElement>(null);
  const busy = useRef(false);
  const [status, setStatus] = useState("");
  const [error, setError] = useState("");
  const [pending, setPending] = useState(false);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (busy.current) return;
    const file = input.current?.files?.[0];
    setError("");
    setStatus("");
    if (!file || file.size > maximum || !validName(file.name)) {
      setError(`${maximum / 1024 / 1024}MB 이하의 ${format} 파일을 선택해 주세요.`);
      return;
    }
    const config = supabaseConfig();
    if (!config) {
      setError("로그인 설정을 확인하려면 운영진에게 문의해 주세요.");
      return;
    }

    busy.current = true;
    setPending(true);
    let path: string | undefined;
    try {
      if (!validate(new Uint8Array(await file.arrayBuffer()))) {
        setError(`${format} 파일을 읽을 수 없습니다. 다른 파일을 선택해 주세요.`);
        return;
      }
      setStatus("제출을 준비하는 중입니다.");
      const prepared = await preparePresentation(version, file.name, file.size, kind);
      if (prepared.error || !prepared.path) {
        setError(prepared.error ?? "제출을 준비하지 못했습니다.");
        return;
      }

      path = prepared.path;
      setStatus(`${format} 파일을 올리는 중입니다.`);
      const supabase = createBrowserClient(config.url, config.key);
      const uploaded = await supabase.storage.from(zip ? ZIP_BUCKET : PDF_BUCKET).upload(path, new Blob([file], { type: mime }), {
        contentType: mime, cacheControl: "0", upsert: false,
      });
      if (uploaded.error) {
        setError("파일을 올리지 못했습니다. 기존 제출본은 유지됩니다. 다시 시도해 주세요.");
        return;
      }

      setStatus(`저장된 ${format} 파일을 확인하는 중입니다.`);
      const completed = await finishPresentation(path, kind);
      if (completed.error) {
        setError(completed.error);
        return;
      }

      path = undefined;
      if (input.current) input.current.value = "";
      setStatus(zip ? "ZIP 파일을 첨부했습니다." : "발표자료를 제출했습니다.");
      router.refresh();
    } catch {
      setError("제출 상태를 확인하지 못했습니다. 화면을 새로고침해 최종본을 확인해 주세요.");
    } finally {
      if (path) await discardPresentation(path, kind).catch(() => undefined);
      busy.current = false;
      setPending(false);
    }
  }

  return <form className="stack" onSubmit={submit}>
    <label className="field">
      {zip ? "ZIP 파일 (선택)" : "PDF 파일"}
      <input type="file" accept={`${mime},.${kind}`} ref={input} required disabled={pending}
        aria-invalid={!!error || undefined}
        aria-describedby={error ? `${kind}-help ${kind}-error` : `${kind}-help`}
        onChange={() => { setError(""); setStatus(""); }} />
    </label>
    <p id={`${kind}-help`} className="muted">{zip ? "ZIP 1개 · 최대 20MB. 현재 팀 대표자와 운영진만 다운로드할 수 있습니다." : "PDF 1개 · 최대 5MB. 제출자·운영진이 확인하며, 발표자료 공유에 동의하면 다른 참가자도 받을 수 있습니다."}</p>
    <div className="action-row"><Button type="submit" label={zip ? (version ? "ZIP 교체" : "ZIP 첨부") : (version ? "발표자료 교체" : "발표자료 제출")} variant="primary" isDisabled={pending} aria-busy={pending} /></div>
    {error ? <p id={`${kind}-error`} role="alert" className="notice">{error}</p> : <p role="status">{status}</p>}
  </form>;
}

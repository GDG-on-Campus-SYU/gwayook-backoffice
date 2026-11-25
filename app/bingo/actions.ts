"use server";

import QRCode from "qrcode";
import { requireMember } from "@/lib/auth";
import { normalizeBingoToken, parseBingoRound } from "@/lib/bingo";
import { appOrigin } from "@/lib/supabase/config";
import type { BingoFeedback, BingoRequest, BingoRequestFeedback } from "./data";

export async function requestConfirmation(_previous: BingoRequestFeedback, form: FormData): Promise<BingoRequestFeedback> {
  const { supabase, member } = await requireMember();
  if (member.role !== "participant") return { status: "error", message: "참가자만 빙고에 참여할 수 있습니다." };
  const origin = appOrigin();
  if (!origin) return { status: "error", message: "빙고 주소 설정을 확인해 주세요. 운영진에게 문의해 주세요." };
  const value = form.get("cell");
  const cell = typeof value === "string" && /^\d{1,2}$/.test(value) ? Number(value) : -1;
  if (cell < 0 || cell > 24) return { status: "error", message: "빙고 칸을 다시 선택해 주세요." };
  const round = parseBingoRound(form.get("round_no"));
  if (!round) return { status: "error", message: "빙고 회차를 확인할 수 없습니다. 새로고침해 주세요." };
  const { data, error } = await supabase.rpc("request_bingo_confirmation_round", { p_round_no: round, p_cell: cell });
  if (error || data?.error || !data) return { status: "error", message: data?.error ?? (error?.code === "22023" || error?.code === "42501" ? error.message : "확인 요청을 만들지 못했습니다. 다시 시도해 주세요.") };
  const request = data as BingoRequest;
  const url = new URL("/bingo/confirm", origin);
  url.searchParams.set("token", request.token);
  try {
    const qr = await QRCode.toDataURL(url.href, { width: 320, margin: 4, errorCorrectionLevel: "M" });
    return { status: "saved", message: "상대방에게 QR을 보여 주세요.", request, qr };
  } catch {
    return { status: "saved", message: "QR을 표시하지 못했습니다. 아래 일회용 코드를 상대방에게 알려 주세요.", request };
  }
}

export async function confirmBingo(_previous: BingoFeedback, form: FormData): Promise<BingoFeedback> {
  const { supabase, member } = await requireMember();
  const invalid = (message: string): BingoFeedback => ({ status: "error", message });
  if (member.role !== "participant") return invalid("참가자만 상대방의 빙고를 확인할 수 있습니다.");
  const token = normalizeBingoToken(form.get("token"));
  if (!token) return invalid("QR이나 일회용 코드를 다시 확인해 주세요.");
  const { data, error } = await supabase.rpc("confirm_bingo", { p_token: token });
  if (error || data?.error || !data?.confirmed) return invalid(data?.error ?? (error?.code === "22023" || error?.code === "42501" ? error.message : "확인하지 못했습니다. 새 QR로 다시 시도해 주세요."));
  // The request is now consumed; keep this confirmation receipt while the board polls for its mark.
  return { status: "saved", message: `${data.requester_name} 님의 ‘${data.question}’ 문항에 O표를 남겼습니다.` };
}

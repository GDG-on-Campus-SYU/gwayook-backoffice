"use server";

import { revalidatePath } from "next/cache";
import { requireStaff } from "@/lib/auth";
import { parseBingoConfig, parseBingoRound } from "@/lib/bingo";
import type { BingoFeedback } from "../../bingo/data";

export async function saveBingo(_previous: BingoFeedback, form: FormData): Promise<BingoFeedback> {
  const { supabase, member } = await requireStaff();
  const invalid = (message: string): BingoFeedback => ({ status: "error", message });
  if (member.role !== "owner") return invalid("총관리자 권한이 필요합니다.");
  const config = parseBingoConfig(form);
  if (!config) return invalid("문항은 각각 200자, 상품 안내는 500자 이내로 입력해 주세요.");
  const { error } = await supabase.rpc("save_bingo_config", { p_questions: config.questions, p_prize: config.prize });
  if (error) return invalid(error.code === "22023" || error.code === "42501" ? error.message : "빙고 설정을 저장하지 못했습니다. 다시 시도해 주세요.");
  revalidatePath("/admin/bingo");
  return { status: "saved", message: "초안을 저장했습니다. 빙고를 열기 전에는 참가자에게 보이지 않습니다." };
}

export async function manageBingo(operation: "open" | "close" | "restart", _previous: BingoFeedback, form: FormData): Promise<BingoFeedback> {
  const { supabase, member } = await requireStaff();
  const invalid = (message: string): BingoFeedback => ({ status: "error", message });
  if (member.role !== "owner") return invalid("총관리자 권한이 필요합니다.");
  if (operation !== "open" && operation !== "close" && operation !== "restart") return invalid("빙고 작업을 다시 선택해 주세요.");
  if (form.get("confirm") !== "yes") return invalid("확인 항목을 선택해 주세요.");
  const round = parseBingoRound(form.get("round_no"));
  if (!round) return invalid("빙고 회차를 확인할 수 없습니다. 새로고침해 주세요.");
  const { error } = await supabase.rpc("manage_bingo_round", { p_operation: operation, p_round_no: round });
  if (error) return invalid(error.code === "22023" || error.code === "42501" ? error.message : "빙고 상태를 변경하지 못했습니다. 새로고침해 주세요.");
  revalidatePath("/", "layout");
  return { status: "saved", message: operation === "open" ? "빙고를 공개했습니다. 지금부터 25분 동안 참여할 수 있습니다." : operation === "restart" ? "이전 회차를 보존하고 새 회차를 시작했습니다. 지금부터 25분입니다." : "빙고를 종료했습니다. 기록은 이 회차에 보존됩니다." };
}

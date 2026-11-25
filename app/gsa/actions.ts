"use server";

import { revalidatePath } from "next/cache";
import { requireMember } from "@/lib/auth";
import { parseMyGsaEmail } from "@/lib/gsa";

export type GsaFeedback = { status: "idle" | "saved" | "error"; message: string };

export async function saveMyGsaEmail(_previous: GsaFeedback, form: FormData): Promise<GsaFeedback> {
  const { supabase, member } = await requireMember();
  if (member.role !== "participant") return { status: "error", message: "참가자 계정에서 신청 이메일을 입력해 주세요." };
  const input = parseMyGsaEmail(form);
  if (!input) return { status: "error", message: "GSA 신청에 사용한 이메일을 확인해 주세요." };
  const { error } = await supabase.rpc("submit_my_gsa_email", { p_email: input.email, p_expected_updated_at: input.expectedUpdatedAt });
  if (error) return { status: "error", message: error.code === "22023" ? error.message : error.code === "42501"
    ? "참가자 등록과 로그인을 다시 확인해 주세요." : "이메일을 저장하지 못했습니다. 최신 상태를 확인한 뒤 다시 시도해 주세요." };
  revalidatePath("/gsa");revalidatePath("/admin", "layout");
  return { status: "saved", message: "신청 이메일을 저장했습니다. 위의 저장된 이메일과 확인 상태를 확인해 주세요." };
}

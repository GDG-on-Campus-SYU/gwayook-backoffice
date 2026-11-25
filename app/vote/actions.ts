"use server";

import { revalidatePath } from "next/cache";
import { requireMember } from "@/lib/auth";
import { teamIdPattern, type VoteActionState } from "./data";

export async function saveVote(_previous: VoteActionState, form: FormData): Promise<VoteActionState> {
  const { supabase, member } = await requireMember();
  const teamId = form.get("team_id");
  const runoffId = form.get("runoff_id");
  if (member.role !== "participant") return { status: "error", message: "참가자에게만 투표권이 있습니다." };
  if (typeof teamId !== "string" || !teamIdPattern.test(teamId)) {
    return { status: "error", message: "투표할 팀을 선택해 주세요." };
  }
  if (runoffId !== null && (typeof runoffId !== "string" || !teamIdPattern.test(runoffId))) {
    return { status: "error", message: "재투표를 새로고침한 뒤 다시 선택해 주세요." };
  }
  const { error } = runoffId
    ? await supabase.rpc("cast_runoff_vote", { p_runoff_id: runoffId, p_team_id: teamId })
    : await supabase.rpc("cast_vote", { p_team_id: teamId });
  if (error) {
    revalidatePath("/vote");
    const message = error.code === "22023" || error.code === "42501" ? error.message : "투표를 저장하지 못했습니다. 다시 시도해 주세요.";
    return { status: "error", message };
  }
  revalidatePath("/vote");
  revalidatePath("/");
  revalidatePath("/admin", "layout");
  return { status: "saved", message: "투표를 저장했습니다." };
}

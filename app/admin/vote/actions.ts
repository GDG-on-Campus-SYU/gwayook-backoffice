"use server";

import { revalidatePath } from "next/cache";
import { getVoteManagement, requireOwner, requireStaff } from "@/lib/auth";
import { parseBingoBonus } from "@/lib/bingo";
import { parseEventInput } from "@/lib/event-time";
import { parseGeminiBonus } from "@/lib/gemini-bonus";
import { confirmedVoterCount } from "@/lib/vote-overview";
import { teamIdPattern, type VoteActionState } from "../../vote/data";

type VoteOperation = "open" | "schedule" | "cancel" | "close" | "publish";

export async function saveBingoBonus(_previous: VoteActionState, form: FormData): Promise<VoteActionState> {
  const { supabase } = await requireStaff();
  const input = parseBingoBonus(form);
  if (!input) return { status: "error", message: "팀과 빙고 가산점을 확인해 주세요. 점수는 0부터 32,767까지의 정수로 입력해 주세요." };
  const { error } = await supabase.rpc("set_bingo_bonus", {
    p_team_id: input.teamId, p_points: input.points, p_expected_points: input.expectedPoints,
  });
  if (error) {
    if (error.code === "40001" || error.code === "22023") revalidatePath("/admin/vote");
    const message = ["22023", "42501", "40001"].includes(error.code) ? error.message : "빙고 가산점을 저장하지 못했습니다. 새로고침한 뒤 다시 시도해 주세요.";
    return { status: "error", message };
  }
  revalidatePath("/admin", "layout");
  revalidatePath("/vote");
  return { status: "saved", message: `빙고 가산점 ${input.points}점을 저장했습니다.` };
}

export async function saveGeminiBonus(_previous: VoteActionState, form: FormData): Promise<VoteActionState> {
  const { supabase } = await requireOwner();
  const input = parseGeminiBonus(form);
  if (!input) return { status: "error", message: "팀과 Gemini 활용 확인 여부를 확인해 주세요. 승인하려면 500자 이내의 근거가 필요합니다." };
  const { error } = await supabase.rpc("set_gemini_bonus", { p_team_id: input.teamId, p_approved: input.approved, p_note: input.note });
  if (error) return { status: "error", message: error.code === "22023" || error.code === "42501" ? error.message : "Gemini 가산점을 저장하지 못했습니다. 새로고침한 뒤 다시 시도해 주세요." };
  revalidatePath("/admin", "layout");
  revalidatePath("/vote");
  revalidatePath("/");
  return { status: "saved", message: input.approved ? "Gemini 가산점 +1점을 승인했습니다." : "Gemini 가산점 승인을 해제했습니다." };
}

export async function manageVote(operation: VoteOperation, _previous: VoteActionState, form: FormData): Promise<VoteActionState> {
  const { supabase, canManageVote, votePermissionError } = await getVoteManagement();
  const invalid = (message: string): VoteActionState => ({ status: "error", message });
  if (votePermissionError) return invalid("투표 운영 권한을 확인하지 못했습니다. 새로고침한 뒤 다시 시도해 주세요.");
  if (!canManageVote) return invalid("총관리자 또는 지정된 투표 대행자 권한이 필요합니다.");
  if (operation !== "open" && operation !== "schedule" && form.get("confirm") !== "yes") return invalid("확인 항목을 선택해 주세요.");
  let rpc = "manage_vote";
  let args: { p_action?: VoteOperation; p_candidate_ids?: string[]; p_awards?: unknown[]; p_opens_at?: string; p_expected_eligible_count?: number };
  switch (operation) {
    case "open":
    case "schedule": {
      const count = confirmedVoterCount(form);
      if (count === null) return invalid("체크인한 유권자 수를 확인하고 확인란을 선택해 주세요.");
      const candidates = form.getAll("candidate_id");
      if (candidates.length < 2 || candidates.length > 200 || !candidates.every((id): id is string => typeof id === "string" && teamIdPattern.test(id))) {
        return invalid("후보 팀을 2개 이상 선택해 주세요.");
      }
      rpc = "confirm_vote_start";
      args = { p_candidate_ids: candidates, p_expected_eligible_count: count };
      if (operation === "schedule") {
        let opensAt: string | null;
        try { opensAt = parseEventInput(String(form.get("opens_at") ?? "")); }
        catch { return invalid("투표 시작 시각을 확인해 주세요."); }
        if (!opensAt || Date.parse(opensAt) <= Date.now()) return invalid("현재 시각 이후의 투표 시작 시각을 입력해 주세요.");
        args.p_opens_at = opensAt;
      }
      break;
    }
    case "cancel":
      rpc = "cancel_vote_schedule";
      args = {};
      break;
    case "close":
      args = { p_action: operation };
      break;
    case "publish": {
      const count = Number(form.get("award_count"));
      if (!Number.isInteger(count) || count < 1 || count > 200) return invalid("수상 팀 수를 확인해 주세요.");
      const awards = [];
      for (let rank = 1; rank <= count; rank++) {
        const teamId = form.get(`team_${rank}`);
        const label = form.get(`name_${rank}`);
        const reason = form.get(`reason_${rank}`);
        if (typeof teamId !== "string" || !teamIdPattern.test(teamId) || typeof label !== "string" ||
          label.trim().length > 80 || (reason !== null && (typeof reason !== "string" || reason.trim().length > 500))) {
          return invalid(`${rank}위 수상 정보를 확인해 주세요.`);
        }
        awards.push({ team_id: teamId, award_name: label.trim() || `${rank}위`, tie_reason: typeof reason === "string" ? reason.trim() : null });
      }
      args = { p_action: operation, p_awards: awards };
      break;
    }
    default:
      return invalid("투표 작업을 다시 선택해 주세요.");
  }
  const { error } = await supabase.rpc(rpc, args);
  if (rpc === "confirm_vote_start" && error?.code === "40001") {
    revalidatePath("/admin/vote");
    return invalid("체크인한 유권자 수가 변경되었습니다. 갱신된 인원을 확인한 뒤 다시 확정해 주세요.");
  }
  if (error) return invalid(error.code === "22023" || error.code === "42501" ? error.message : "투표 상태를 변경하지 못했습니다. 새로고침해 주세요.");
  revalidatePath("/vote");
  revalidatePath("/");
  revalidatePath("/admin", "layout");
  return { status: "saved", message: operation === "schedule" ? "예약을 확정했습니다. 지정 시각에 투표가 자동으로 열립니다." : operation === "cancel" ? "예약을 취소했습니다. 명단과 시작 시각을 확인한 뒤 다시 예약할 수 있습니다." : "변경 사항을 저장했습니다." };
}

export async function manageRunoff(operation: "start" | "close", _previous: VoteActionState, form: FormData): Promise<VoteActionState> {
  const { supabase, canManageVote, votePermissionError } = await getVoteManagement();
  const invalid = (message: string): VoteActionState => ({ status: "error", message });
  if (votePermissionError) return invalid("투표 운영 권한을 확인하지 못했습니다. 새로고침한 뒤 다시 시도해 주세요.");
  if (!canManageVote) return invalid("총관리자 또는 지정된 투표 대행자 권한이 필요합니다.");
  if (form.get("confirm") !== "yes") return invalid("확인 항목을 선택해 주세요.");
  let args: { p_action: string; p_candidate_ids?: string[]; p_closes_at?: string; p_runoff_id?: string };
  if (operation === "start") {
    const candidates = form.getAll("candidate_id");
    if (candidates.length < 2 || candidates.length > 200 || !candidates.every((id): id is string => typeof id === "string" && teamIdPattern.test(id))) {
      return invalid("재투표할 동점 그룹을 선택해 주세요.");
    }
    let closesAt: string | null;
    try { closesAt = parseEventInput(String(form.get("closes_at") ?? "")); }
    catch { return invalid("재투표 마감 시각을 확인해 주세요."); }
    if (!closesAt || Date.parse(closesAt) <= Date.now()) return invalid("현재 시각 이후의 재투표 마감을 입력해 주세요.");
    args = { p_action: operation, p_candidate_ids: candidates, p_closes_at: closesAt };
  } else if (operation === "close") {
    const id = form.get("runoff_id");
    if (typeof id !== "string" || !teamIdPattern.test(id)) return invalid("재투표를 새로고침한 뒤 다시 선택해 주세요.");
    args = { p_action: operation, p_runoff_id: id };
  } else return invalid("재투표 작업을 다시 선택해 주세요.");
  const { error } = await supabase.rpc("manage_runoff", args);
  if (error) return invalid(error.code === "22023" || error.code === "42501" ? error.message : "재투표를 변경하지 못했습니다. 새로고침해 주세요.");
  revalidatePath("/vote");
  revalidatePath("/");
  revalidatePath("/admin", "layout");
  return { status: "saved", message: operation === "start" ? "재투표를 시작했습니다. 기존 본투표와 마감 설정은 유지됩니다." : "재투표 마감을 확정했습니다. 최종 수상 순위를 확인해 주세요." };
}

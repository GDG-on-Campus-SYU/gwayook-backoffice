"use server";

import { revalidatePath } from "next/cache";
import { requireStaff } from "@/lib/auth";
import { parseTeamAssignment, parseTeamRemoval } from "@/lib/team-assignment";

type RosterAction = "create_team" | "update_team" | "create_member" | "update_member" | "update_member_email" | "set_representative";

export type SaveState = { status: "idle" | "saved" | "error"; message: string; field?: "name" | "email" | "team_id" | "school" };

const uuid = /^[\da-f]{8}-[\da-f]{4}-[\da-f]{4}-[\da-f]{4}-[\da-f]{12}$/i;
const emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export async function assignTeamMembers(_previous: SaveState, form: FormData): Promise<SaveState> {
  const { supabase } = await requireStaff();
  const selection = parseTeamAssignment(form);
  if (!selection) return { status: "error", message: "추가할 참가자를 1~200명 선택해 주세요. 목록이 바뀌었다면 새로고침해 주세요." };
  const { data, error } = await supabase.rpc("assign_team_members", {
    p_team_id: selection.teamId,
    p_members: selection.members,
    p_confirm_move: selection.confirmMove,
  });
  if (error) return {
    status: "error",
    message: error.code === "22023" ? error.message : error.code === "42501"
      ? "팀을 수정할 권한이 없습니다. 다시 로그인해 주세요."
      : "팀에 추가하지 못했습니다. 새로고침한 뒤 다시 시도해 주세요.",
  };
  revalidatePath("/admin", "layout");
  revalidatePath("/");
  return { status: "saved", message: data === 0 ? "선택한 참가자는 모두 이미 이 팀에 소속되어 있습니다." : `${data}명을 팀에 추가했습니다.` };
}

export async function removeTeamMembers(_previous: SaveState, form: FormData): Promise<SaveState> {
  const { supabase } = await requireStaff();
  const selection = parseTeamRemoval(form);
  if (!selection) return { status: "error", message: "제거할 팀원과 대표자 해제 여부를 다시 확인해 주세요." };
  const { data, error } = await supabase.rpc("remove_team_members", {
    p_team_id: selection.teamId,
    p_members: selection.members,
    p_expected_representative_id: selection.expectedRepresentativeId,
    p_confirm_representative: selection.confirmRepresentative,
  });
  if (error) return {
    status: "error",
    message: error.code === "22023" ? error.message : error.code === "42501"
      ? "팀을 수정할 권한이 없습니다. 다시 로그인해 주세요."
      : "팀에서 제거하지 못했습니다. 새로고침한 뒤 다시 시도해 주세요.",
  };
  revalidatePath("/admin", "layout");
  revalidatePath("/");
  revalidatePath("/team");
  return { status: "saved", message: `${data}명을 팀에서 제거했습니다. 참가자 명단에는 미배정 상태로 남아 있습니다.` };
}

export async function saveRoster(
  action: RosterAction,
  _previous: SaveState,
  form: FormData,
): Promise<SaveState> {
  const { supabase, member } = await requireStaff();
  const id = form.get("id");
  const name = form.get("name");
  const order = form.get("presentation_order");
  const teamId = form.get("team_id");
  const representativeId = form.get("representative_id");
  const active = form.get("active");
  const school = form.get("school");
  const invalid = (message: string, field?: SaveState["field"]): SaveState => ({ status: "error", message, field });

  if (action !== "create_team" && action !== "create_member" && (typeof id !== "string" || !uuid.test(id))) {
    return invalid("수정할 항목을 다시 선택해 주세요.");
  }

  if ((action === "create_member" || action === "update_member") &&
    (form.getAll("school").length > 1 || (school !== null && (typeof school !== "string" || school.trim().length > 100)))) {
    return invalid("학교는 100자 이내로 입력해 주세요. 미등록으로 두려면 비워 주세요.", "school");
  }

  let payload: Record<string, string | number | boolean | null>;
  let success: string;

  switch (action) {
    case "create_team":
    case "update_team": {
      if (typeof name !== "string" || !name.trim() || name.trim().length > 100) {
        return invalid("팀명을 100자 이내로 입력해 주세요.");
      }
      if (
        typeof order !== "string" ||
        (order !== "" && (!/^\d+$/.test(order) || Number(order) < 1 || Number(order) > 200))
      ) {
        return invalid("발표 순서는 1부터 200 사이의 정수로 입력해 주세요.");
      }
      payload = { name: name.trim(), presentation_order: order === "" ? null : Number(order) };
      if (action === "update_team" && typeof id === "string") payload.id = id;
      success = action === "create_team" ? "팀을 추가했습니다." : "팀 정보를 저장했습니다.";
      break;
    }
    case "create_member":
    case "update_member_email": {
      const rawEmail = form.get("email");
      const email = typeof rawEmail === "string" ? rawEmail.trim().toLowerCase() : "";
      if (email.length > 254 || !emailPattern.test(email)) {
        return invalid("로그인에 사용할 Google 이메일 주소를 확인해 주세요.", "email");
      }
      if (action === "create_member") {
        if (typeof name !== "string" || !name.trim() || name.trim().length > 100) {
          return invalid("참가자 이름을 100자 이내로 입력해 주세요.", "name");
        }
        if (typeof teamId !== "string" || (teamId !== "" && !uuid.test(teamId))) {
          return invalid("소속 팀을 다시 선택해 주세요.", "team_id");
        }
        payload = { name: name.trim(), email, team_id: teamId || null };
        success = "참가자를 추가했습니다.";
      } else {
        const expectedEmail = form.get("expected_email");
        const confirmDisconnect = form.get("confirm_disconnect") === "on";
        if (typeof id !== "string" || typeof expectedEmail !== "string" || expectedEmail.length > 254 || !emailPattern.test(expectedEmail)) {
          return invalid("참가자 정보를 새로고침한 뒤 다시 확인해 주세요.");
        }
        if (email === expectedEmail) return invalid("현재 로그인 이메일과 같은 주소입니다.", "email");
        if (confirmDisconnect && member.role !== "owner") {
          return invalid("연결된 참가자의 로그인 이메일은 총관리자만 변경할 수 있습니다.");
        }
        payload = { id, email, expected_email: expectedEmail, confirm_disconnect: confirmDisconnect };
        success = "로그인 이메일을 저장했습니다.";
      }
      break;
    }
    case "update_member": {
      if (typeof id !== "string" || typeof name !== "string" || !name.trim() || name.trim().length > 100) {
        return invalid("참가자 이름을 100자 이내로 입력해 주세요.");
      }
      if (
        typeof teamId !== "string" ||
        (teamId !== "" && !uuid.test(teamId)) ||
        (active !== "true" && active !== "false")
      ) {
        return invalid("팀과 참가 상태를 다시 선택해 주세요.");
      }
      payload = { id, name: name.trim(), team_id: teamId || null, active: active === "true" };
      success = "참가자 정보를 저장했습니다.";
      break;
    }
    case "set_representative": {
      if (
        typeof id !== "string" ||
        typeof representativeId !== "string" ||
        (representativeId !== "" && !uuid.test(representativeId))
      ) {
        return invalid("대표자를 다시 선택해 주세요.");
      }
      payload = { id, representative_id: representativeId || null };
      success = representativeId ? "대표자를 지정했습니다." : "대표자 지정을 해제했습니다.";
      break;
    }
    default:
      return invalid("저장할 항목을 다시 선택해 주세요.");
  }

  if ((action === "create_member" || action === "update_member") && typeof school === "string") {
    payload.school = school.trim() || null;
  }

  const { error } = await supabase.rpc("manage_roster", { p_action: action, p_payload: payload });
  if (error) {
    if (error.code === "22023") {
      const duplicateEmail = (action === "create_member" || action === "update_member_email")
        && error.message === "이미 등록된 이메일입니다.";
      return invalid(error.message, duplicateEmail ? "email" : undefined);
    }
    if (error.code === "42501") {
      return invalid(action === "update_member_email"
        ? "연결된 참가자의 로그인 이메일은 총관리자만 변경할 수 있습니다. 목록을 새로고침해 주세요."
        : "참가자와 팀을 수정할 권한이 없습니다.");
    }
    return invalid("저장하지 못했습니다. 화면을 새로고침한 뒤 다시 시도해 주세요.");
  }

  revalidatePath("/admin", "layout");
  return { status: "saved", message: success };
}

"use server";

import { revalidatePath } from "next/cache";
import { requireStaff } from "@/lib/auth";
import { attendanceLabels, gsaLabels, parseAttendance, parseGsa } from "@/lib/participant-operations";

export type OperationFeedback = { status: "idle" | "saved" | "error"; message: string };

function failure(error: { code: string; message: string }): OperationFeedback {
  return { status: "error", message: error.code === "22023" ? error.message : error.code === "42501"
    ? "출석·GSA 기록을 수정할 권한이 없습니다. 다시 로그인해 주세요."
    : "저장하지 못했습니다. 최신 기록을 확인한 뒤 다시 시도해 주세요." };
}

export async function saveAttendance(_previous: OperationFeedback, form: FormData): Promise<OperationFeedback> {
  const { supabase } = await requireStaff();
  const record = parseAttendance(form);
  if (!record) return { status: "error", message: "출석 상태와 메모를 다시 확인해 주세요. 메모는 500자까지 입력할 수 있습니다." };
  const { error } = await supabase.rpc("set_participant_attendance", {
    p_member_id: record.memberId, p_status: record.status, p_note: record.note, p_expected_updated_at: record.expectedUpdatedAt,
  });
  if (error) return failure(error);
  revalidatePath("/admin", "layout");
  return { status: "saved", message: `출석 상태를 ‘${attendanceLabels[record.status]}’으로 저장했습니다.` };
}

export async function saveGsa(_previous: OperationFeedback, form: FormData): Promise<OperationFeedback> {
  const { supabase } = await requireStaff();
  const record = parseGsa(form);
  if (!record) return { status: "error", message: "GSA 상태와 신청 이메일을 확인해 주세요. 확인 완료에는 AI Plus 활성 상태와 실제 계정 이메일 일치 확인이 모두 필요합니다. 메모는 500자까지 입력할 수 있습니다." };
  const { error } = await supabase.rpc("set_participant_gsa", {
    p_member_id: record.memberId, p_status: record.status, p_gsa_email: record.gsaEmail, p_note: record.note, p_expected_updated_at: record.expectedUpdatedAt,
    p_plus_active: record.plusActive, p_email_matched: record.emailMatched,
  });
  if (error) return failure(error);
  revalidatePath("/admin", "layout");
  revalidatePath("/gsa");
  return { status: "saved", message: `GSA 상태를 ‘${gsaLabels[record.status]}’로 저장했습니다.` };
}

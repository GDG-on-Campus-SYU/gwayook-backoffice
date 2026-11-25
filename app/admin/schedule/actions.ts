"use server";

import { revalidatePath } from "next/cache";
import { requireOwner } from "@/lib/auth";
import { parseScheduleDeletion, parseScheduleItem, parseSchedulePublication } from "@/lib/schedule";

export type ScheduleFeedback = { status: "idle" | "saved" | "error"; message: string };

function failure(error: { code?: string; message: string }): ScheduleFeedback {
  return { status: "error", message: error.code === "22023" || error.code === "42501" ? error.message : "일정을 저장하지 못했습니다. 잠시 후 다시 시도해 주세요." };
}
function refreshed(message: string): ScheduleFeedback {
  revalidatePath("/admin/schedule"); revalidatePath("/schedule");
  return { status: "saved", message };
}

export async function saveScheduleItem(_previous: ScheduleFeedback, form: FormData): Promise<ScheduleFeedback> {
  const { supabase } = await requireOwner();
  const item = parseScheduleItem(form);
  if (!item) return { status: "error", message: "제목·내용·장소와 한국 시간 기준 시작·종료 시각을 확인해 주세요. 종료는 시작 이후여야 합니다." };
  const { error } = await supabase.rpc("save_schedule_item", { p_id: item.id, p_version: item.version,
    p_title: item.title, p_description: item.description, p_location: item.location, p_starts_at: item.startsAt, p_ends_at: item.endsAt });
  return error ? failure(error) : refreshed("일정을 저장했습니다. 제출·투표 마감과 빙고 시간은 유지됩니다.");
}

export async function deleteScheduleItem(_previous: ScheduleFeedback, form: FormData): Promise<ScheduleFeedback> {
  const { supabase } = await requireOwner();
  const item = parseScheduleDeletion(form);
  if (!item) return { status: "error", message: "삭제할 일정과 확인 항목을 다시 확인해 주세요." };
  const { error } = await supabase.rpc("delete_schedule_item", { p_id: item.id, p_version: item.version });
  return error ? failure(error) : refreshed("안내 일정 한 개를 삭제했습니다. 실제 행사 설정은 유지됩니다.");
}

export async function publishSchedule(_previous: ScheduleFeedback, form: FormData): Promise<ScheduleFeedback> {
  const { supabase } = await requireOwner();
  const choice = parseSchedulePublication(form);
  if (!choice) return { status: "error", message: "공개 상태와 확인 항목을 다시 확인해 주세요." };
  const { error } = await supabase.rpc("set_schedule_published", { p_published: choice.published, p_version: choice.version });
  return error ? failure(error) : refreshed(choice.published ? "타임테이블을 참가자에게 공개했습니다." : "타임테이블을 비공개로 바꿨습니다. 초안은 보존됩니다.");
}

"use server";

import { revalidatePath } from "next/cache";
import { requireOwner } from "@/lib/auth";
import { parseEventDate, parseEventInput } from "@/lib/event-time";
import { parseVoteDelegate } from "@/lib/vote-delegation";

export type SettingsFeedback = { message: string; failed: boolean };

export async function saveSettings(_previous: SettingsFeedback, form: FormData): Promise<SettingsFeedback> {
  const { supabase } = await requireOwner();
  const name = form.get("name");
  const date = form.get("event_date");
  const settings: Record<string, string | null> = {};
  if (name !== null) {
    if (typeof name !== "string" || !name.trim() || name.trim().length > 100) {
      return { message: "행사명을 확인해 주세요.", failed: true };
    }
    settings.name = name.trim();
  }
  try {
    if (date !== null) settings.event_date = parseEventDate(typeof date === "string" ? date : "");
    for (const field of ["event_starts_at", "event_ends_at", "submission_deadline", "vote_closes_at"]) {
      const value = form.get(field);
      if (typeof value === "string") settings[field] = parseEventInput(value);
    }
    for (const field of ["notice", "contact"]) {
      const value = form.get(field);
      if (typeof value === "string") settings[field] = value.trim() || null;
    }
  } catch {
    return { message: "날짜와 시각을 다시 확인해 주세요.", failed: true };
  }
  if (settings.event_starts_at && settings.event_ends_at && settings.event_ends_at <= settings.event_starts_at) {
    return { message: "행사 종료는 시작 이후여야 합니다.", failed: true };
  }
  if (Object.keys(settings).length === 0) return { message: "저장할 변경 사항이 없습니다.", failed: false };
  const { error } = await supabase.rpc("save_event_settings", { p_settings: settings });
  if (error) return { message: error.code === "22023" ? error.message : "설정을 저장하지 못했습니다.", failed: true };
  revalidatePath("/admin", "layout");
  revalidatePath("/");
  revalidatePath("/vote");
  revalidatePath("/presentations");
  revalidatePath("/schedule");
  return { message: "행사 설정을 저장했습니다.", failed: false };
}

export async function saveStaff(_previous: SettingsFeedback, form: FormData): Promise<SettingsFeedback> {
  const { supabase } = await requireOwner();
  const id = form.get("id");
  const active = form.get("active");
  const name = form.get("name");
  const email = form.get("email");
  if (id !== null && (typeof id !== "string" || !/^[\da-f]{8}(?:-[\da-f]{4}){3}-[\da-f]{12}$/i.test(id) || !["true", "false"].includes(String(active)))) {
    return { message: "변경할 운영진을 다시 선택해 주세요.", failed: true };
  }
  if (id === null && (typeof name !== "string" || !name.trim() || name.trim().length > 100 || typeof email !== "string" || email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.trim()))) {
    return { message: "이름과 로그인용 Google 이메일을 확인해 주세요.", failed: true };
  }
  const { error } = await supabase.rpc("save_event_staff", {
    p_id: id, p_name: typeof name === "string" ? name : null,
    p_email: typeof email === "string" ? email : null, p_active: id !== null ? active === "true" : null,
  });
  if (error) return { message: error.code === "22023" ? error.message : "운영진 정보를 저장하지 못했습니다.", failed: true };
  revalidatePath("/admin", "layout");
  return { message: id ? "운영진 상태를 변경했습니다." : "운영진을 등록했습니다.", failed: false };
}

export async function saveVoteDelegate(_previous: SettingsFeedback, form: FormData): Promise<SettingsFeedback> {
  const { supabase } = await requireOwner();
  const selection = parseVoteDelegate(form);
  if (!selection) return { message: "투표 대행자를 다시 선택해 주세요.", failed: true };
  const { error } = await supabase.rpc("set_vote_delegate", { p_member_id: selection.memberId });
  if (error) return {
    message: error.code === "22023" || error.code === "42501" ? error.message : "투표 대행자를 저장하지 못했습니다. 새로고침한 뒤 다시 시도해 주세요.",
    failed: true,
  };
  revalidatePath("/admin", "layout");
  return { message: selection.memberId ? "투표 운영 대행자를 지정했습니다." : "투표 운영 대행자 지정을 해제했습니다.", failed: false };
}

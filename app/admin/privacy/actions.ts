"use server";
import { revalidatePath } from "next/cache";
import { requireOwner } from "@/lib/auth";

export async function saveErasureReview(_previous: { error?: string; saved?: boolean }, form: FormData): Promise<{ error?: string; saved?: boolean }> {
  const { supabase } = await requireOwner();
  const note = String(form.get("note") ?? "").trim();
  if (!note || note.length > 1000) return { error: "검토 내용을 1~1,000자로 입력해 주세요." };
  const { error } = await supabase.rpc("save_erasure_review", { p_note: note });
  if (error) return { error: "검토 기록을 저장하지 못했습니다. 다시 시도해 주세요." };
  revalidatePath("/admin/privacy");
  return { saved: true };
}

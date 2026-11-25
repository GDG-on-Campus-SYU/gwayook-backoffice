"use server";

import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import { getMembership } from "@/lib/auth";
import { agreementVersion, consentDestination, parseConsent } from "@/lib/privacy";

export async function saveConsent(_previous: { error?: string }, form: FormData): Promise<{ error?: string }> {
  const membership = await getMembership();
  if (membership.status !== "active") redirect("/login");
  const input = parseConsent(form);
  if (input.error) return { error: input.error };
  const { error } = await membership.supabase.rpc("save_my_consents", {
    p_version: agreementVersion, p_terms: true, p_choices: input.values,
  });
  if (error) return { error: error.code === "22023" ? error.message : "동의 기록을 저장하지 못했습니다. 다시 시도해 주세요." };
  revalidatePath("/", "layout");
  redirect(consentDestination(form.get("next"), membership.member.role === "participant", input.values.bingo));
}

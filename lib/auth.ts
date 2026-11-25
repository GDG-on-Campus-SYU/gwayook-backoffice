import { cache } from "react";
import { redirect } from "next/navigation";
import { connection } from "next/server";
import { supabaseConfig } from "./supabase/config";
import { createSupabase } from "./supabase/server";
import type { ConsentState } from "./privacy";

export type Member = {
  id: string;
  name: string;
  email: string;
  team_id: string | null;
  role: "participant" | "staff" | "owner";
  active: boolean;
};

export const getMembership = cache(async () => {
  await connection();
  if (!supabaseConfig()) return { status: "setup" } as const;
  const supabase = await createSupabase();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { status: "signed-out" } as const;
  const { data, error } = await supabase.from("members")
    .select("id,name,email,team_id,role,active")
    .eq("auth_user_id", user.id).eq("active", true).maybeSingle<Member>();
  if (error) throw new Error("Could not load membership");
  if (!data) return { status: "unlisted" } as const;
  return { status: "active", supabase, member: data, userId: user.id } as const;
});

export const getConsent = cache(async () => {
  const membership = await getMembership();
  if (membership.status !== "active") redirect("/login");
  const { data, error } = await membership.supabase.rpc("get_my_consents");
  if (error || !data) throw new Error("Could not load consent status");
  return data as ConsentState;
});

export async function requireMember() {
  const membership = await getMembership();
  if (membership.status !== "active") redirect("/login");
  const consent = await getConsent();
  if (consent.enforced && !consent.terms) redirect("/consent");
  return membership;
}

export async function requireStaff() {
  const membership = await requireMember();
  if (membership.member.role === "participant") redirect("/");
  return membership;
}

export async function requireOwner() {
  const membership = await requireStaff();
  if (membership.member.role !== "owner") redirect("/admin");
  return membership;
}

export async function getVoteManagement() {
  const membership = await requireStaff();
  const { data, error } = await membership.supabase.rpc("can_manage_vote");
  return { ...membership, canManageVote: !error && data === true, votePermissionError: Boolean(error) };
}

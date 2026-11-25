"use server";

import { redirect } from "next/navigation";
import { headers } from "next/headers";
import { appOrigin, supabaseConfig } from "@/lib/supabase/config";
import { createSupabase } from "@/lib/supabase/server";
import { loginNext } from "@/lib/login-next";

export async function signIn(formData: FormData) {
  const next = loginNext(formData.get("next"));
  const nextQuery = next ? `&next=${encodeURIComponent(next)}` : "";
  const origin = appOrigin();
  if (!origin || !supabaseConfig()) redirect(`/login?reason=setup${nextQuery}`);
  const requestOrigin = (await headers()).get("origin");
  if (requestOrigin && requestOrigin !== origin) redirect(`${origin}/login${next ? `?next=${encodeURIComponent(next)}` : ""}`);
  const supabase = await createSupabase();
  const { data, error } = await supabase.auth.signInWithOAuth({
    provider: "google",
    options: { redirectTo: `${origin}/auth/callback${next ? `?next=${encodeURIComponent(next)}` : ""}`, queryParams: { prompt: "select_account" } },
  });
  if (error || !data.url) redirect(`/login?reason=auth${nextQuery}`);
  redirect(data.url);
}

export async function signOut() {
  if (supabaseConfig()) {
    const supabase = await createSupabase();
    const { error } = await supabase.auth.signOut({ scope: "local" });
    if (error) redirect("/login?reason=signout");
  }
  redirect("/login");
}

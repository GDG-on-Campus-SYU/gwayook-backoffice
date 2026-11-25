import { NextResponse, type NextRequest } from "next/server";
import { appOrigin, supabaseConfig } from "@/lib/supabase/config";
import { createSupabase } from "@/lib/supabase/server";
import { loginNext } from "@/lib/login-next";

export async function GET(request: NextRequest) {
  const origin = appOrigin() ?? request.nextUrl.origin;
  const code = request.nextUrl.searchParams.get("code");
  const next = loginNext(request.nextUrl.searchParams.get("next"));
  const retry = (reason: string) => `/login?reason=${reason}${next ? `&next=${encodeURIComponent(next)}` : ""}`;
  const go = (path: string) => NextResponse.redirect(new URL(path, origin), {
    headers: { "Cache-Control": "private, no-store" },
  });
  if (!code || !appOrigin() || !supabaseConfig()) return go(retry("auth"));

  const supabase = await createSupabase();
  const { error: exchangeError } = await supabase.auth.exchangeCodeForSession(code);
  if (exchangeError) return go(retry("auth"));

  const { data, error } = await supabase.rpc("bind_member");
  if (error || !data) {
    await supabase.auth.signOut({ scope: "local" });
    return go(retry(error ? "auth" : "unlisted"));
  }
  const consent = await supabase.rpc("get_my_consents");
  if (consent.error) return go(retry("auth"));
  if (consent.data?.enforced && !consent.data?.terms) return go(`/consent${next ? `?next=${encodeURIComponent(next)}` : ""}`);
  return go(next ?? (data.role === "owner" || data.role === "staff" ? "/admin" : "/"));
}

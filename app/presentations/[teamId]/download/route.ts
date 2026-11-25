import { getMembership, getConsent } from "@/lib/auth";
import { createClient } from "@supabase/supabase-js";
import { supabaseConfig } from "@/lib/supabase/config";
import { NextResponse } from "next/server";
import { PDF_BUCKET } from "../../pdf";
import { ZIP_BUCKET } from "../../zip";

const headers = { "Cache-Control": "private, no-store", "Referrer-Policy": "no-referrer" };

export async function GET(request: Request, { params }: { params: Promise<{ teamId: string }> }) {
  const membership = await getMembership();
  if (membership.status !== "active") return NextResponse.redirect(new URL("/login", request.url), { headers });
  const consent = await getConsent();
  if (consent.enforced && !consent.terms) return NextResponse.redirect(new URL("/consent", request.url), { headers });
  const { teamId } = await params;
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(teamId)) {
    return new Response("발표자료를 찾을 수 없습니다.", { status: 404, headers });
  }

  const query = new URL(request.url).searchParams;
  const zip = query.get("file") === "zip";
  const { data, error } = zip
    ? await membership.supabase.rpc("get_presentation_zips", { p_download_team: teamId })
    : await membership.supabase.rpc("get_presentation_file", { p_team_id: teamId });
  if (error) return new Response("발표자료를 불러오지 못했습니다. 다시 시도해 주세요.", { status: 503, headers });
  if (!data) return new Response("발표자료를 찾을 수 없습니다.", { status: 404, headers });

  const view = !zip && query.get("view") === "1";
  const config = supabaseConfig();
  const secret = process.env.SUPABASE_SECRET_KEY;
  if (!config || !secret) return new Response("발표자료 설정을 확인해 주세요.", { status: 503, headers });
  // The guarded RPC above determines the file and durably logs operator access before signing.
  const service = createClient(config.url, secret, { auth: { persistSession: false, autoRefreshToken: false } });
  const signed = await service.storage.from(zip ? ZIP_BUCKET : PDF_BUCKET)
    .createSignedUrl(data.current_path, 60, view ? undefined : { download: data.file_name });
  if (signed.error || !signed.data) return new Response("발표자료를 불러오지 못했습니다. 다시 시도해 주세요.", { status: 503, headers });
  return NextResponse.redirect(signed.data.signedUrl, { headers });
}

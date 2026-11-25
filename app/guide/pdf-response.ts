import { getMembership } from "@/lib/auth";
import { guideRevision } from "@/lib/user-guides";
import { NextResponse } from "next/server";

const headers = { "Cache-Control": "private, no-store", "Referrer-Policy": "no-referrer", "X-Content-Type-Options": "nosniff" };

export async function guidePdf(request: Request, audience: "participant" | "staff") {
  const membership = await getMembership();
  if (membership.status !== "active") return NextResponse.redirect(new URL("/login", request.url), { headers });
  if (audience === "staff" && membership.member.role === "participant") return new Response("운영진만 볼 수 있는 안내입니다.", { status: 403, headers });
  const { data, error } = await membership.supabase.storage.from("event-guides").download(`${guideRevision}/${audience}.pdf`);
  if (error || !data) return new Response("PDF를 불러오지 못했습니다. 사용안내 화면에서 같은 내용을 읽거나 잠시 후 다시 시도해 주세요.", { status: 503, headers });
  return new Response(data, { headers: { ...headers, "Content-Type": "application/pdf", "Content-Disposition": `inline; filename="gwayook-${audience}-guide.pdf"` } });
}

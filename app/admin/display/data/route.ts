import { getMembership } from "@/lib/auth";
import { getDisplaySnapshot } from "../data";

const headers = { "Cache-Control": "private, no-store", Vary: "Cookie" };

export async function GET() {
  try {
    const membership = await getMembership();
    if (membership.status !== "active") return Response.json({ error: "로그인이 필요합니다." }, { status: 401, headers });
    if (membership.member.role === "participant") return Response.json({ error: "운영진 권한이 필요합니다." }, { status: 403, headers });
    return Response.json(await getDisplaySnapshot(membership.supabase), { headers });
  } catch {
    return Response.json({ error: "현황을 갱신하지 못했습니다." }, { status: 503, headers });
  }
}

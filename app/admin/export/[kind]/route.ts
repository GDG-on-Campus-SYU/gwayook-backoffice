import { getMembership } from "@/lib/auth";
import { exportCsv, exportOptions } from "@/lib/csv-export";

const headers = { "Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff" };

export async function GET(_request: Request, { params }: { params: Promise<{ kind: string }> }) {
  const membership = await getMembership();
  if (membership.status !== "active") return new Response("로그인이 필요합니다.", { status: 401, headers });
  if (membership.member.role === "participant") return new Response("운영진 권한이 필요합니다.", { status: 403, headers });
  const { kind } = await params;
  const option = exportOptions.find((entry) => entry.kind === kind);
  if (!option) return new Response("내보낼 항목을 찾을 수 없습니다.", { status: 404, headers });
  const { data, error } = await membership.supabase.rpc("get_event_export", { p_kind: option.kind });
  if (error) return new Response(error.code === "22023" || error.code === "42501" ? error.message : "내보내기에 실패했습니다. 다시 시도해 주세요.", {
    status: error.code === "42501" ? 403 : error.code === "22023" ? 409 : 503, headers,
  });
  try {
    return new Response(exportCsv(data, option.kind), { headers: {
      ...headers, "Content-Type": "text/csv; charset=utf-8", "Content-Disposition": `attachment; filename="gwayook-${option.kind}.csv"`,
    } });
  } catch {
    return new Response("내보낼 자료를 확인하지 못했습니다. 새로고침한 뒤 다시 시도해 주세요.", { status: 503, headers });
  }
}

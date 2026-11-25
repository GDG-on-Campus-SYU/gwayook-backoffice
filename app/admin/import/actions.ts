"use server";

import { revalidatePath } from "next/cache";
import { requireStaff } from "@/lib/auth";
import { MAX_ROSTER_ROWS, type RosterPreview, type RosterRow } from "@/lib/roster-xlsx";

function failed(message: string): RosterPreview {
  return { revision: "", rows: [], new_teams: [], errors: [message] };
}

async function runImport(rows: RosterRow[], revision?: string): Promise<RosterPreview> {
  const { supabase } = await requireStaff();
  if (!Array.isArray(rows) || !rows.length || rows.length > MAX_ROSTER_ROWS) {
    return failed(`가져올 참가자 행을 1~${MAX_ROSTER_ROWS}개로 맞춰 주세요.`);
  }
  const { data, error } = revision === undefined
    ? await supabase.rpc("roster_preview", { p_rows: rows })
    : await supabase.rpc("roster_apply", { p_rows: rows, p_revision: revision });

  if (error?.code === "42501") return failed("명단을 관리할 권한이 없습니다.");
  if (error || !data) return failed("명단을 처리하지 못했습니다. 잠시 후 다시 시도해 주세요.");
  const result = data as RosterPreview;
  if (revision !== undefined && !result.errors.length) revalidatePath("/admin", "layout");
  return result;
}

export async function previewRoster(rows: RosterRow[]) {
  return runImport(rows);
}

export async function applyRoster(rows: RosterRow[], revision: string) {
  if (typeof revision !== "string" || !revision || revision.length > 128) {
    return failed("명단을 다시 미리보기 해 주세요.");
  }
  return runImport(rows, revision);
}

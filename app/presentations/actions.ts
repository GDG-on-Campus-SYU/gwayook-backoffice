"use server";

import { createClient } from "@supabase/supabase-js";
import { revalidatePath } from "next/cache";
import { requireMember, type Member } from "@/lib/auth";
import { supabaseConfig } from "@/lib/supabase/config";
import { looksLikePdf, MAX_PDF_BYTES, PDF_BUCKET, validPdfFileName } from "./pdf";
import { looksLikeZip, MAX_ZIP_BYTES, ZIP_BUCKET, validZipFileName } from "./zip";

type FileKind = "pdf" | "zip";
const configurationMessage = "발표자료 제출 설정을 확인하려면 운영진에게 문의해 주세요.";

function submissionService() {
  const config = supabaseConfig();
  const secret = process.env.SUPABASE_SECRET_KEY;
  return config && secret ? createClient(config.url, secret, {
    auth: { autoRefreshToken: false, persistSession: false },
  }) : null;
}

function submissionError(error: { code?: string; message: string }) {
  return error.code === "22023" || error.code === "42501"
    ? error.message
    : "발표자료를 처리하지 못했습니다. 잠시 후 다시 시도해 주세요.";
}

function isTeamPath(member: Member, path: string, kind: FileKind) {
  return member.role === "participant" && member.team_id && typeof path === "string"
    && path.startsWith(`${member.team_id}/`)
    && path.endsWith(`.${kind}`) && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(pdf|zip)$/.test(path.slice(37));
}

async function cleanTeamUploads(service: NonNullable<ReturnType<typeof submissionService>>, teamId: string, kind: FileKind) {
  // A later upload retries cleanup without rolling back the accepted submission.
  try {
    const { data, error } = await service.rpc(kind === "zip" ? "unreferenced_presentation_zips" : "unreferenced_presentation_files", { p_team_id: teamId });
    if (!error && Array.isArray(data) && data.length) await service.storage.from(kind === "zip" ? ZIP_BUCKET : PDF_BUCKET).remove(data);
  } catch {
    return;
  }
}

export async function preparePresentation(version: number, name: string, size: number, kind: FileKind = "pdf") {
  const { member, userId } = await requireMember();
  if (kind !== "pdf" && kind !== "zip") return { error: "파일 유형을 확인해 주세요." };
  const zip = kind === "zip";
  if (typeof name !== "string" || !(zip ? validZipFileName(name) : validPdfFileName(name)) || !Number.isInteger(size)
    || size < 1 || size > (zip ? MAX_ZIP_BYTES : MAX_PDF_BYTES) || !Number.isInteger(version) || version < 0 || version >= 2_147_483_647) {
    return { error: zip ? "20MB 이하 ZIP 파일을 선택해 주세요." : "5MB 이하 PDF 파일을 선택해 주세요." };
  }
  if (member.role !== "participant" || !member.team_id) return { error: "팀 대표자만 제출할 수 있습니다." };
  const service = submissionService();
  if (!service) return { error: configurationMessage };

  const { data, error } = await service.rpc(zip ? "prepare_presentation_zip" : "prepare_presentation", {
    p_member_id: member.id, p_auth_user_id: userId, p_version: version, p_file_name: name, p_size_bytes: size,
  });
  if (error || typeof data !== "string") return { error: error ? submissionError(error) : configurationMessage };
  await cleanTeamUploads(service, member.team_id, kind);
  return { path: data };
}

export async function finishPresentation(path: string, kind: FileKind = "pdf") {
  const { supabase, member, userId } = await requireMember();
  if (!isTeamPath(member, path, kind)) return { error: "현재 팀의 업로드를 다시 확인해 주세요." };
  const service = submissionService();
  if (!service) return { error: configurationMessage };

  const zip = kind === "zip";
  const { data: file, error: readError } = await supabase.storage.from(zip ? ZIP_BUCKET : PDF_BUCKET).download(path);
  const validate = zip ? looksLikeZip : looksLikePdf;
  if (readError || !file || file.size > (zip ? MAX_ZIP_BYTES : MAX_PDF_BYTES) || !validate(new Uint8Array(await file.arrayBuffer()))) {
    return { error: zip ? "저장된 ZIP을 확인할 수 없습니다. 올바른 ZIP 파일을 선택해 주세요." : "저장된 PDF를 확인할 수 없습니다. 올바른 파일로 다시 시도해 주세요." };
  }

  const { data, error } = await service.rpc(zip ? "complete_presentation_zip" : "complete_presentation", {
    p_member_id: member.id, p_auth_user_id: userId, p_path: path, p_verified_size: file.size,
  });
  if (error || typeof data !== "string") return { error: error ? submissionError(error) : configurationMessage };
  await cleanTeamUploads(service, data, kind);
  revalidatePath("/presentations");
  revalidatePath("/team");
  revalidatePath("/");
  revalidatePath("/admin", "layout");
  return { saved: true };
}

export async function discardPresentation(path: string, kind: FileKind = "pdf") {
  const { member, userId } = await requireMember();
  if (!isTeamPath(member, path, kind)) return;
  const service = submissionService();
  if (!service) return;
  const { data } = await service.rpc(kind === "zip" ? "abandon_presentation_zip" : "abandon_presentation", { p_member_id: member.id, p_auth_user_id: userId, p_path: path });
  if (typeof data === "string") await cleanTeamUploads(service, data, kind);
}

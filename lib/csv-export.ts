export const exportOptions = [
  { kind: "teams", label: "팀·참가자", description: "팀 배정, 대표자, 참가자 명단과 학교·로그인 이메일" },
  { kind: "attendance", label: "출석·체크인", description: "학교, 출석 상태, 체크인 시각, 기록 담당자와 메모" },
  { kind: "gsa", label: "GSA 확인 기록", description: "가입 확인 상태, 별도 GSA 이메일, 확인 담당자와 메모" },
  { kind: "bingo", label: "빙고 회차별 결과", description: "회차별 완성 순위, 완료 시각, 당시 팀과 검토 표시" },
  { kind: "voting", label: "투표 집계", description: "마감 확정 후 팀별 본투표·가산점·합계·재투표 집계" },
  { kind: "awards", label: "수상 결과", description: "결과 공개 후 최종 수상 순위·수상명·동점 결정 사유" },
] as const;

export type ExportKind = typeof exportOptions[number]["kind"];

function csvCell(value: unknown): string {
  if (value !== null && typeof value !== "string" && (typeof value !== "number" || !Number.isFinite(value))) {
    throw new Error("Invalid CSV value");
  }
  let text = value === null ? "" : String(value);
  // Keep user-entered cells as text when a spreadsheet could interpret a formula.
  if (typeof value === "string" && (/^[\s\u0000-\u001f]*[=+\-@＝＋－＠]/u.test(text) || /^[\t\r\n]/.test(text))) text = `'${text}`;
  return `"${text.replaceAll('"', '""')}"`;
}

export function exportCsv(payload: unknown, kind: ExportKind): string {
  if (!payload || typeof payload !== "object" || !("kind" in payload) || payload.kind !== kind ||
      !("headers" in payload) || !Array.isArray(payload.headers) || !payload.headers.length ||
      !payload.headers.every((cell) => typeof cell === "string") || !("rows" in payload) || !Array.isArray(payload.rows)) {
    throw new Error("Invalid CSV export");
  }
  const width = payload.headers.length;
  const lines = [payload.headers.map(csvCell).join(",")];
  for (const row of payload.rows) {
    if (!Array.isArray(row) || row.length !== width) throw new Error("Invalid CSV row");
    lines.push(row.map(csvCell).join(","));
  }
  return `\uFEFF${lines.join("\r\n")}\r\n`;
}

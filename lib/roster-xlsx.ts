export const MAX_ROSTER_ROWS = 200;
export const MAX_WORKBOOK_BYTES = 2 * 1024 * 1024;

export type RosterRow = {
  row: number;
  name: string;
  email: string;
  school?: string | null;
  team: string | null;
  representative: boolean | null;
};

type MemberValues = { name: string; school: string | null; team: string | null; representative: boolean };

export type RosterPreview = {
  revision: string;
  rows: (Omit<RosterRow, "representative" | "school"> & {
    school: string | null;
    representative: boolean;
    action: "insert" | "update" | "unchanged";
    before?: MemberValues | null;
  })[];
  new_teams: string[];
  errors: string[];
};

export const rosterColumns = {
  name: "이름",
  email: "로그인용 Google 이메일",
  school: "학교",
  team: "팀명",
  representative: "대표자 여부",
} as const;

type Column = keyof typeof rosterColumns;
export type ColumnMapping = Record<Column, number>;

const headerAliases: Record<Column, readonly string[]> = {
  name: ["이름", "성명", "참가자 이름", "이름을 입력해주세요.", "name"],
  email: ["로그인용 Google 이메일", "Google 계정 이메일", "이메일 주소", "이메일", "email"],
  school: ["학교", "학교명", "소속 학교", "대학교", "소속 대학교", "school", "university"],
  team: ["팀명", "팀 이름", "팀", "team"],
  representative: ["대표자 여부", "팀 대표자", "대표자", "대표 여부", "팀장 여부", "representative"],
};

function textValue(value: unknown) {
  return typeof value === "string" ? value.trim() : "";
}

function normalizeHeader(value: unknown) {
  return textValue(value).replace(/\s+/g, "").toLowerCase();
}

function findColumn(headers: readonly unknown[], aliases: readonly string[]) {
  for (const alias of aliases) {
    const header = normalizeHeader(alias);
    const index = headers.findIndex((cell) => normalizeHeader(cell) === header);
    if (index !== -1 && index === headers.findLastIndex((cell) => normalizeHeader(cell) === header)) return index;
  }
  return -1;
}

export function guessColumns(headers: readonly unknown[]): ColumnMapping {
  return {
    name: findColumn(headers, headerAliases.name),
    email: findColumn(headers, headerAliases.email),
    school: findColumn(headers, headerAliases.school),
    team: findColumn(headers, headerAliases.team),
    representative: findColumn(headers, headerAliases.representative),
  };
}

function parseRepresentative(value: unknown) {
  if (value == null) return null;
  if (typeof value === "boolean") return value;
  if (typeof value !== "string" && typeof value !== "number") return undefined;
  const normalized = String(value).trim().toLowerCase();
  if (!normalized) return null;
  if (["예", "네", "대표", "대표자", "o", "yes", "true", "1"].includes(normalized)) return true;
  if (["아니오", "아니요", "팀원", "x", "no", "false", "0"].includes(normalized)) return false;
  return undefined;
}

export function extractRoster(data: readonly (readonly unknown[])[], mapping: ColumnMapping) {
  const errors: string[] = [];
  const rows: RosterRow[] = [];
  const headers = data[0] ?? [];
  const required = [mapping.name, mapping.email];
  const selected = [...required, ...[mapping.school, mapping.team, mapping.representative].filter((index) => index !== -1)];
  if (selected.some((index) => !Number.isInteger(index) || index < 0 || index >= headers.length)) {
    return { rows, errors: ["이름과 로그인용 Google 이메일에 해당하는 열을 선택해 주세요."] };
  }
  if (new Set(selected).size !== selected.length) {
    return { rows, errors: ["각 항목에 서로 다른 열을 선택해 주세요."] };
  }

  const emails = new Map<string, number>();
  const representatives = new Map<string, number>();
  let rowCount = 0;
  for (let i = 1; i < data.length; i++) {
    const cells = data[i];
    if (cells.every((value) => value == null || (typeof value === "string" && !value.trim()))) continue;
    if (++rowCount > MAX_ROSTER_ROWS) {
      return { rows: [], errors: [`명단은 한 번에 ${MAX_ROSTER_ROWS}명까지 가져올 수 있습니다.`] };
    }

    const row = i + 1;
    const name = textValue(cells[mapping.name]);
    const email = textValue(cells[mapping.email]).toLowerCase();
    const schoolCell = cells[mapping.school];
    const school = textValue(schoolCell);
    const teamCell = cells[mapping.team];
    const team = (typeof teamCell === "number" && Number.isFinite(teamCell) ? String(teamCell) : textValue(teamCell)) || null;
    const representative = parseRepresentative(cells[mapping.representative]);
    const errorCount = errors.length;
    if (!name || name.length > 100) errors.push(`${row}행: 이름을 1~100자로 입력해 주세요.`);
    if (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      errors.push(`${row}행: 로그인용 이메일 주소를 확인해 주세요.`);
    }
    if ((schoolCell != null && typeof schoolCell !== "string") || school.length > 100) {
      errors.push(`${row}행: 학교는 100자 이하의 문자로 입력하거나 비워 주세요.`);
    }
    const invalidTeam = teamCell != null && typeof teamCell !== "string" &&
      !(typeof teamCell === "number" && Number.isFinite(teamCell));
    if (invalidTeam || (team && team.length > 100)) {
      errors.push(`${row}행: 팀명은 100자 이하의 문자 또는 숫자로 입력해 주세요.`);
    }
    if (representative === undefined) errors.push(`${row}행: 대표자 여부는 예·아니오 또는 빈칸으로 입력해 주세요.`);

    if (email) {
      const first = emails.get(email);
      if (first !== undefined) errors.push(`${row}행: ${first}행과 로그인 이메일이 같습니다.`);
      else emails.set(email, row);
    }
    if (team && representative === true) {
      const first = representatives.get(team.toLowerCase());
      if (first !== undefined) errors.push(`${row}행: ${first}행과 같은 팀에 대표자가 지정되어 있습니다.`);
      else representatives.set(team.toLowerCase(), row);
    }
    if (errors.length === errorCount && representative !== undefined) rows.push({ row, name, email, ...(school ? { school } : {}), team, representative });
  }

  if (!rowCount) errors.push("시트에 가져올 참가자 행이 없습니다.");
  return { rows, errors };
}

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const maxBingoBonus = 32767;

export function normalizeBingoToken(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const token = value.trim();
  if (uuid.test(token)) return token.toLowerCase();
  const code = token.replace(/[ -]/g, "").toUpperCase();
  return /^[0-9A-F]{12}$/.test(code) ? code : null;
}

export function parseBingoRound(value: unknown): number | null {
  if (typeof value !== "string") return null;
  const round = Number(value);
  return Number.isInteger(round) && round > 0 && round <= 2147483647 && String(round) === value ? round : null;
}

export function bingoEndTime(closesAt: string | null, closedAt: string | null): string | null {
  return closedAt && (!closesAt || Date.parse(closedAt) < Date.parse(closesAt)) ? closedAt : closesAt;
}

export function formatBingoElapsed(seconds: number | null): string {
  if (seconds === null) return "—";
  const milliseconds = Math.floor(seconds * 1000);
  return `${Math.floor(milliseconds / 60000)}분 ${((milliseconds % 60000) / 1000).toFixed(3)}초`;
}

export function parseBingoConfig(form: FormData): { questions: string[]; prize: string } | null {
  const questions = form.getAll("question");
  const prize = form.get("prize");
  if (questions.length !== 25 || !questions.every((value): value is string => typeof value === "string" && value.trim().length <= 200) ||
    typeof prize !== "string" || prize.trim().length > 500) return null;
  return { questions: questions.map((question) => question.trim()), prize: prize.trim() };
}

export function parseBingoBonus(form: FormData) {
  if (["team_id", "points", "expected_points"].some((field) => form.getAll(field).length !== 1)) return null;
  const teamId = form.get("team_id");
  const parsePoints = (value: FormDataEntryValue | null) => {
    if (typeof value !== "string" || !/^\d+$/.test(value)) return null;
    const points = Number(value);
    return points <= maxBingoBonus ? points : null;
  };
  const points = parsePoints(form.get("points"));
  const expectedPoints = parsePoints(form.get("expected_points"));
  if (typeof teamId !== "string" || !uuid.test(teamId) || points === null || expectedPoints === null) return null;
  return { teamId, points, expectedPoints };
}

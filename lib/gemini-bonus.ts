export function parseGeminiBonus(form: FormData): { teamId: string; approved: boolean; note: string | null } | null {
  if (["team_id", "approved", "note"].some((field) => form.getAll(field).length !== 1)) return null;
  const team = form.get("team_id");
  const approved = form.get("approved");
  const note = form.get("note");
  if (typeof team !== "string" || !/^[\da-f]{8}(?:-[\da-f]{4}){3}-[\da-f]{12}$/i.test(team)
    || (approved !== "true" && approved !== "false") || typeof note !== "string") return null;
  const reason = note.trim();
  if (reason.length > 500 || (approved === "true" && !reason)) return null;
  return { teamId: team.toLowerCase(), approved: approved === "true", note: reason || null };
}

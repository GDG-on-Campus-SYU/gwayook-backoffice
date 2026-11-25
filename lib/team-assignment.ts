export type TeamAssignmentMember = { id: string; expected_team_id: string | null };
export type TeamAssignment = { teamId: string; members: TeamAssignmentMember[]; confirmMove: boolean };
export type TeamRemoval = { teamId: string; members: TeamAssignmentMember[]; expectedRepresentativeId: string | null; confirmRepresentative: boolean };

const uuid = /^[\da-f]{8}-[\da-f]{4}-[\da-f]{4}-[\da-f]{4}-[\da-f]{12}$/i;

export function parseTeamAssignment(form: FormData): TeamAssignment | null {
  const teamId = form.get("team_id");
  const rawMembers = form.get("members");
  if (typeof teamId !== "string" || !uuid.test(teamId) || typeof rawMembers !== "string" || rawMembers.length > 25_000) return null;

  let values: unknown;
  try { values = JSON.parse(rawMembers); } catch { return null; }
  if (!Array.isArray(values) || values.length < 1 || values.length > 200) return null;
  const members: TeamAssignmentMember[] = [];
  const ids = new Set<string>();
  for (const value of values) {
    if (!value || typeof value !== "object" || typeof value.id !== "string" || !uuid.test(value.id)
      || (value.expected_team_id !== null && (typeof value.expected_team_id !== "string" || !uuid.test(value.expected_team_id)))) return null;
    const id = value.id.toLowerCase();
    if (ids.has(id)) return null;
    ids.add(id);
    members.push({ id, expected_team_id: value.expected_team_id?.toLowerCase() ?? null });
  }
  return { teamId: teamId.toLowerCase(), members, confirmMove: form.get("confirm_move") === "on" };
}

export function parseTeamRemoval(form: FormData): TeamRemoval | null {
  const selection = parseTeamAssignment(form);
  const representative = form.get("expected_representative_id");
  if (!selection || selection.members.some((person) => person.expected_team_id !== selection.teamId)
    || typeof representative !== "string" || (representative !== "" && !uuid.test(representative))) return null;
  const expectedRepresentativeId = representative.toLowerCase() || null;
  const confirmRepresentative = form.get("confirm_representative") === "on";
  if (selection.members.some((person) => person.id === expectedRepresentativeId) && !confirmRepresentative) return null;
  return { teamId: selection.teamId, members: selection.members, expectedRepresentativeId, confirmRepresentative };
}

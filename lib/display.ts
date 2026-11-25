import type { CountdownPhase } from "./countdown";

export type DisplayTeam = { id: string; name: string; submittedAt: string | null };
export type DisplaySnapshot = {
  serverNow: number;
  event: { name: string; date: string; submissionDeadline: string | null };
  vote: { status: CountdownPhase; isRunoff?: boolean; opensAt: string | null; deadline: string | null; voted: number; eligible: number };
  teams: DisplayTeam[];
};

export function displayTeams(teams: readonly DisplayTeam[]) {
  return {
    missing: teams.filter((team) => team.submittedAt === null),
    submitted: teams.filter((team) => team.submittedAt !== null),
  };
}

export async function loadDisplaySnapshot(signal: AbortSignal, fetcher: typeof fetch = fetch) {
  try {
    const response = await fetcher("/admin/display/data", {
      cache: "no-store", credentials: "same-origin", signal,
    });
    if (response.status === 401 || response.status === 403) return { kind: "denied" } as const;
    if (!response.ok) return { kind: "unavailable" } as const;
    const data: DisplaySnapshot = await response.json();
    if (!data || !Number.isFinite(data.serverNow) || !data.event || !data.vote || !Array.isArray(data.teams)) {
      return { kind: "unavailable" } as const;
    }
    return { kind: "updated", data } as const;
  } catch {
    return { kind: "unavailable" } as const;
  }
}

import type { CountdownPhase } from "./countdown";

type VoteSummary = {
  status: CountdownPhase;
  opens_at: string | null;
  closes_at: string | null;
  eligible?: boolean;
  voted?: boolean;
  eligible_count?: number | null;
  voted_count?: number | null;
};
export type VoteOverview = VoteSummary & { runoff?: VoteSummary | null };

export function currentVote(vote: VoteOverview) {
  const isRunoff = vote.status !== "published" && Boolean(vote.runoff);
  return { ...(isRunoff ? vote.runoff! : vote), isRunoff };
}

export function confirmedVoterCount(form: FormData): number | null {
  const [value, ...other] = form.getAll("confirm");
  const count = Number(value);
  if (other.length || !Number.isInteger(count) || count < 1 || count > 2147483647 || String(count) !== value) return null;
  return count;
}

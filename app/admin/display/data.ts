import type { SupabaseClient } from "@supabase/supabase-js";
import type { DisplaySnapshot } from "@/lib/display";
import { listPresentations } from "../../presentations/data";
import { currentVote, type VoteOverview } from "@/lib/vote-overview";

export async function getDisplaySnapshot(supabase: SupabaseClient): Promise<DisplaySnapshot> {
  const [teams, settings, voting] = await Promise.all([
    listPresentations(supabase),
    supabase.from("event_settings").select("name,event_date,submission_deadline").single(),
    supabase.rpc("get_vote_overview"),
  ]);
  if (settings.error || voting.error || !settings.data || !voting.data) throw new Error("Could not load event display");
  const vote = currentVote(voting.data as VoteOverview);
  return {
    serverNow: Date.now(),
    event: { name: settings.data.name, date: settings.data.event_date, submissionDeadline: settings.data.submission_deadline },
    vote: { status: vote.status, isRunoff: vote.isRunoff, opensAt: vote.opens_at, deadline: vote.closes_at, voted: vote.voted_count ?? 0, eligible: vote.eligible_count ?? 0 },
    teams: teams.map((team) => ({ id: team.id, name: team.name, submittedAt: team.submission?.submitted_at ?? null })),
  };
}

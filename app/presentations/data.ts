import type { SupabaseClient } from "@supabase/supabase-js";

type ZipAttachment = { team_id: string; file_name: string | null; version: number };

export async function listZipAttachments(supabase: SupabaseClient) {
  const { data, error } = await supabase.rpc("get_presentation_zips");
  if (error) throw new Error("Could not load ZIP attachments");
  return new Map((data as ZipAttachment[]).map((attachment) => [attachment.team_id, attachment]));
}

export type Submission = {
  team_id: string;
  file_name: string;
  size_bytes: number;
  submitted_at: string;
  submitted_by: string;
  version: number;
};

type PresentationTeam = {
  id: string;
  name: string;
  representative_id: string | null;
  presentation_order: number | null;
};

export async function listPresentations(supabase: SupabaseClient) {
  const [teams, submissions] = await Promise.all([
    supabase.from("teams").select("id,name,representative_id,presentation_order")
      .order("presentation_order", { nullsFirst: false }).order("name").returns<PresentationTeam[]>(),
    supabase.rpc("get_presentation_list"),
  ]);
  if (teams.error || submissions.error) throw new Error("Could not load presentation submissions");
  const byTeam = new Map((submissions.data as Submission[]).map((submission) => [submission.team_id, submission]));
  return teams.data.map((team) => ({ ...team, submission: byTeam.get(team.id) }));
}

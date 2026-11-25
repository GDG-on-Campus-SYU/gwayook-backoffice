import { cache } from "react";
import { requireMember } from "@/lib/auth";

export const getBingoStatus = cache(async () => {
  const { supabase } = await requireMember();
  const { data, error } = await supabase.rpc("get_bingo_status");
  if (error) throw new Error("Could not load bingo status");
  return data as { status: "hidden" | "open" | "closed"; opens_at?: string; closes_at?: string };
});

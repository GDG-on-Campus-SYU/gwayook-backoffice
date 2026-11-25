import { requireStaff } from "@/lib/auth";
import { getDisplaySnapshot } from "./data";
import { DisplayBoard } from "./display-board";

export const metadata = { title: "운영 현황판" };

export default async function DisplayPage() {
  const { supabase } = await requireStaff();
  return <DisplayBoard initial={await getDisplaySnapshot(supabase)} />;
}

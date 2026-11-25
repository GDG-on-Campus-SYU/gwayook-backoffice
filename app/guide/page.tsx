import { requireMember } from "@/lib/auth";
import { participantGuide } from "@/lib/user-guides";
import { Header } from "../ui";
import { GuideContent } from "./content";

export const metadata = { title: "참가자 사용안내" };

export default async function GuidePage() {
  const { member } = await requireMember();
  return <><Header admin={member.role !== "participant"} /><main id="participant-main" tabIndex={-1} className="content stack"><GuideContent guide={participantGuide} pdfHref="/guide/pdf" /></main></>;
}

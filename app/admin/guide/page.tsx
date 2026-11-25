import Link from "next/link";
import { requireStaff } from "@/lib/auth";
import { staffGuide } from "@/lib/user-guides";
import { GuideContent } from "../../guide/content";

export const metadata = { title: "운영진 사용안내" };

export default async function AdminGuidePage() {
  await requireStaff();
  return <><GuideContent guide={staffGuide} pdfHref="/admin/guide/pdf" /><Link className="text-link" href="/guide">참가자 사용안내도 확인하기</Link></>;
}

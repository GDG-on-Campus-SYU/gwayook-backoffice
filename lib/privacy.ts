import { loginNext } from "./login-next.ts";

export const agreementVersion = "2026-11-16.1";

export const sharingNotices = [
  { key: "team", title: "팀원에게 내 이름 공유", recipient: "같은 팀에 등록된 참가자", purpose: "팀 구성 확인과 협업", fields: "이름, 팀, 대표자 여부", effect: "동의하지 않으면 다른 팀원에게 이름을 숨깁니다. 팀 배정과 투표는 유지됩니다." },
  { key: "presentation", title: "발표자료 공유", recipient: "행사에 등록된 참가자", purpose: "발표 평가와 투표", fields: "대표자가 제출한 PDF, 파일명, 팀명과 PDF에 포함된 본인의 정보", effect: "동의하지 않으면 PDF는 운영진에게만 제출·열람되며 참가자에게 공유되지 않습니다. 파일 속 다른 사람의 개인정보는 별도 권한을 확보하거나 제거해 주세요." },
  { key: "bingo", title: "빙고 상호 확인 정보 공유", recipient: "QR·코드로 서로 확인하는 등록 참가자", purpose: "대화 후 문항 확인과 빙고 인증", fields: "이름, 확인 문항, 확인 여부·시각", effect: "동의하지 않으면 QR 빙고에 참여할 수 없습니다. 다른 행사 기능에는 영향이 없습니다." },
] as const;

export type ConsentState = {
  version: string; terms: boolean; team: boolean; presentation: boolean; bingo: boolean;
  enforced: boolean; history: { kind: string; version: string; accepted: boolean; recorded_at: string }[];
};

export function parseConsent(form: FormData) {
  if (form.get("version") !== agreementVersion) return { error: "안내 내용이 변경되었습니다. 새로고침 후 다시 확인해 주세요." } as const;
  if (form.get("terms") !== "on") return { error: "앱 이용약관을 확인하고 동의해 주세요. 동의하지 않으면 로그아웃할 수 있습니다." } as const;
  return { values: Object.fromEntries(sharingNotices.map(({ key }) => [key, form.get(key) === "on"])) as Record<"team" | "presentation" | "bingo", boolean> } as const;
}

export function consentDestination(next: unknown, participant: boolean, bingo: boolean): string {
  const destination = loginNext(next);
  if (destination && participant && !bingo) return "/bingo";
  return destination ?? (participant ? "/" : "/admin");
}

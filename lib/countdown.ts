export type CountdownPhase = "draft" | "scheduled" | "open" | "expired" | "closed" | "published";

export function getCountdown(deadline: string | null, now: number, phase: CountdownPhase = "open") {
  if (phase === "published") return { status: "published", text: "결과 공개", seconds: null } as const;
  if (phase === "closed" || phase === "expired") return { status: "closed", text: "마감됨", seconds: null } as const;
  const end = deadline ? Date.parse(deadline) : NaN;
  if (!Number.isFinite(end)) return { status: "unscheduled", text: "마감 미정", seconds: null } as const;
  if (phase === "draft") return { status: "pending", text: "준비 중", seconds: null } as const;
  const seconds = Math.max(0, Math.ceil((end - now) / 1000));
  if (seconds === 0) return phase === "scheduled"
    ? { status: "starting", text: "시작 확인 중", seconds: 0 } as const
    : { status: "closed", text: "마감됨", seconds: 0 } as const;
  const days = Math.floor(seconds / 86400);
  const hours = Math.floor(seconds % 86400 / 3600);
  const minutes = Math.floor(seconds % 3600 / 60);
  const clock = [hours, minutes, seconds % 60].map((value) => String(value).padStart(2, "0")).join(":");
  return { status: "counting", text: `${days ? `${days}일 ` : ""}${clock}`, seconds } as const;
}

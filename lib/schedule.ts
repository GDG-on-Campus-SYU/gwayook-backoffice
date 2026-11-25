import { parseEventInput } from "./event-time.ts";

export type ScheduleItem = {
  id: string; title: string; description: string | null; location: string | null;
  starts_at: string | null; ends_at: string | null;
};
export type ScheduleAdminItem = ScheduleItem & { version: number; updated_at: string };
export type ScheduleDetails = { published: boolean; updated_at: string; items: ScheduleItem[] };
export type ScheduleAdmin = Omit<ScheduleDetails, "items"> & { version: number; items: ScheduleAdminItem[] };
export type ScheduleTiming = {
  event_starts_at: string | null; event_ends_at: string | null; submission_deadline: string | null;
  vote_opens_at: string | null; vote_closes_at: string | null;
};

function field(form: FormData, key: string): string | null {
  const values = form.getAll(key);
  return values.length === 1 && typeof values[0] === "string" ? values[0] : null;
}

function version(value: string | null, allowZero = false): number | null {
  if (value === null || !/^(0|[1-9]\d*)$/.test(value)) return null;
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed >= (allowZero ? 0 : 1) && parsed <= 2147483647 ? parsed : null;
}

const uuid = /^[\da-f]{8}(?:-[\da-f]{4}){3}-[\da-f]{12}$/i;

export function parseScheduleItem(form: FormData) {
  const id = field(form, "id");
  const expectedVersion = version(field(form, "version"), id === "");
  const title = field(form, "title")?.trim();
  const description = field(form, "description")?.trim();
  const location = field(form, "location")?.trim();
  const start = field(form, "starts_at");
  const end = field(form, "ends_at");
  if (id === null || (id !== "" && !uuid.test(id)) || expectedVersion === null || (id === "" && expectedVersion !== 0)
    || !title || title.length > 120 || description === undefined || description.length > 2000
    || location === undefined || location.length > 200 || start === null || end === null) return null;
  try {
    const startsAt = parseEventInput(start);
    const endsAt = parseEventInput(end);
    if (endsAt && (!startsAt || Date.parse(endsAt) <= Date.parse(startsAt))) return null;
    return { id: id || null, version: expectedVersion, title, description: description || null,
      location: location || null, startsAt, endsAt };
  } catch { return null; }
}

export function parseScheduleDeletion(form: FormData) {
  const id = field(form, "id");
  const expectedVersion = version(field(form, "version"));
  return id && uuid.test(id) && expectedVersion !== null && field(form, "confirm") === "yes"
    ? { id, version: expectedVersion } : null;
}

export function parseSchedulePublication(form: FormData) {
  const published = field(form, "published");
  const expectedVersion = version(field(form, "version"));
  return (published === "true" || published === "false") && expectedVersion !== null && field(form, "confirm") === "yes"
    ? { published: published === "true", version: expectedVersion } : null;
}

export function scheduleItemPhase(item: ScheduleItem, now: number) {
  if (!item.starts_at) return "unscheduled";
  if (Date.parse(item.starts_at) > now) return "upcoming";
  if (!item.ends_at) return "started";
  return Date.parse(item.ends_at) > now ? "current" : "finished";
}

export function scheduleProgress(items: ScheduleItem[], now: number) {
  const current = items.filter((item) => scheduleItemPhase(item, now) === "current");
  const future = items.filter((item) => scheduleItemPhase(item, now) === "upcoming");
  const nextTime = Math.min(...future.map((item) => Date.parse(item.starts_at!)));
  return { current, next: future.filter((item) => Date.parse(item.starts_at!) === nextTime) };
}

const dateTime = new Intl.DateTimeFormat("ko-KR", {
  timeZone: "Asia/Seoul", month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit", hour12: false,
});
const timeOnly = new Intl.DateTimeFormat("ko-KR", {
  timeZone: "Asia/Seoul", hour: "2-digit", minute: "2-digit", hour12: false,
});
const koreanDay = (value: string) => new Date(Date.parse(value) + 9 * 60 * 60 * 1000).toISOString().slice(0, 10);

export function formatScheduleRange(item: Pick<ScheduleItem, "starts_at" | "ends_at">) {
  if (!item.starts_at) return "시각 미정";
  const start = dateTime.format(new Date(item.starts_at));
  if (!item.ends_at) return `${start} · 종료 미정`;
  return `${start} – ${(koreanDay(item.starts_at) === koreanDay(item.ends_at) ? timeOnly : dateTime).format(new Date(item.ends_at))}`;
}

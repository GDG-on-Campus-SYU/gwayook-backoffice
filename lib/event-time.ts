const dateTime = new Intl.DateTimeFormat("ko-KR", {
  dateStyle: "medium", timeStyle: "short", timeZone: "Asia/Seoul",
});
const dateOnly = new Intl.DateTimeFormat("ko-KR", { dateStyle: "full", timeZone: "Asia/Seoul" });

export function formatEventDate(value: string) {
  return dateOnly.format(new Date(`${value}T00:00:00+09:00`));
}

export function formatEventTime(value: string | null) {
  return value ? dateTime.format(new Date(value)) : "미정";
}

export function localEventInput(value: string | null) {
  if (!value) return "";
  const instant = new Date(value);
  return new Date(instant.getTime() + 9 * 60 * 60 * 1000).toISOString().slice(0, 16);
}

export function parseEventInput(value: string) {
  if (value === "") return null;
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(value)) throw new Error("Invalid time");
  const timestamp = `${value}:00+09:00`;
  if (!Number.isFinite(Date.parse(timestamp)) || localEventInput(timestamp) !== value) throw new Error("Invalid time");
  return timestamp;
}

export function parseEventDate(value: string) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value) || value.startsWith("0000-")) throw new Error("Invalid date");
  parseEventInput(`${value}T00:00`);
  return value;
}

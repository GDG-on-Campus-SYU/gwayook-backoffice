import assert from "node:assert/strict";
import test from "node:test";
import { formatScheduleRange, parseScheduleDeletion, parseScheduleItem, parseSchedulePublication, scheduleItemPhase, scheduleProgress, type ScheduleItem } from "./schedule.ts";

function form(values: Record<string, string> = {}) {
  const result = new FormData();
  for (const [key, value] of Object.entries({ id: "", version: "0", title: "  오프닝  ", description: "행사 소개", location: "서울과학기술대학교", starts_at: "2026-11-24T18:30", ends_at: "2026-11-24T18:35", ...values })) result.set(key, value);
  return result;
}

test("schedule input uses Korean time, optional text/times, and a positive version for edits", () => {
  const parsed = parseScheduleItem(form());
  assert.equal(parsed?.title, "오프닝");
  assert.equal(parsed?.startsAt, "2026-11-24T18:30:00+09:00");
  assert.equal(parseScheduleItem(form({ starts_at: "", ends_at: "", description: " ", location: "" }))?.startsAt, null);
  assert.equal(parseScheduleItem(form({ id: "11111111-1111-1111-1111-111111111111", version: "2" }))?.version, 2);
  const invalid: Record<string, string>[] = [{ title: " " }, { title: "x".repeat(121) }, { description: "x".repeat(2001) }, { location: "x".repeat(201) },
    { starts_at: "2026-11-31T18:30" }, { ends_at: "2026-11-24T18:30" }, { starts_at: "", ends_at: "2026-11-24T18:35" },
    { version: "1" }, { version: "1e0" }, { id: "invalid" }, { id: "11111111-1111-1111-1111-111111111111", version: "0" }];
  for (const change of invalid) {
    assert.equal(parseScheduleItem(form(change)), null);
  }
  const duplicate = form(); duplicate.append("title", "Injected");
  assert.equal(parseScheduleItem(duplicate), null);
  const missing = form(); missing.delete("description");
  assert.equal(parseScheduleItem(missing), null);
});

test("schedule publishing and deletion require an exact version and explicit confirmation", () => {
  const data = form({ id: "11111111-1111-1111-1111-111111111111", version: "3", published: "true", confirm: "yes" });
  assert.deepEqual(parseSchedulePublication(data), { published: true, version: 3 });
  assert.deepEqual(parseScheduleDeletion(data), { id: "11111111-1111-1111-1111-111111111111", version: 3 });
  data.delete("confirm");
  assert.equal(parseSchedulePublication(data), null);
  assert.equal(parseScheduleDeletion(data), null);
  data.set("confirm", "yes"); data.set("version", "2147483648");
  assert.equal(parseSchedulePublication(data), null);
  assert.equal(parseScheduleDeletion(data), null);
});

test("current/next switches at exact boundaries, supports overlaps and does not invent an end", () => {
  const item = (id: string, start: string | null, end: string | null): ScheduleItem => ({ id, title: id, description: null, location: null, starts_at: start, ends_at: end });
  const items = [item("a", "2026-11-24T18:30+09:00", "2026-11-24T18:35+09:00"), item("b", "2026-11-24T18:35+09:00", "2026-11-24T19:00+09:00"),
    item("c", "2026-11-24T18:35+09:00", "2026-11-24T18:40+09:00"), item("unknown", null, null), item("end-unknown", "2026-11-24T18:00+09:00", null)];
  const before = Date.parse("2026-11-24T18:34:59+09:00");
  assert.deepEqual(scheduleProgress(items, before).current.map((x) => x.id), ["a"]);
  assert.deepEqual(scheduleProgress(items, before).next.map((x) => x.id), ["b", "c"]);
  const at = Date.parse("2026-11-24T18:35+09:00");
  assert.equal(scheduleItemPhase(items[0], at), "finished");
  assert.deepEqual(scheduleProgress(items, at).current.map((x) => x.id), ["b", "c"]);
  assert.deepEqual(scheduleProgress(items, at).next, []);
  assert.equal(scheduleItemPhase(items[3], at), "unscheduled");
  assert.equal(scheduleItemPhase(items[4], at), "started");
  assert.match(formatScheduleRange(items[0]), /18:30.*18:35/);
  assert.equal(formatScheduleRange(items[3]), "시각 미정");
  assert.match(formatScheduleRange(item("overnight", "2026-11-24T23:50+09:00", "2026-11-25T00:10+09:00")), /11\. 25\./);
});

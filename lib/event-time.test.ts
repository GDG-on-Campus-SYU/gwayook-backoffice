import assert from "node:assert/strict";
import test from "node:test";
import { formatEventDate, localEventInput, parseEventDate, parseEventInput } from "./event-time.ts";

test("admin dates round-trip in Korean time across UTC date boundaries", () => {
  assert.equal(localEventInput("2026-11-23T15:30:00Z"), "2026-11-24T00:30");
  assert.equal(parseEventInput("2026-11-24T00:30"), "2026-11-24T00:30:00+09:00");
  assert.equal(parseEventInput(""), null);
  assert.throws(() => parseEventInput("2026-11-31T00:30"));
});

test("event dates stay on the selected Korean calendar day and reject invalid dates", () => {
  assert.equal(parseEventDate("2028-02-29"), "2028-02-29");
  assert.equal(formatEventDate("2026-11-24"), "2026년 11월 24일 화요일");
  for (const value of ["2026-02-29", "2026-11-31", "0000-01-01", "2026-11-24T00:00", ""]) {
    assert.throws(() => parseEventDate(value));
  }
});

import assert from "node:assert/strict";
import test from "node:test";
import { getCountdown } from "./countdown.ts";

const now = Date.parse("2026-11-24T00:00:00Z");

test("deadline countdown shows days and rounds the last fraction up without going negative", () => {
  assert.deepEqual(getCountdown("2026-11-26T03:04:05Z", now), { status: "counting", text: "2일 03:04:05", seconds: 183845 });
  assert.equal(getCountdown("2026-11-24T09:00:00.001+09:00", now).text, "00:00:01");
  assert.deepEqual(getCountdown("2026-11-24T00:00:00Z", now), { status: "closed", text: "마감됨", seconds: 0 });
  assert.equal(getCountdown("2026-11-23T23:59:59Z", now).seconds, 0);
});

test("unconfigured, draft, closed and published deadlines stay distinct", () => {
  const future = "2026-11-25T00:00:00Z";
  assert.equal(getCountdown(null, now).status, "unscheduled");
  assert.equal(getCountdown("invalid", now).status, "unscheduled");
  assert.equal(getCountdown(future, now, "draft").text, "준비 중");
  assert.equal(getCountdown(future, now, "closed").text, "마감됨");
  assert.equal(getCountdown(future, now, "expired").text, "마감됨");
  assert.equal(getCountdown(null, now, "published").text, "결과 공개");
});

test("scheduled voting counts down to opening and waits for server confirmation at the boundary", () => {
  const opensAt = "2026-11-24T00:00:01Z";
  assert.equal(getCountdown(opensAt, now, "scheduled").text, "00:00:01");
  assert.deepEqual(getCountdown(opensAt, now + 1000, "scheduled"), { status: "starting", text: "시작 확인 중", seconds: 0 });
  assert.equal(getCountdown(opensAt, now + 5000, "scheduled").status, "starting");
});

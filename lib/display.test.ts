import assert from "node:assert/strict";
import test from "node:test";
import { displayTeams, loadDisplaySnapshot, type DisplaySnapshot } from "./display.ts";

test("display groups final submissions without changing presentation order or empty totals", () => {
  const teams = [
    { id: "a", name: "먼저 발표", submittedAt: "2026-11-24T10:00:00Z" },
    { id: "b", name: "미제출 팀", submittedAt: null },
    { id: "c", name: "다음 발표", submittedAt: "2026-11-24T10:01:00Z" },
  ];
  assert.deepEqual(displayTeams(teams).missing.map((team) => team.id), ["b"]);
  assert.deepEqual(displayTeams(teams).submitted.map((team) => team.id), ["a", "c"]);
  assert.deepEqual(displayTeams([]), { missing: [], submitted: [] });
  assert.equal(teams[0].id, "a");
});

test("display updates distinguish inaccessible and failed requests from an empty successful result", async () => {
  const signal = new AbortController().signal;
  const snapshot: DisplaySnapshot = {
    serverNow: 1234, event: { name: "검증 행사", date: "2026-11-24", submissionDeadline: null },
    vote: { status: "draft", opensAt: null, deadline: null, voted: 0, eligible: 0 }, teams: [],
  };
  const fetcher = (status: number, body: unknown = snapshot) => (async (_input, init) => {
    assert.equal(init?.cache, "no-store");
    assert.equal(init?.credentials, "same-origin");
    return Response.json(body, { status });
  }) as typeof fetch;
  assert.deepEqual(await loadDisplaySnapshot(signal, fetcher(200)), { kind: "updated", data: snapshot });
  for (const status of [401, 403]) assert.deepEqual(await loadDisplaySnapshot(signal, fetcher(status)), { kind: "denied" });
  assert.deepEqual(await loadDisplaySnapshot(signal, fetcher(503)), { kind: "unavailable" });
  assert.deepEqual(await loadDisplaySnapshot(signal, fetcher(200, null)), { kind: "unavailable" });
  assert.deepEqual(await loadDisplaySnapshot(signal, async () => { throw new Error("offline"); }), { kind: "unavailable" });
});

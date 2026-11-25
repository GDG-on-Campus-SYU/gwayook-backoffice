import assert from "node:assert/strict";
import test from "node:test";
import { bingoEndTime, formatBingoElapsed, normalizeBingoToken, parseBingoBonus, parseBingoConfig, parseBingoRound } from "./bingo.ts";

test("bingo confirmation accepts opaque UUIDs or grouped manual codes only", () => {
  assert.equal(normalizeBingoToken(" 123E4567-E89B-12D3-A456-426614174000 "), "123e4567-e89b-12d3-a456-426614174000");
  assert.equal(normalizeBingoToken("ab12-cd34 ef56"), "AB12CD34EF56");
  for (const value of [null, "", "ABC123", "https://example.com", "AB12CD34EF5G", "<script>"]) assert.equal(normalizeBingoToken(value), null);
});

test("bingo drafts allow blank questions but constrain all 25 fields and prize", () => {
  const form = new FormData();
  for (let index = 0; index < 25; index++) form.append("question", index === 0 ? "  대화를 시작해 보세요  " : "");
  form.set("prize", " 나중에 안내 ");
  assert.deepEqual(parseBingoConfig(form), { questions: ["대화를 시작해 보세요", ...Array<string>(24).fill("")], prize: "나중에 안내" });
  form.set("prize", "가".repeat(501));
  assert.equal(parseBingoConfig(form), null);
  form.set("prize", "");
  form.append("question", "초과");
  assert.equal(parseBingoConfig(form), null);
});

test("bingo round references require a positive database integer without coercion", () => {
  assert.equal(parseBingoRound("1"), 1);
  assert.equal(parseBingoRound("12"), 12);
  assert.equal(parseBingoRound("2147483647"), 2147483647);
  for (const value of [null, undefined, 1, ["1"], "", "0", "-1", "01", "1.0", "1e2", " 1", "1\n", "2147483648", "99999999999999999"]) {
    assert.equal(parseBingoRound(value), null);
  }
});

test("bingo bonus requires a team, the new total and the previous total", () => {
  const teamId = "aaaaaaaa-0000-0000-0000-000000000001";
  const form = new FormData();
  form.set("team_id", teamId);
  form.set("points", "0");
  form.set("expected_points", "32767");
  assert.deepEqual(parseBingoBonus(form), { teamId, points: 0, expectedPoints: 32767 });
  for (const field of ["points", "expected_points"]) {
    for (const invalid of ["", "-1", "2.5", "1e2", "0x10", "32768", " 1"]) {
      form.set(field, invalid);
      assert.equal(parseBingoBonus(form), null);
    }
    form.set(field, "1");
    form.append(field, "2");
    assert.equal(parseBingoBonus(form), null);
    form.delete(field);
    assert.equal(parseBingoBonus(form), null);
    form.set(field, "1");
  }
  form.set("team_id", "AB12CD34EF56");
  assert.equal(parseBingoBonus(form), null);
});

test("bingo end time preserves early closure and automatic expiry", () => {
  const scheduled = "2026-11-24T10:30:00Z";
  const early = "2026-11-24T10:10:00Z";
  const late = "2026-11-24T10:35:00Z";
  assert.equal(bingoEndTime(scheduled, null), scheduled);
  assert.equal(bingoEndTime(scheduled, early), early);
  assert.equal(bingoEndTime(scheduled, late), scheduled);
  assert.equal(bingoEndTime(null, null), null);
});

test("bingo elapsed time truncates submilliseconds without displaying 60 seconds", () => {
  assert.equal(formatBingoElapsed(null), "—");
  assert.equal(formatBingoElapsed(0), "0분 0.000초");
  assert.equal(formatBingoElapsed(59.9999), "0분 59.999초");
  assert.equal(formatBingoElapsed(60), "1분 0.000초");
  assert.equal(formatBingoElapsed(60.0009), "1분 0.000초");
  assert.equal(formatBingoElapsed(123.4567), "2분 3.456초");
});

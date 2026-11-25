import assert from "node:assert/strict";
import test from "node:test";
import { parseGeminiBonus } from "./gemini-bonus.ts";

test("Gemini bonus approval requires a bounded reason; explicit removal can omit it", () => {
  const form = new FormData();
  form.set("team_id", "AAAAAAAA-0000-0000-0000-000000000001");
  form.set("approved", "true");
  form.set("note", " ");
  assert.equal(parseGeminiBonus(form), null);
  form.set("note", " Gemini로 만든 앱 프로토타입을 발표에서 확인 ");
  assert.deepEqual(parseGeminiBonus(form), { teamId: "aaaaaaaa-0000-0000-0000-000000000001", approved: true, note: "Gemini로 만든 앱 프로토타입을 발표에서 확인" });
  form.set("note", "a".repeat(501));
  assert.equal(parseGeminiBonus(form), null);
  form.set("approved", "false");form.set("note", " ");
  assert.deepEqual(parseGeminiBonus(form), { teamId: "aaaaaaaa-0000-0000-0000-000000000001", approved: false, note: null });
  form.set("approved", "on");assert.equal(parseGeminiBonus(form), null);
  form.set("approved", "false");form.append("team_id", "");assert.equal(parseGeminiBonus(form), null);
  form.delete("team_id");assert.equal(parseGeminiBonus(form), null);
});

import assert from "node:assert/strict";
import test from "node:test";
import { loginNext } from "./login-next.ts";

test("Google login resumes only a validated bingo destination", () => {
  for (const path of ["/bingo", "/bingo/confirm?token=00000000-0000-4000-8000-000000000001", "/bingo/confirm?code=ABCDEF012345"]) {
    assert.equal(loginNext(path), path);
  }
  for (const path of [null, [], "https://evil.example", "//evil.example", "/\\evil.example", "/admin", "/bingo/confirm?token=bad", "/bingo/confirm?code=ABCDEF012345&next=//evil.example", "/bingo/confirm?code=ABCDEF012345\n", "/bingo#evil"]) {
    assert.equal(loginNext(path), null);
  }
});

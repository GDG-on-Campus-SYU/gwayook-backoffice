import assert from "node:assert/strict";
import test from "node:test";
import { parseVoteDelegate } from "./vote-delegation.ts";

test("vote delegation distinguishes explicit removal from missing, repeated or malformed input", () => {
  const form = new FormData();
  assert.equal(parseVoteDelegate(form), null);
  form.set("member_id", "");
  assert.deepEqual(parseVoteDelegate(form), { memberId: null });
  form.set("member_id", "AAAAAAAA-0000-0000-0000-000000000001");
  assert.deepEqual(parseVoteDelegate(form), { memberId: "aaaaaaaa-0000-0000-0000-000000000001" });
  form.append("member_id", "");
  assert.equal(parseVoteDelegate(form), null);
  for (const invalid of ["null", " ", "owner", "aaaaaaaa-0000-0000-0000-000000000001 "]) {
    form.set("member_id", invalid);
    assert.equal(parseVoteDelegate(form), null);
  }
  form.set("member_id", new Blob(["ignored"]));
  assert.equal(parseVoteDelegate(form), null);
});

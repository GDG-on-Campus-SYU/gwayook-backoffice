import assert from "node:assert/strict";
import test from "node:test";
import { parseMyGsaEmail } from "./gsa.ts";

function input() {
  const form = new FormData();
  form.set("email", " My-Gsa@Example.Test ");
  form.set("expected_updated_at", "2026-11-15T10:10:10.123456+00:00");
  return form;
}

test("self GSA submission normalizes email and preserves the expected microsecond timestamp", () => {
  const form = input();
  assert.deepEqual(parseMyGsaEmail(form), { email: "my-gsa@example.test", expectedUpdatedAt: "2026-11-15T10:10:10.123456+00:00" });
  form.set("expected_updated_at", "");assert.equal(parseMyGsaEmail(form)?.expectedUpdatedAt, null);
  // Identity and approval are never accepted from submitted fields.
  form.set("member_id", "another-person");form.set("status", "verified");
  assert.deepEqual(parseMyGsaEmail(form), { email: "my-gsa@example.test", expectedUpdatedAt: null });
});

test("self GSA submission rejects missing, duplicate, malformed or oversized fields", () => {
  for (const value of ["", " ", "bad-email", "a b@example.test", "x".repeat(250) + "@example.test"]) {
    const form = input();form.set("email", value);assert.equal(parseMyGsaEmail(form), null);
  }
  for (const name of ["email", "expected_updated_at"]) {
    const missing = input();missing.delete(name);assert.equal(parseMyGsaEmail(missing), null);
    const duplicate = input();duplicate.append(name, "");assert.equal(parseMyGsaEmail(duplicate), null);
    const file = input();file.set(name, new Blob(["not a string"]));assert.equal(parseMyGsaEmail(file), null);
  }
  const form = input();form.set("expected_updated_at", "yesterday");assert.equal(parseMyGsaEmail(form), null);
});

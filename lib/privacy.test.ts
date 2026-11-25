import assert from "node:assert/strict";
import test from "node:test";
import { agreementVersion, consentDestination, parseConsent } from "./privacy.ts";

test("consent requires the displayed version and explicit terms; optional sharing defaults to refusal", () => {
  const form = new FormData();
  assert.ok(parseConsent(form).error);
  form.set("version", agreementVersion);
  assert.ok(parseConsent(form).error);
  form.set("terms", "on");
  assert.deepEqual(parseConsent(form).values, { team: false, presentation: false, bingo: false });
  form.set("bingo", "on");
  assert.deepEqual(parseConsent(form).values, { team: false, presentation: false, bingo: true });
  form.set("version", "old");
  assert.ok(parseConsent(form).error);
});

test("refusing optional bingo sharing leaves QR consent for the participation explanation", () => {
  for (const next of ["/bingo", "/bingo/confirm?token=00000000-0000-4000-8000-000000000001", "/bingo/confirm?code=ABCDEF012345"]) {
    assert.equal(consentDestination(next, true, false), "/bingo");
    assert.equal(consentDestination(next, true, true), next);
    assert.equal(consentDestination(next, false, false), next);
  }
});

test("consent return keeps role defaults and rejects untrusted destinations", () => {
  for (const next of [null, "", "https://evil.example", "//evil.example", "/consent", "/bingo/confirm?code=ABCDEF012345&next=//evil.example"]) {
    assert.equal(consentDestination(next, true, false), "/");
    assert.equal(consentDestination(next, true, true), "/");
    assert.equal(consentDestination(next, false, false), "/admin");
  }
});

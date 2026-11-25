import assert from "node:assert/strict";
import test from "node:test";
import { matchesParticipantOperations, parseAttendance, parseGsa, type ParticipantOperation } from "./participant-operations.ts";

function record() {
  const form = new FormData();
  form.set("member_id", "AAAAAAAA-0000-0000-0000-000000000001");
  form.set("expected_updated_at", "2026-11-15T10:00:00.123456+00:00");
  form.set("status", "pending");form.set("note", " 현장 확인 ");
  return form;
}

test("attendance parser preserves stale-check precision and requires explicit bounded fields", () => {
  const form = record();form.set("status", "late");
  assert.deepEqual(parseAttendance(form), { memberId: "aaaaaaaa-0000-0000-0000-000000000001", expectedUpdatedAt: "2026-11-15T10:00:00.123456+00:00", note: "현장 확인", status: "late" });
  form.set("expected_updated_at", "");form.set("note", " \n ");assert.equal(parseAttendance(form)?.expectedUpdatedAt, null);assert.equal(parseAttendance(form)?.note, null);
  form.delete("expected_updated_at");assert.equal(parseAttendance(form), null);
  form.set("expected_updated_at", "not-a-time");assert.equal(parseAttendance(form), null);
  form.set("expected_updated_at", "");form.append("status", "present");assert.equal(parseAttendance(form), null);
  form.set("status", "toString");assert.equal(parseAttendance(form), null);
  form.set("status", "present");form.set("note", "x".repeat(501));assert.equal(parseAttendance(form), null);
  form.set("note", new Blob(["hello"]));assert.equal(parseAttendance(form), null);
});

test("GSA approval requires saved email and both explicit checks; pending email can be empty", () => {
  const form = record();form.set("status", "verified");form.set("gsa_email", " New-Gsa@Example.Test ");
  form.set("gsa_plus_active", "true");form.set("gsa_email_matched", "true");
  assert.equal(parseGsa(form)?.gsaEmail, "new-gsa@example.test");assert.equal(parseAttendance(form), null);
  form.set("gsa_plus_active", "false");assert.equal(parseGsa(form), null);
  form.set("gsa_plus_active", "true");form.set("gsa_email_matched", "false");assert.equal(parseGsa(form), null);
  form.set("gsa_email_matched", "true");form.set("gsa_email", "");assert.equal(parseGsa(form), null);
  form.set("status", "pending");assert.equal(parseGsa(form), null);
  form.set("gsa_plus_active", "false");form.set("gsa_email_matched", "false");assert.equal(parseGsa(form)?.gsaEmail, null);
  form.delete("gsa_email");assert.equal(parseGsa(form), null);
  for (const invalid of ["missing-domain", "a b@example.test", "a@b.test".repeat(40)]) { form.set("gsa_email", invalid);assert.equal(parseGsa(form), null); }
  form.set("gsa_email", "ok@example.test");form.append("member_id", "bbbbbbbb-0000-0000-0000-000000000002");assert.equal(parseGsa(form), null);
});

test("operations search combines both state filters with name, login, GSA, school and team search", () => {
  const person: ParticipantOperation = { member_id: "a", name: "김라온", email: "login@example.test", team_id: "team", team_name: "복숭아즈", active: true,
    school: "삼육대학교",
    attendance_status: "late", attendance_note: null, checked_in_at: null, attendance_updated_at: null, attendance_updated_by_name: null,
    gsa_status: "verified", gsa_email: "gsa@example.test", gsa_note: null, gsa_updated_at: null, gsa_updated_by_name: null,
    gsa_plus_active: true, gsa_email_matched: true };
  for (const query of ["김라", " LOGIN@ ", "GSA@", "복숭아", "삼육"]) assert.ok(matchesParticipantOperations(person, query, "late", "verified"));
  assert.equal(matchesParticipantOperations(person, "", "pending", "all"), false);
  assert.equal(matchesParticipantOperations(person, "", "all", "failed"), false);
  assert.equal(matchesParticipantOperations(person, "다른 사람", "all", "all"), false);
  assert.ok(matchesParticipantOperations({ ...person, team_name: null }, "미배정", "all", "all"));
  assert.ok(matchesParticipantOperations({ ...person, school: null }, "학교 미등록", "all", "all"));
  assert.equal(matchesParticipantOperations(person, "삼육", "pending", "all"), false);
  assert.equal(matchesParticipantOperations(person, "다른대학교", "all", "all"), false);
});

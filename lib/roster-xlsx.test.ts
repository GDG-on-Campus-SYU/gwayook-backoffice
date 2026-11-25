import assert from "node:assert/strict";
import test from "node:test";
import { extractRoster, guessColumns, MAX_ROSTER_ROWS } from "./roster-xlsx.ts";

const headers = ["타임스탬프", "이메일 주소", " 성명 ", "팀 이름", "대표자 여부", "전화번호"];
const mapping = guessColumns(headers);

test("maps Google Forms columns and emits only roster values with spreadsheet row numbers", () => {
  const { rows, errors } = extractRoster([
    headers,
    [new Date(), " TEAM.LEAD@example.org ", "홍길동 ", 3, "예", "010-0000-0000"],
    [null, null, null, null, null, null],
    [new Date(), "member@example.org", "김민지", 3, null, "010-1111-1111"],
  ], mapping);
  assert.deepEqual(errors, []);
  assert.deepEqual(rows, [
    { row: 2, name: "홍길동", email: "team.lead@example.org", team: "3", representative: true },
    { row: 4, name: "김민지", email: "member@example.org", team: "3", representative: null },
  ]);
});

test("reports duplicate normalized emails and representatives by source row", () => {
  const { errors } = extractRoster([
    headers,
    [null, "same@example.org", "김하늘", "Alpha", true],
    [null, "SAME@example.org", "정유진", "alpha", 1],
  ], mapping);
  assert.match(errors[0], /3행.*2행.*이메일/);
  assert.match(errors[1], /3행.*2행.*대표자/);
});

test("imports a Forms response without a team column after the organizer selects the login email", () => {
  const responseHeaders = ["타임스탬프", "이름을 입력해주세요.  ", "참가 안내를 받을 이메일을 입력해주세요."];
  const mapping = guessColumns(responseHeaders);
  assert.deepEqual(mapping, { name: 1, email: -1, school: -1, team: -1, representative: -1 });
  const { rows, errors } = extractRoster([
    responseHeaders, [new Date(), "홍길동", "person@example.org"],
  ], { ...mapping, email: 2 });
  assert.deepEqual(errors, []);
  assert.deepEqual(rows, [{ row: 2, name: "홍길동", email: "person@example.org", team: null, representative: null }]);
});

test("imports an optional school column and omits blank or unmapped school to preserve existing values", () => {
  const headers = ["이름", "이메일", "소속 학교", "수집하지 않을 정보"];
  const mapping = guessColumns(headers);
  assert.equal(mapping.school, 2);
  const data = [headers, ["가람", "a@example.test", " 삼육대학교 ", "비공개"],
    ["나래", "b@example.test", "   ", "비공개"], ["다온", "c@example.test", null, "비공개"]];
  const parsed = extractRoster(data, mapping);
  assert.deepEqual(parsed.errors, []);
  assert.equal(parsed.rows[0].school, "삼육대학교");
  assert.equal(Object.hasOwn(parsed.rows[1], "school"), false);
  assert.equal(Object.hasOwn(parsed.rows[2], "school"), false);
  const unmapped = extractRoster(data, { ...mapping, school: -1 });
  assert.deepEqual(unmapped.errors, []);
  assert.equal(unmapped.rows.every((row) => !Object.hasOwn(row, "school")), true);
  assert.equal(JSON.stringify(parsed.rows).includes("비공개"), false);
});

test("school mapping rejects duplicate columns, non-text cells and names longer than 100 characters", () => {
  const headers = ["이름", "이메일", "학교"];
  const mapping = guessColumns(headers);
  assert.equal(guessColumns(["학교", "학교"]).school, -1);
  assert.match(extractRoster([headers], { ...mapping, school: mapping.name }).errors[0], /서로 다른 열/);
  for (const value of [123, true, new Date(), "가".repeat(101)]) {
    const result = extractRoster([headers, ["이름", "person@example.test", value]], mapping);
    assert.equal(result.rows.length, 0);
    assert.match(result.errors[0], /학교.*100자/);
  }
  assert.equal(extractRoster([headers, ["이름", "person@example.test", "가".repeat(100)]], mapping).errors.length, 0);
});

test("rejects repeated or ambiguous columns, malformed values and oversized imports", () => {
  assert.equal(guessColumns(["성명", "성명", "이메일 주소", "팀명"]).name, -1);
  assert.match(extractRoster([headers], { ...mapping, team: mapping.email }).errors[0], /서로 다른 열/);
  assert.equal(extractRoster([headers, [null, "invalid", "", new Date(), "maybe"]], mapping).errors.length, 4);
  const data = Array.from({ length: MAX_ROSTER_ROWS + 1 }, (_, i) => [null, `member${i}@example.org`, "이름", "팀", null]);
  assert.match(extractRoster([headers, ...data], mapping).errors[0], /200명/);
});

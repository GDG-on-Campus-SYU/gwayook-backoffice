import assert from "node:assert/strict";
import test from "node:test";
import { bingoManualCodePath, bingoScanPath } from "./bingo-scan.ts";

const origin = "https://event.example.test";
const token = "123e4567-e89b-12d3-a456-426614174000";
const path = `/bingo/confirm?token=${token}`;

test("manual bingo codes navigate only when all 12 hex characters are present", () => {
  assert.equal(bingoManualCodePath("ab12 cd34-ef56"), "/bingo/confirm?code=AB12CD34EF56");
  for (const value of [null, "", "ABC", "AB12CD34EF5", "AB12CD34EF567", "AB12CD34EF5G", "AB12CD34EF56<script>", token, `${origin}${path}`]) {
    assert.equal(bingoManualCodePath(value), null);
  }
});

test("QR URLs produce only same-origin canonical bingo confirmation paths", () => {
  assert.equal(bingoScanPath(`${origin}${path}`, origin), path);
  assert.equal(bingoScanPath(`${origin}/bingo/confirm?token=${token.toUpperCase()}`, origin), path);
  assert.equal(bingoScanPath(`${origin}/bingo/confirm?code=ab12+cd34+ef56`, origin), "/bingo/confirm?code=AB12CD34EF56");
  assert.equal(bingoScanPath(`http://127.0.0.1:3487${path}`, "http://127.0.0.1:3487"), path);
});

test("QR scanning rejects external hosts, schemes, credentials and unexpected routes", () => {
  for (const value of [
    null, "", "AB12CD34EF56", token, path, `//event.example.test${path}`,
    `https://other.example.test${path}`, `https://event.example.test.evil.test${path}`,
    `http://event.example.test${path}`, `https://event.example.test:444${path}`,
    `https://event.example.test@other.example.test${path}`, `https://user@event.example.test${path}`,
    `javascript:alert(1)`, `data:text/html,${path}`, `file:///bingo/confirm?token=${token}`,
    `${origin}/admin?token=${token}`, `${origin}/bingo/confirm/?token=${token}`,
    `${origin}/bingo%2fconfirm?token=${token}`, `${origin}${path}#next`,
  ]) assert.equal(bingoScanPath(value, origin), null, String(value));
  assert.equal(bingoScanPath(`http://127.0.0.1:3488${path}`, "http://127.0.0.1:3487"), null);
  assert.equal(bingoScanPath(`${origin}${path}`, "not an origin"), null);
});

test("QR scanning rejects ambiguous, incomplete or additional query parameters", () => {
  for (const query of [
    "", "code=ABC", "code=AB12CD34EF5G", `code=${token}`, "token=AB12CD34EF56",
    `token=${token}&code=AB12CD34EF56`, `token=${token}&token=${token}`,
    "code=AB12CD34EF56&code=AB12CD34EF56", `token=${token}&next=https://other.example.test`,
    `token=${token}&next=`, `other=${token}`, "token=%3Cscript%3E", `token=${token}suffix`,
  ]) assert.equal(bingoScanPath(`${origin}/bingo/confirm?${query}`, origin), null, query);
});

import assert from "node:assert/strict";
import test from "node:test";
import { exportCsv } from "./csv-export.ts";

test("CSV preserves Korean, quotes, commas, newlines and numeric counts with UTF-8 BOM", () => {
  assert.equal(exportCsv({ kind: "teams", headers: ["이름", "메모", "수"], rows: [["김과육", 'a,"b"\nc', 0], [null, "", -1]] }, "teams"),
    '\uFEFF"이름","메모","수"\r\n"김과육","a,""b""\nc","0"\r\n"","","-1"\r\n');
  assert.equal(exportCsv({ kind: "bingo", headers: ["회차"], rows: [] }, "bingo"), '\uFEFF"회차"\r\n');
});

test("CSV treats formula-like strings as text and rejects unexpected payloads", () => {
  for (const value of ["=1+1", "+1", "-2", "@SUM(1)", " \t=1", "\r\ntext", "＝1", "＋1", "－1", "＠A"]) {
    const csv = exportCsv({ kind: "gsa", headers: ["값"], rows: [[value]] }, "gsa");
    assert.equal(csv, `\uFEFF"값"\r\n"'${value}"\r\n`);
  }
  for (const payload of [null, {}, { kind: "teams", headers: ["값"], rows: [] },
    { kind: "gsa", headers: ["값"], rows: [["a", "b"]] },
    { kind: "gsa", headers: ["값"], rows: [[{}]] },
    { kind: "gsa", headers: ["값"], rows: [[Infinity]] }]) assert.throws(() => exportCsv(payload, "gsa"));
});

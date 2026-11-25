"use client";

import { Button } from "@astryxdesign/core/Button";
import { useRef, useState } from "react";
import {
  extractRoster,
  guessColumns,
  MAX_ROSTER_ROWS,
  MAX_WORKBOOK_BYTES,
  rosterColumns,
  type ColumnMapping,
  type RosterPreview,
  type RosterRow,
} from "@/lib/roster-xlsx";
import { applyRoster, previewRoster } from "./actions";
import styles from "./roster-import.module.css";

type Sheet = { sheet: string; data: readonly (readonly unknown[])[] };
type Preview = { input: RosterRow[]; result: RosterPreview };
const actionLabels = { insert: "신규", update: "변경", unchanged: "유지" };

function changedValue(value: string | null, previous?: string | null, emptyLabel = "미배정") {
  const label = value ?? emptyLabel;
  return previous !== undefined && previous !== value
    ? <><span className="muted">{previous ?? emptyLabel}</span><span aria-label="에서 다음으로 변경"> → </span>{label}</>
    : label;
}

export function RosterImport() {
  const [sheets, setSheets] = useState<Sheet[]>([]);
  const [sheetIndex, setSheetIndex] = useState(0);
  const [mapping, setMapping] = useState(() => guessColumns([]));
  const [preview, setPreview] = useState<Preview | null>(null);
  const [errors, setErrors] = useState<string[]>([]);
  const [success, setSuccess] = useState("");
  const [busy, setBusy] = useState(false);
  const active = useRef(false);
  const data = sheets[sheetIndex]?.data;
  const headers = data?.[0] ?? [];
  const result = preview?.result;
  const counts = { insert: 0, update: 0, unchanged: 0 };
  for (const row of result?.rows ?? []) counts[row.action]++;

  function clearResult() {
    setErrors([]);
    setSuccess("");
    setPreview(null);
  }

  async function run(operation: () => Promise<void>, failure: string) {
    if (active.current) return;
    active.current = true;
    setBusy(true);
    setErrors([]);
    setSuccess("");
    try {
      await operation();
    } catch {
      setErrors([failure]);
    } finally {
      active.current = false;
      setBusy(false);
    }
  }

  async function readWorkbook(file?: File) {
    await run(async () => {
      setPreview(null);
      setSheets([]);
      setSheetIndex(0);
      setMapping(guessColumns([]));
      if (!file) return;
      if (!file.name.toLowerCase().endsWith(".xlsx") || file.size === 0 || file.size > MAX_WORKBOOK_BYTES) {
        setErrors(["비어 있지 않은 2MB 이하의 .xlsx 파일을 선택해 주세요."]);
        return;
      }
      const { default: readExcelFile } = await import("read-excel-file/browser");
      const workbook = await readExcelFile(file);
      if (!workbook.length) {
        setErrors(["엑셀 파일에 읽을 수 있는 시트가 없습니다."]);
        return;
      }
      setSheets(workbook);
      setMapping(guessColumns(workbook[0].data[0] ?? []));
    }, "엑셀 파일을 읽지 못했습니다. .xlsx 파일인지 확인해 주세요.");
  }

  async function checkRoster() {
    if (!data) return;
    await run(async () => {
      setPreview(null);
      const parsed = extractRoster(data, mapping);
      if (parsed.errors.length) {
        setErrors(parsed.errors);
        return;
      }
      const checked = await previewRoster(parsed.rows);
      if (checked.errors.length) setErrors(checked.errors);
      else setPreview({ input: parsed.rows, result: checked });
    }, "명단을 미리보기 하지 못했습니다. 다시 시도해 주세요.");
  }

  async function saveRoster() {
    if (!preview || counts.insert + counts.update === 0) return;
    await run(async () => {
      const applied = await applyRoster(preview.input, preview.result.revision);
      setPreview(null);
      if (applied.errors.length) setErrors(applied.errors);
      else setSuccess(`명단을 반영했습니다. 신규 ${counts.insert}명, 변경 ${counts.update}명, 유지 ${counts.unchanged}명.`);
    }, "명단 적용을 확인하지 못했습니다. 미리보기에서 현재 명단을 다시 확인해 주세요.");
  }

  return (
    <div className="stack">
      <section className="panel stack" aria-labelledby="source-heading">
        <h2 id="source-heading">파일과 열 선택</h2>
        <fieldset className={styles.controls} disabled={busy}>
          <label className="field">
            엑셀 파일
            <input
              type="file"
              accept=".xlsx,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
              aria-describedby="workbook-help"
              onChange={(event) => {
                const file = event.currentTarget.files?.[0];
                void readWorkbook(file);
              }}
            />
          </label>
          <p id="workbook-help" className="muted">.xlsx · 최대 2MB, 참가자 {MAX_ROSTER_ROWS}명 · 첫 행은 열 제목</p>

          {sheets.length > 0 && (
            <>
              <label className="field">
                시트
                <select
                  value={sheetIndex}
                  onChange={(event) => {
                    const index = Number(event.target.value);
                    setSheetIndex(index);
                    setMapping(guessColumns(sheets[index].data[0] ?? []));
                    clearResult();
                  }}
                >
                  {sheets.map(({ sheet }, index) => <option value={index} key={index}>{sheet}</option>)}
                </select>
              </label>
              <div className={styles.mapping}>
                {(Object.keys(rosterColumns) as (keyof ColumnMapping)[]).map((key) => (
                  <label className="field" key={key}>
                    {rosterColumns[key]}
                    <select
                      value={mapping[key]}
                      onChange={(event) => {
                        setMapping({ ...mapping, [key]: Number(event.target.value) });
                        clearResult();
                      }}
                    >
                      <option value={-1}>{key === "name" || key === "email" ? "열 선택" : "열 없음 (선택 사항)"}</option>
                      {headers.map((value, index) => (
                        <option key={index} value={index}>{index + 1}열 · {String(value ?? "").trim() || "제목 없음"}</option>
                      ))}
                    </select>
                  </label>
                ))}
              </div>
              <p className="muted">이메일은 참가자가 Google 로그인에 사용할 주소를 선택하세요. 학교·팀명·대표자 열을 선택하지 않거나 칸을 비우면 기존 정보를 유지합니다. 신규 참가자의 빈 항목은 학교 미등록·팀 미배정으로 처리합니다. 기존 학교 정보를 지우려면 참가자 수정 화면에서 비워 저장하세요.</p>
            </>
          )}
        </fieldset>

        {sheets.length > 0 && (
          <div className="action-row">
            <Button
              label="변경 사항 미리보기"
              variant="primary"
              isDisabled={busy}
              onClick={() => { void checkRoster(); }}
            />
          </div>
        )}
        <p role="status" className="muted">{busy ? "명단을 처리하고 있습니다…" : success}</p>
        {errors.length > 0 && (
          <div role="alert" className={`notice ${styles.errors}`}>
            <strong>명단을 확인해 주세요</strong>
            <ul>{errors.map((error, index) => <li key={index}>{error}</li>)}</ul>
          </div>
        )}
      </section>

      {result && (
        <section className="panel stack" aria-labelledby="preview-heading">
          <h2 id="preview-heading">반영할 명단</h2>
          <p role="status">신규 {counts.insert}명 · 변경 {counts.update}명 · 유지 {counts.unchanged}명</p>
          {result.new_teams.length > 0 && <p>새로 만들 팀 · {result.new_teams.join(", ")}</p>}
          <p className="muted">파일에 없는 기존 참가자는 유지됩니다.</p>
          <div className="table-wrap" role="region" aria-label="가져오기 미리보기 표" tabIndex={0}>
            <p className="table-scroll-hint">표가 잘리면 좌우로 밀어 확인하세요.</p>
            <table className={styles.previewTable}>
              <thead><tr>
                <th scope="col">행</th><th scope="col">처리</th><th scope="col">이름</th>
                <th scope="col">이메일</th><th scope="col">학교</th><th scope="col">팀</th><th scope="col">대표자</th>
              </tr></thead>
              <tbody>
                {result.rows.map((row) => (
                  <tr key={row.email}>
                    <td>{row.row ?? "–"}</td>
                    <td>{actionLabels[row.action]}</td>
                    <td>{changedValue(row.name, row.before?.name)}</td>
                    <td>{row.email}</td>
                    <td>{changedValue(row.school, row.before?.school, "미등록")}</td>
                    <td>{changedValue(row.team, row.before?.team)}</td>
                    <td>{changedValue(row.representative ? "예" : "아니오", row.before ? row.before.representative ? "예" : "아니오" : undefined)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <div className="action-row">
            <Button
              label="명단 적용"
              variant="primary"
              isDisabled={busy || counts.insert + counts.update === 0}
              onClick={() => { void saveRoster(); }}
            />
            {counts.insert + counts.update === 0 && <p className="muted">반영할 변경 사항이 없습니다.</p>}
          </div>
        </section>
      )}
    </div>
  );
}

import { strict as assert } from "node:assert";
import { test } from "node:test";
import { looksLikePdf, MAX_PDF_BYTES, validPdfFileName } from "../app/presentations/pdf.ts";

test("PDF validation accepts the expected header and end marker within the file limit", () => {
  const bytes = (text: string) => new TextEncoder().encode(text);
  assert.equal(looksLikePdf(bytes("%PDF-1.7\n1 0 obj\nendobj\n%%EOF\n")), true);
  assert.equal(looksLikePdf(bytes("%PDF-2.0\r\n%%EOF\r\n")), true);
  assert.equal(looksLikePdf(bytes("<html>not a pdf</html>\n%%EOF\n")), false);
  assert.equal(looksLikePdf(bytes("%PDF-1.7\n1 0 obj\nendobj\n")), false);
  assert.equal(looksLikePdf(bytes("%PDF-1.7\n%%EOF\n<script>")), false);
  const fullPdf = (size: number) => {
    const file = new Uint8Array(size).fill(32);
    file.set(bytes("%PDF-1.7\n"));
    file.set(bytes("\n%%EOF\n"), size - 7);
    return file;
  };
  assert.equal(looksLikePdf(fullPdf(MAX_PDF_BYTES)), true);
  assert.equal(looksLikePdf(fullPdf(MAX_PDF_BYTES + 1)), false);
});

test("PDF filenames allow Korean and reject path separators and controls", () => {
  assert.equal(validPdfFileName("과육톤 발표자료.PDF"), true);
  assert.equal(validPdfFileName("../팀.pdf"), false);
  assert.equal(validPdfFileName("폴더\\팀.pdf"), false);
  assert.equal(validPdfFileName("발표\n팀.pdf"), false);
  assert.equal(validPdfFileName("발표.pptx"), false);
});

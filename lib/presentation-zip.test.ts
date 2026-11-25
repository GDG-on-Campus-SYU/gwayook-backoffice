import { strict as assert } from "node:assert";
import { test } from "node:test";
import { looksLikeZip, validZipFileName } from "../app/presentations/zip.ts";

test("accepts a ZIP with a central directory and rejects renamed or truncated files", () => {
  const archive = Buffer.from("UEsDBBQAAAAAALileF2g30LWBAAAAAQAAAAIAAAAZGVtby50eHRkZW1vUEsBAhQAFAAAAAAAuKV4XaDfQtYEAAAABAAAAAgAAAAAAAAAAAAAAIABAAAAAGRlbW8udHh0UEsFBgAAAAABAAEANgAAACoAAAAAAA==", "base64");
  assert(looksLikeZip(archive));
  assert(!looksLikeZip(archive.subarray(0, archive.length - 1)));
  assert(!looksLikeZip(Buffer.from("%PDF-1.7 fake archive content")));
  assert(!looksLikeZip(Buffer.concat([archive.subarray(0, 4), Buffer.alloc(100)])));
  assert(validZipFileName("발표 소스.ZIP"));
  assert(!validZipFileName("../demo.zip"));
  assert(!validZipFileName("slides.pdf"));
});

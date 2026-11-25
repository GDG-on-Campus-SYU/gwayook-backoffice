export const ZIP_BUCKET = "presentation-zips";
export const MAX_ZIP_BYTES = 20 * 1024 * 1024;

export function validZipFileName(name: string) {
  return name.length >= 5 && name.length <= 180 && /\.zip$/i.test(name)
    && !/[\u0000-\u001f\u007f/\\]/.test(name);
}

// Check the central directory without extracting participant-provided files.
export function looksLikeZip(bytes: Uint8Array) {
  if (bytes.length < 22 || bytes.length > MAX_ZIP_BYTES) return false;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const earliest = Math.max(0, bytes.length - 22 - 65535);
  for (let end = bytes.length - 22; end >= earliest; end--) {
    if (view.getUint32(end, true) !== 0x06054b50 || end + 22 + view.getUint16(end + 20, true) !== bytes.length) continue;
    const entries = view.getUint16(end + 10, true);
    const length = view.getUint32(end + 12, true);
    const offset = view.getUint32(end + 16, true);
    if (view.getUint32(end + 4, true) !== 0 || view.getUint16(end + 8, true) !== entries || offset + length !== end) continue;
    if (!entries) return end === 0 && length === 0;
    return length >= 46 && view.getUint32(0, true) === 0x04034b50 && view.getUint32(offset, true) === 0x02014b50;
  }
  return false;
}

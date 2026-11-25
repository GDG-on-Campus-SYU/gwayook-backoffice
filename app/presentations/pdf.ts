export const PDF_BUCKET = "presentation-pdfs";
export const MAX_PDF_BYTES = 5 * 1024 * 1024;

export function validPdfFileName(name: string) {
  return name.length >= 5 && name.length <= 180 && /\.pdf$/i.test(name)
    && !/[\u0000-\u001f\u007f/\\]/.test(name);
}

export function looksLikePdf(bytes: Uint8Array) {
  if (bytes.length < 16 || bytes.length > MAX_PDF_BYTES) return false;
  const decoder = new TextDecoder();
  return /^%PDF-(1\.[0-7]|2\.0)[\r\n]/.test(decoder.decode(bytes.subarray(0, 9)))
    && /(?:^|[\r\n])%%EOF[\t\n\r ]*$/.test(decoder.decode(bytes.subarray(-1024)));
}

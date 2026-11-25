import { normalizeBingoToken } from "./bingo.ts";

export function bingoManualCodePath(value: unknown): string | null {
  const code = normalizeBingoToken(value);
  return code && /^[0-9A-F]{12}$/.test(code) ? `/bingo/confirm?code=${code}` : null;
}

export function bingoScanPath(value: unknown, trustedOrigin: string): string | null {
  if (typeof value !== "string" || value.length > 2048) return null;
  try {
    const origin = new URL(trustedOrigin);
    const url = new URL(value);
    if (!["https:", "http:"].includes(origin.protocol) || url.origin !== origin.origin ||
      url.username || url.password || url.hash || url.pathname !== "/bingo/confirm") return null;
    const entries = [...url.searchParams];
    if (entries.length !== 1) return null;
    const [key, raw] = entries[0];
    if (key === "code") return bingoManualCodePath(raw);
    const token = normalizeBingoToken(raw);
    return key === "token" && token?.includes("-") ? `/bingo/confirm?token=${token}` : null;
  } catch {
    return null;
  }
}

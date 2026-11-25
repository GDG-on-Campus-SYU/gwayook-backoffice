// Only the bingo confirmation flow can resume after Google login.
export function loginNext(value: unknown): string | null {
  if (typeof value !== "string" || value.trim() !== value) return null;
  if (value === "/bingo") return value;
  if (/^\/bingo\/confirm\?token=[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)) return value;
  if (/^\/bingo\/confirm\?code=[0-9a-f]{12}$/i.test(value)) return value;
  return null;
}

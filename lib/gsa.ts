import type { GsaStatus } from "./participant-operations.ts";

export type MyGsa = { gsa_email: string | null; gsa_status: GsaStatus; gsa_updated_at: string | null };

export function parseMyGsaEmail(form: FormData): { email: string; expectedUpdatedAt: string | null } | null {
  if (["email", "expected_updated_at"].some((name) => form.getAll(name).length !== 1)) return null;
  const value = form.get("email");
  const expected = form.get("expected_updated_at");
  if (typeof value !== "string" || typeof expected !== "string") return null;
  const email = value.trim().toLowerCase();
  if (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return null;
  if (expected !== "" && (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$/.test(expected) || !Number.isFinite(Date.parse(expected)))) return null;
  return { email, expectedUpdatedAt: expected || null };
}

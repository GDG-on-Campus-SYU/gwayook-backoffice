export function parseVoteDelegate(form: FormData): { memberId: string | null } | null {
  const values = form.getAll("member_id");
  if (values.length !== 1 || typeof values[0] !== "string") return null;
  const value = values[0];
  if (value === "") return { memberId: null };
  if (!/^[\da-f]{8}(?:-[\da-f]{4}){3}-[\da-f]{12}$/i.test(value)) return null;
  return { memberId: value.toLowerCase() };
}

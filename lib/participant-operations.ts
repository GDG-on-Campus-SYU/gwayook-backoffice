export const attendanceLabels = { pending: "미확인", present: "출석", late: "지각", absent: "불참" } as const;
export const gsaLabels = { pending: "확인 대기", verified: "확인 완료", failed: "확인 실패" } as const;
export type AttendanceStatus = keyof typeof attendanceLabels;
export type GsaStatus = keyof typeof gsaLabels;

export type ParticipantOperation = {
  member_id: string; name: string; email: string; team_id: string | null; team_name: string | null; active: boolean;
  school: string | null;
  attendance_status: AttendanceStatus; attendance_note: string | null; checked_in_at: string | null;
  attendance_updated_by_name: string | null; attendance_updated_at: string | null;
  gsa_status: GsaStatus; gsa_email: string | null; gsa_note: string | null;
  gsa_plus_active: boolean; gsa_email_matched: boolean;
  gsa_updated_by_name: string | null; gsa_updated_at: string | null;
};

function single(form: FormData, name: string) {
  const values = form.getAll(name);
  return values.length === 1 && typeof values[0] === "string" ? values[0] : null;
}

function parseRecord(form: FormData) {
  const memberId = single(form, "member_id");
  const expected = single(form, "expected_updated_at");
  const rawNote = single(form, "note");
  if (!memberId || !/^[\da-f]{8}(?:-[\da-f]{4}){3}-[\da-f]{12}$/i.test(memberId) || expected === null || rawNote === null) return null;
  // Keep PostgreSQL's timestamp precision; converting through Date would lose microseconds.
  if (expected !== "" && (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$/.test(expected) || !Number.isFinite(Date.parse(expected)))) return null;
  const note = rawNote.trim();
  if (note.length > 500) return null;
  return { memberId: memberId.toLowerCase(), expectedUpdatedAt: expected || null, note: note || null };
}

export function parseAttendance(form: FormData) {
  const record = parseRecord(form);
  const status = single(form, "status");
  return record && status && Object.hasOwn(attendanceLabels, status) ? { ...record, status: status as AttendanceStatus } : null;
}

export function parseGsa(form: FormData) {
  const record = parseRecord(form);
  const status = single(form, "status");
  const rawEmail = single(form, "gsa_email");
  const plusActive = single(form, "gsa_plus_active");
  const emailMatched = single(form, "gsa_email_matched");
  if (!record || !status || !Object.hasOwn(gsaLabels, status) || rawEmail === null
    || (plusActive !== "true" && plusActive !== "false") || (emailMatched !== "true" && emailMatched !== "false")) return null;
  const email = rawEmail.trim().toLowerCase();
  if (email.length > 254 || (email !== "" && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))) return null;
  if (status === "verified" ? !email || plusActive !== "true" || emailMatched !== "true" : plusActive !== "false" || emailMatched !== "false") return null;
  return { ...record, status: status as GsaStatus, gsaEmail: email || null, plusActive: plusActive === "true", emailMatched: emailMatched === "true" };
}

export function matchesParticipantOperations(person: ParticipantOperation, search: string, attendance: AttendanceStatus | "all", gsa: GsaStatus | "all") {
  const query = search.trim().toLocaleLowerCase();
  return (attendance === "all" || person.attendance_status === attendance)
    && (gsa === "all" || person.gsa_status === gsa)
    && [person.name, person.email, person.gsa_email, person.school ?? "학교 미등록", person.team_name ?? "미배정"].some((value) => value?.toLocaleLowerCase().includes(query));
}

alter policy read_participant_guide on storage.objects using (
  bucket_id = 'event-guides'
  and name in ('2026-11-16/participant.pdf', '2026-11-21/participant.pdf', '2026-11-21.2/participant.pdf')
  and (select (private.current_member()).id) is not null
);

alter policy read_staff_guide on storage.objects using (
  bucket_id = 'event-guides'
  and name in ('2026-11-16/staff.pdf', '2026-11-21/staff.pdf', '2026-11-21.2/staff.pdf')
  and (select (private.current_member()).role) in ('staff', 'owner')
);

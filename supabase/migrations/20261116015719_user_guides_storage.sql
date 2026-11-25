insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('event-guides', 'event-guides', false, 2097152, array['application/pdf']);

create policy read_participant_guide on storage.objects for select to authenticated
  using (bucket_id = 'event-guides' and name = '2026-11-16/participant.pdf'
    and (select (private.current_member()).id) is not null);

create policy read_staff_guide on storage.objects for select to authenticated
  using (bucket_id = 'event-guides' and name = '2026-11-16/staff.pdf'
    and (select (private.current_member()).role) in ('staff', 'owner'));

begin;

do $$ begin
  if not exists(select 1 from storage.buckets where id='event-guides' and name='event-guides'
    and not public and file_size_limit=2097152 and allowed_mime_types=array['application/pdf']) then
    raise exception 'guide bucket must be private, PDF only and limited to 2 MiB';
  end if;
  if not (select relrowsecurity from pg_class where oid='storage.objects'::regclass) then
    raise exception 'storage object RLS is disabled';
  end if;
  if (select count(*) from pg_policies where schemaname='storage' and tablename='objects'
    and policyname in('read_participant_guide','read_staff_guide') and cmd='SELECT' and roles=array['authenticated']::name[]) <> 2 then
    raise exception 'guide policies must grant SELECT only to authenticated';
  end if;
end; $$;

insert into auth.users(id,email) select ('a1000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  'guide-'||i||'@example.test' from generate_series(1,6) i;
insert into public.members(id,name,email,auth_user_id,role,active)
select ('a2000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,'Guide member '||i,'guide-'||i||'@example.test',
  ('a1000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  case when i=1 then 'owner' when i in(2,5) then 'staff' else 'participant' end,i not in(4,5)
from generate_series(1,5) i;
insert into public.teams(id,name) values('a3000000-0000-0000-0000-000000000001','Guide presentation fixture');
insert into public.submissions(team_id,current_path,file_name,size_bytes,submitted_at,submitted_by,version)
values('a3000000-0000-0000-0000-000000000001','guide-test-final.pdf','test.pdf',100,now(),
  'a2000000-0000-0000-0000-000000000003',1);
insert into storage.buckets(id,name,public) values('guide-unrelated-fixture','guide-unrelated-fixture',false);
insert into storage.objects(bucket_id,name) values
  ('event-guides','2026-11-16/participant.pdf'),
  ('event-guides','2026-11-16/staff.pdf'),
  ('event-guides','2026-11-21/participant.pdf'),
  ('event-guides','2026-11-21/staff.pdf'),
  ('event-guides','2026-11-21.2/participant.pdf'),
  ('event-guides','2026-11-21.2/staff.pdf'),
  ('event-guides','2026-11-21.2/private-draft.pdf'),
  ('event-guides','2026-11-21/private-draft.pdf'),
  ('event-guides','2026-11-16/private-draft.pdf'),
  ('event-guides','2026-11-17/participant.pdf'),
  ('event-guides','participant.pdf'),
  ('presentation-pdfs','2026-11-16/participant.pdf'),
  ('presentation-pdfs','guide-test-final.pdf'),
  ('guide-unrelated-fixture','2026-11-16/participant.pdf'),
  ('guide-unrelated-fixture','2026-11-21/participant.pdf'),
  ('guide-unrelated-fixture','2026-11-21.2/participant.pdf');

\ir fixtures/consented-members.sql
select pg_temp.consent_fixture_members('{"team":false,"presentation":false,"bingo":false}');

create temp table guides_before as
select jsonb_agg(to_jsonb(o) order by id) as objects from storage.objects o;
-- Grant table privileges inside this rolled-back test so the checks exercise RLS, not missing grants.
grant select on storage.objects to anon;
grant update,delete on storage.objects to authenticated;

set local role anon;
do $$ begin
  if exists(select 1 from storage.objects where bucket_id='event-guides') then
    raise exception 'anonymous reader accessed guide';
  end if;
end; $$;
reset role;

set local role authenticated;
do $$
declare
  person integer;
  actual text[];
  expected text[];
  affected integer;
begin
  perform set_config('request.jwt.claim.sub','',true);
  if exists(select 1 from storage.objects where bucket_id='event-guides') then
    raise exception 'missing identity accessed guide';
  end if;
  for person in 1..6 loop
    perform set_config('request.jwt.claim.sub','a1000000-0000-0000-0000-'||lpad(person::text,12,'0'),true);
    expected:=case when person in(1,2) then array['2026-11-16/participant.pdf','2026-11-16/staff.pdf',
                                                '2026-11-21/participant.pdf','2026-11-21/staff.pdf',
                                                '2026-11-21.2/participant.pdf','2026-11-21.2/staff.pdf']
      when person=3 then array['2026-11-16/participant.pdf','2026-11-21/participant.pdf','2026-11-21.2/participant.pdf'] else array[]::text[] end;
    select coalesce(array_agg(name order by name),array[]::text[]) into actual
      from storage.objects where bucket_id='event-guides';
    if actual is distinct from array(select unnest(expected) order by 1) then raise exception 'unexpected guide read for identity %: %',person,actual; end if;
    if exists(select 1 from storage.objects where bucket_id in('presentation-pdfs','guide-unrelated-fixture')
      and name in('2026-11-16/participant.pdf','2026-11-21/participant.pdf','2026-11-21.2/participant.pdf')) then
      raise exception 'guide path bypassed another bucket policy';
    end if;
    if exists(select 1 from storage.objects where bucket_id='presentation-pdfs' and name='guide-test-final.pdf')
      is distinct from (person=3) then
      raise exception 'existing presentation policy behavior changed for identity %',person;
    end if;
    if person in(1,2) and public.get_presentation_file('a3000000-0000-0000-0000-000000000001') is null then
      raise exception 'logged staff presentation download unavailable';
    end if;
    begin
      insert into storage.objects(bucket_id,name) values('event-guides','unapproved-'||person||'.pdf');
      raise exception 'user uploaded guide';
    exception when insufficient_privilege then null; end;
    update storage.objects set metadata='{"replaced":true}' where bucket_id='event-guides';
    get diagnostics affected = row_count;
    if affected <> 0 then raise exception 'user replaced guide'; end if;
    delete from storage.objects where bucket_id='event-guides';
    get diagnostics affected = row_count;
    if affected <> 0 then raise exception 'user deleted guide'; end if;
  end loop;
end; $$;
reset role;

do $$ begin
  if (select objects from guides_before) is distinct from (select jsonb_agg(to_jsonb(o) order by id) from storage.objects o) then
    raise exception 'guide access test changed storage objects';
  end if;
end; $$;

select '1..1';
select 'ok 1 - private role-scoped guide reads, exact paths, no client writes and existing presentation access';
rollback;

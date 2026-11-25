begin;

insert into auth.users (id, email, email_confirmed_at) values
  ('21000000-0000-0000-0000-000000000001', 'rep@pdf.example.test', now()),
  ('21000000-0000-0000-0000-000000000002', 'reader@pdf.example.test', now()),
  ('21000000-0000-0000-0000-000000000003', 'outsider@pdf.example.test', now()),
  ('21000000-0000-0000-0000-000000000004', 'corrected@pdf.example.test', now());
insert into public.teams (id, name) values ('31000000-0000-0000-0000-000000000001', 'PDF test team');
insert into public.members (id, name, email, team_id, auth_user_id) values
  ('41000000-0000-0000-0000-000000000001', 'PDF rep', 'rep@pdf.example.test', '31000000-0000-0000-0000-000000000001', '21000000-0000-0000-0000-000000000001'),
  ('41000000-0000-0000-0000-000000000002', 'PDF reader', 'reader@pdf.example.test', '31000000-0000-0000-0000-000000000001', '21000000-0000-0000-0000-000000000002');
update public.teams set representative_id = '41000000-0000-0000-0000-000000000001' where id = '31000000-0000-0000-0000-000000000001';
update public.event_settings set submission_deadline = now() + interval '1 hour';

\ir fixtures/consented-members.sql
select pg_temp.consent_fixture_members('{"team":false,"presentation":true,"bingo":false}');

do $$
declare
  rep uuid := '41000000-0000-0000-0000-000000000001';
  reader uuid := '41000000-0000-0000-0000-000000000002';
  team uuid := '31000000-0000-0000-0000-000000000001';
  rep_account uuid := '21000000-0000-0000-0000-000000000001';
  reader_account uuid := '21000000-0000-0000-0000-000000000002';
  corrected_account uuid := '21000000-0000-0000-0000-000000000004';
  first_path text;
  second_path text;
  third_path text;
  abandoned text;
  late_finalize text;
  zip_path text;
  replacement_zip text;
begin
  if has_function_privilege('authenticated', 'public.complete_presentation(uuid,uuid,text,integer)', 'execute')
    or has_function_privilege('authenticated', 'public.prepare_presentation(uuid,uuid,integer,text,integer)', 'execute')
    or has_function_privilege('service_role', 'private.complete_presentation(uuid,text,integer)', 'execute')
    or to_regprocedure('public.complete_presentation(uuid,text,integer)') is not null
    or has_table_privilege('authenticated', 'public.submissions', 'insert') then
    raise exception 'browser can bypass upload verification';
  end if;
  execute 'set local role service_role';
  begin
    perform public.prepare_presentation_zip(rep, rep_account, 0, 'extra.zip', 100);
    raise exception 'ZIP accepted without a submitted PDF';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.prepare_presentation(rep, rep_account, 0, 'oversize.pdf', 5242881);
    raise exception 'oversized PDF reservation accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.prepare_presentation(rep, rep_account, 0, 'empty.pdf', 0);
    raise exception 'empty PDF reservation accepted';
  exception when invalid_parameter_value then null;
  end;
  perform public.prepare_presentation(rep, rep_account, 0, 'maximum.pdf', 5242880);
  begin
    perform public.prepare_presentation(reader, reader_account, 0, 'slides.pdf', 500);
    raise exception 'non-representative reserved a path';
  exception when insufficient_privilege then null;
  end;
  first_path := public.prepare_presentation(rep, rep_account, 0, 'slides.pdf', 500);
  begin
    perform public.complete_presentation(rep, rep_account, first_path, 500);
    raise exception 'missing storage object accepted';
  exception when invalid_parameter_value then null;
  end;

  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', '21000000-0000-0000-0000-000000000002', true);
  begin
    insert into storage.objects (bucket_id, name, metadata) values ('presentation-pdfs', first_path, '{"size":500,"mimetype":"application/pdf"}');
    raise exception 'other member wrote reserved path';
  exception when insufficient_privilege then null;
  end;
  perform set_config('request.jwt.claim.sub', '21000000-0000-0000-0000-000000000001', true);
  insert into storage.objects (bucket_id, name, metadata) values ('presentation-pdfs', first_path, '{"size":500,"mimetype":"application/pdf"}');
  perform set_config('request.jwt.claim.sub', '21000000-0000-0000-0000-000000000002', true);
  if exists (select 1 from storage.objects where bucket_id = 'presentation-pdfs' and name = first_path) then
    raise exception 'draft visible to other participant';
  end if;

  execute 'set local role service_role';
  if public.complete_presentation(rep, rep_account, first_path, 500) is distinct from team then raise exception 'first upload did not finalize'; end if;
  zip_path := public.prepare_presentation_zip(rep, rep_account, 0, 'extra.zip', 100);
  execute 'set local role authenticated';
  if has_function_privilege('authenticated','public.complete_presentation_zip(uuid,uuid,text,integer)','execute') then
    raise exception 'client can bypass ZIP verification';
  end if;
  begin
    insert into storage.objects(bucket_id,name,metadata) values('presentation-zips',zip_path,'{"size":100,"mimetype":"application/zip"}');
    raise exception 'teammate uploaded to a ZIP reservation';
  exception when insufficient_privilege then null;
  end;
  perform set_config('request.jwt.claim.sub',rep_account::text,true);
  insert into storage.objects(bucket_id,name,metadata) values('presentation-zips',zip_path,'{"size":100,"mimetype":"application/zip"}');
  execute 'set local role service_role';
  perform public.complete_presentation_zip(rep, rep_account, zip_path, 100);
  replacement_zip := public.prepare_presentation_zip(rep, rep_account, 1, 'replacement.zip', 120);
  begin
    perform public.complete_presentation_zip(rep, rep_account, replacement_zip, 120);
    raise exception 'missing replacement ZIP accepted';
  exception when invalid_parameter_value then null;
  end;
  perform public.abandon_presentation_zip(rep, rep_account, replacement_zip);
  execute 'set local role authenticated';
  if public.get_presentation_zips(team)->>'current_path' is distinct from zip_path then
    raise exception 'valid ZIP lost after unsuccessful replacement';
  end if;
  perform set_config('request.jwt.claim.sub',reader_account::text,true);
  if public.get_presentation_zips(team) is not null or public.get_presentation_zips() <> '[]'::jsonb
    or exists(select 1 from storage.objects where bucket_id='presentation-zips' and name=zip_path) then
    raise exception 'PDF sharing leaked private ZIP to another team member';
  end if;
  execute 'set local role service_role';
  begin
    perform public.prepare_presentation(rep, rep_account, 0, 'stale.pdf', 500);
    raise exception 'stale submission version accepted';
  exception when invalid_parameter_value then null;
  end;

  execute 'set local role authenticated';
  if not exists (select 1 from public.submissions where team_id = team and current_path = first_path and version = 1)
    or not exists (select 1 from storage.objects where bucket_id = 'presentation-pdfs' and name = first_path) then
    raise exception 'registered participant cannot read final';
  end if;
  perform set_config('request.jwt.claim.sub', '21000000-0000-0000-0000-000000000003', true);
  if exists (select 1 from public.submissions where team_id = team)
    or exists (select 1 from storage.objects where bucket_id = 'presentation-pdfs' and name = first_path) then
    raise exception 'unregistered user can read final';
  end if;

  execute 'set local role service_role';
  abandoned := public.prepare_presentation(rep, rep_account, 1, 'abandoned.pdf', 500);
  second_path := public.prepare_presentation(rep, rep_account, 1, 'second.pdf', 501);
  execute 'reset role';
  insert into storage.objects (bucket_id, name, metadata) values
    ('presentation-pdfs', abandoned, '{"size":500,"mimetype":"application/pdf"}'),
    ('presentation-pdfs', second_path, '{"size":501,"mimetype":"application/pdf"}');
  execute 'set local role service_role';
  if public.unreferenced_presentation_files(team) is distinct from array[abandoned] then
    raise exception 'cleanup included a final or reserved file';
  end if;
  begin
    perform public.complete_presentation(rep, rep_account, second_path, 500);
    raise exception 'mismatched file size accepted';
  exception when invalid_parameter_value then null;
  end;
  execute 'reset role';
  if (select current_path from public.submissions where team_id = team) is distinct from first_path then
    raise exception 'failed upload replaced the accepted file';
  end if;
  execute 'set local role service_role';
  perform public.complete_presentation(rep, rep_account, second_path, 501);
  third_path := public.prepare_presentation(rep, rep_account, 2, 'third.pdf', 502);
  execute 'reset role';
  insert into storage.objects (bucket_id, name, metadata) values ('presentation-pdfs', third_path, '{"size":502,"mimetype":"application/pdf"}');
  execute 'set local role service_role';
  perform public.complete_presentation(rep, rep_account, third_path, 502);
  if not (public.unreferenced_presentation_files(team) @> array[first_path, abandoned])
    or public.unreferenced_presentation_files(team) && array[second_path, third_path] then
    raise exception 'cleanup failed to preserve exactly current and previous file';
  end if;

  abandoned := public.prepare_presentation(rep, rep_account, 3, 'old-account.pdf', 503);
  execute 'reset role';
  insert into storage.objects (bucket_id, name, metadata) values ('presentation-pdfs', abandoned, '{"size":503,"mimetype":"application/pdf"}');
  update public.members set email = 'corrected@pdf.example.test', auth_user_id = corrected_account where id = rep;
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', corrected_account::text, true);
  if (public.get_my_consents()->>'terms')::boolean then raise exception 'replacement account inherited previous consent'; end if;
  perform public.save_my_consents('2026-11-16.1',true,'{"team":false,"presentation":true,"bingo":false}');
  if exists (select 1 from storage.objects where bucket_id = 'presentation-pdfs' and name = abandoned) then
    raise exception 'replacement account can read a reservation made by the previous account';
  end if;
  execute 'set local role service_role';
  begin
    perform public.complete_presentation(rep, rep_account, abandoned, 503);
    raise exception 'stale authenticated request finalized after another account was linked';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.complete_presentation(rep, corrected_account, abandoned, 503);
    raise exception 'replacement account finalized a reservation made by the previous account';
  exception when invalid_parameter_value then null;
  end;
  if public.abandon_presentation(rep, corrected_account, abandoned) is not null then
    raise exception 'replacement account abandoned another account reservation';
  end if;
  abandoned := public.prepare_presentation(rep, corrected_account, 3, 'corrected-account.pdf', 503);
  execute 'set local role authenticated';
  insert into storage.objects (bucket_id, name, metadata) values ('presentation-pdfs', abandoned, '{"size":503,"mimetype":"application/pdf"}');
  execute 'set local role service_role';
  if public.complete_presentation(rep, corrected_account, abandoned, 503) is distinct from team then
    raise exception 'replacement account could not finalize a fresh reservation';
  end if;

  late_finalize := public.prepare_presentation(rep, corrected_account, 4, 'crossing-deadline.pdf', 504);
  execute 'reset role';
  insert into storage.objects (bucket_id, name, metadata) values ('presentation-pdfs', late_finalize, '{"size":504,"mimetype":"application/pdf"}');
  update public.event_settings set submission_deadline = now() - interval '1 second';
  execute 'set local role service_role';
  begin
    perform public.complete_presentation(rep, corrected_account, late_finalize, 504);
    raise exception 'upload started before deadline finalized after closing';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.prepare_presentation(rep, corrected_account, 4, 'late.pdf', 500);
    raise exception 'expired deadline accepted';
  exception when invalid_parameter_value then null;
  end;
  execute 'reset role';
  if (select current_path from public.submissions where team_id = team) is distinct from abandoned
    or (select version from public.submissions where team_id = team) <> 4 then
    raise exception 'late upload replaced the accepted final PDF';
  end if;
end;
$$;

select '1..1' as tap;
select 'ok 1 - PDF verification boundary, access, replacement and cleanup invariants' as tap;
rollback;

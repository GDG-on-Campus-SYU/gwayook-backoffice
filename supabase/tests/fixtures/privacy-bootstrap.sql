-- Disposable local PostgreSQL only; minimal Auth/Storage API schema for SQL tests.
create role anon noinherit;
create role authenticated noinherit;
create role service_role noinherit bypassrls;
create schema auth;
create table auth.users(id uuid primary key,email text not null,email_confirmed_at timestamptz);
create table auth.identities(provider_id text not null,user_id uuid references auth.users(id),provider text not null,identity_data jsonb);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid; $$;
grant usage on schema auth to anon,authenticated,service_role;
create schema storage;
create table storage.buckets(id text primary key,name text not null,public boolean not null default false,file_size_limit bigint,allowed_mime_types text[]);
create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text references storage.buckets(id),name text,metadata jsonb,owner_id text,owner uuid,created_at timestamptz default now(),updated_at timestamptz default now(),unique(bucket_id,name));
alter table storage.objects enable row level security;
grant usage on schema storage to anon,authenticated,service_role;
grant select,insert on storage.objects to authenticated;
grant all on storage.buckets,storage.objects to service_role;

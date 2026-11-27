-- Disposable PostgreSQL fixture ONLY. Never run this file in Supabase.
create role anon nologin;
create role authenticated nologin;
create schema auth;
create table auth.users (
 id uuid primary key,
 email text,
 email_confirmed_at timestamptz,
 created_at timestamptz not null default now()
);
create function auth.uid() returns uuid language sql stable as $$
 select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid
$$;
grant usage on schema auth to anon,authenticated;
grant execute on function auth.uid() to anon,authenticated;
create table public.portfleet_owner(user_id uuid primary key references auth.users(id));
alter table public.portfleet_owner enable row level security;
grant select on public.portfleet_owner to authenticated;
create policy test_owner_self on public.portfleet_owner for select to authenticated using (user_id=auth.uid());
insert into auth.users(id,email,email_confirmed_at) values
 ('00000000-0000-4000-8000-000000000001','owner@example.invalid',now()),
 ('00000000-0000-4000-8000-000000000002','personal-a@example.invalid',now()),
 ('00000000-0000-4000-8000-000000000003','personal-b@example.invalid',now()),
 ('00000000-0000-4000-8000-000000000004','staff@example.invalid',now()),
 ('00000000-0000-4000-8000-000000000005','unconfirmed@example.invalid',null);
insert into public.portfleet_owner values ('00000000-0000-4000-8000-000000000001');
create schema fixture;
create function fixture.snapshot(a text) returns jsonb language sql immutable as $$
 select jsonb_build_object('version',1,'assets',jsonb_build_array(jsonb_build_object('id','a','code',a)), 'staff','[]'::jsonb,'requests','[]'::jsonb,'assignments','[]'::jsonb,'cranes','[]'::jsonb,'fuel','[]'::jsonb,'work','[]'::jsonb,'plans','[]'::jsonb,'parts','[]'::jsonb,'moves','[]'::jsonb,'oils','[]'::jsonb,'audit','[]'::jsonb)
$$;
grant usage on schema fixture to authenticated,anon;
grant execute on function fixture.snapshot(text) to authenticated,anon;

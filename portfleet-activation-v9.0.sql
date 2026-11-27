-- Port Fleet V9.0: one cumulative activation script. Existing owner records remain unchanged.
-- Run after the existing owner and central-state setup (V8.1).
begin;

-- portfleet-staff-v8.5.sql

create table if not exists public.portfleet_staff_access (
 user_id uuid primary key references auth.users(id) on delete cascade,
 enabled boolean not null default false,
 sections text[] not null default '{}',
 updated_at timestamptz not null default now(),
 check (sections <@ array['cranes','requests','assignments','parts','fuel','oils']::text[])
);
alter table public.portfleet_staff_access enable row level security;
revoke all on public.portfleet_staff_access from public, anon, authenticated;

create or replace function public.portfleet_staff_list()
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
 if not exists(select 1 from public.portfleet_owner where user_id=auth.uid()) then
  raise exception 'OWNER_REQUIRED' using errcode='42501';
 end if;
 return coalesce((select jsonb_agg(to_jsonb(q)) from (
  select u.id, u.email, (u.email_confirmed_at is not null) as confirmed,
   coalesce(a.enabled,false) as enabled, coalesce(a.sections,'{}'::text[]) as sections
  from auth.users u left join public.portfleet_staff_access a on a.user_id=u.id
  where u.email is not null and not exists(select 1 from public.portfleet_owner o where o.user_id=u.id)
  order by u.created_at desc limit 200
 ) q),'[]'::jsonb);
end;
$$;

create or replace function public.portfleet_staff_set(p_user uuid,p_enabled boolean,p_sections text[])
returns boolean language plpgsql security definer set search_path = '' as $$
begin
 if not exists(select 1 from public.portfleet_owner where user_id=auth.uid()) then
  raise exception 'OWNER_REQUIRED' using errcode='42501';
 end if;
 if p_user is null or p_enabled is null or p_sections is null
 or cardinality(p_sections)>6 or array_position(p_sections,null) is not null
 or not (p_sections <@ array['cranes','requests','assignments','parts','fuel','oils']::text[])
 or (p_enabled and cardinality(p_sections)=0)
 or not exists(select 1 from auth.users where id=p_user and email is not null)
 or exists(select 1 from public.portfleet_owner where user_id=p_user) then
  raise exception 'INVALID_ACCESS' using errcode='22023';
 end if;
 insert into public.portfleet_staff_access(user_id,enabled,sections)
 values(p_user,p_enabled,p_sections)
 on conflict(user_id) do update set enabled=excluded.enabled,sections=excluded.sections,updated_at=now();
 return true;
end;
$$;

create or replace function public.portfleet_staff_overview()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
 allowed text[];
 snap jsonb;
 result jsonb := '{}'::jsonb;
 sect text;
 asset_type text;
 asset_count bigint;
 record_count bigint;
begin
 select a.sections into allowed from public.portfleet_staff_access a
 join auth.users u on u.id=a.user_id
 where a.user_id=auth.uid() and a.enabled and u.email_confirmed_at is not null;
 if allowed is null or cardinality(allowed)=0 then
  raise exception 'STAFF_ACCESS_DENIED' using errcode='42501';
 end if;
 select s.snapshot into snap from public.portfleet_state s
 join public.portfleet_owner o on o.user_id=s.owner_id limit 1;
 snap:=coalesce(snap,'{}'::jsonb);
 foreach sect in array allowed loop
  asset_type:=case sect when 'cranes' then 'رافعة' when 'requests' then 'سيارة خدمة' when 'assignments' then 'سيارة مخصصة' else null end;
  record_count:=jsonb_array_length(coalesce(snap->sect,'[]'::jsonb));
  if asset_type is not null then
   select count(*) into asset_count from jsonb_array_elements(coalesce(snap->'assets','[]'::jsonb)) x where x->>'type'=asset_type;
   result:=result||jsonb_build_object(sect,jsonb_build_object('records',record_count,'assets',asset_count));
  else
   result:=result||jsonb_build_object(sect,jsonb_build_object('records',record_count));
  end if;
 end loop;
 return result;
end;
$$;
revoke all on function public.portfleet_staff_list() from public, anon, authenticated;
revoke all on function public.portfleet_staff_set(uuid,boolean,text[]) from public, anon, authenticated;
revoke all on function public.portfleet_staff_overview() from public, anon, authenticated;
grant execute on function public.portfleet_staff_list() to authenticated;
grant execute on function public.portfleet_staff_set(uuid,boolean,text[]) to authenticated;
grant execute on function public.portfleet_staff_overview() to authenticated;


-- portfleet-personal-v8.7.sql
-- Port Fleet V8.7: isolated personal snapshot per authenticated account.
-- Run in the dedicated Port Fleet Supabase SQL editor, not the fish-market project.

create table if not exists public.portfleet_personal_state (
  user_id uuid primary key references auth.users(id) on delete cascade,
  revision bigint not null check (revision > 0),
  snapshot jsonb not null check (jsonb_typeof(snapshot) = 'object'),
  updated_at timestamptz not null default now()
);
alter table public.portfleet_personal_state enable row level security;
revoke all on public.portfleet_personal_state from public, anon, authenticated;
grant select on public.portfleet_personal_state to authenticated;
drop policy if exists portfleet_personal_state_self_read on public.portfleet_personal_state;
create policy portfleet_personal_state_self_read on public.portfleet_personal_state
for select to authenticated
using (user_id = (select auth.uid()));
create or replace function public.portfleet_personal_save(p_expected bigint, p_snapshot jsonb)
returns bigint
language plpgsql security definer set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_revision bigint;
  v_key text;
begin
  if v_user is null or not exists (
    select 1 from auth.users u where u.id = v_user and u.email_confirmed_at is not null
  ) then raise exception 'CONFIRMED_ACCOUNT_REQUIRED' using errcode = '42501'; end if;
  if p_expected is null or p_expected < 0
     or jsonb_typeof(p_snapshot) is distinct from 'object'
     or p_snapshot->'version' is distinct from '1'::jsonb
     or octet_length(p_snapshot::text) > 2097152
  then raise exception 'INVALID_SNAPSHOT' using errcode = '22023'; end if;
  foreach v_key in array array['assets','staff','requests','assignments','cranes','fuel','work','plans','parts','moves','oils','audit'] loop
    if jsonb_typeof(p_snapshot->v_key) is distinct from 'array' then
      raise exception 'INVALID_SNAPSHOT' using errcode = '22023';
    end if;
    if exists(select 1 from jsonb_array_elements(p_snapshot->v_key) as x(value)
      where jsonb_typeof(x.value) is distinct from 'object'
         or jsonb_typeof(x.value->'id') is distinct from 'string') then
      raise exception 'INVALID_RECORD' using errcode = '22023';
    end if;
  end loop;
  if p_expected = 0 then
    insert into public.portfleet_personal_state(user_id,revision,snapshot)
    values(v_user,1,p_snapshot) on conflict(user_id) do nothing
    returning revision into v_revision;
  else
    update public.portfleet_personal_state set revision=revision+1,snapshot=p_snapshot,updated_at=now()
    where user_id=v_user and revision=p_expected returning revision into v_revision;
  end if;
  if v_revision is null then raise exception 'REVISION_CONFLICT' using errcode='40001'; end if;
  return v_revision;
end;
$$;
revoke all on function public.portfleet_personal_save(bigint,jsonb) from public, anon, authenticated;
grant execute on function public.portfleet_personal_save(bigint,jsonb) to authenticated;


-- portfleet-staff-write-v8.11.sql
-- V8.11: cumulative employee permissions and controlled service-request creation.
-- Independent personal accounts remain accessible without owner approval.

alter table public.portfleet_staff_access
 add column if not exists full_name text not null default '',
 add column if not exists department text not null default '',
 add column if not exists job_title text not null default '',
 add column if not exists employee_no text not null default '',
 add column if not exists revision bigint not null default 1,
 add column if not exists detail_sections text[] not null default '{}',
 add column if not exists request_create boolean not null default false;

create table if not exists public.portfleet_staff_history (
 id bigint generated always as identity primary key,
 actor_id uuid not null,
 target_id uuid not null,
 target_email text,
 changed_at timestamptz not null default now(),
 previous jsonb,
 current_value jsonb not null
);
alter table public.portfleet_staff_history enable row level security;
revoke all on public.portfleet_staff_history from public, anon, authenticated;

create or replace function public.portfleet_staff_track()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
 before_value jsonb;
 after_value jsonb;
begin
 if auth.uid() is null or not exists(select 1 from public.portfleet_owner where user_id=auth.uid()) then
  raise exception 'OWNER_REQUIRED' using errcode='42501';
 end if;
 if new.enabled and not exists(select 1 from auth.users where id=new.user_id and email_confirmed_at is not null) then
  raise exception 'EMAIL_CONFIRMATION_REQUIRED' using errcode='22023';
 end if;
 new.detail_sections:=array(select distinct v from unnest(new.detail_sections) as x(v) where v=any(new.sections) and new.enabled order by v);
 new.request_create:=new.request_create and new.enabled and 'requests'=any(new.sections) and 'requests'=any(new.detail_sections);
 if tg_op='UPDATE' then
  if old.user_id<>new.user_id then raise exception 'INVALID_ACCOUNT' using errcode='22023'; end if;
  before_value:=jsonb_build_object('name',old.full_name,'department',old.department,'job',old.job_title,'employee_no',old.employee_no,'enabled',old.enabled,'sections',old.sections,'details',old.detail_sections,'request_create',old.request_create);
  new.revision:=old.revision+1;
 else
  new.revision:=1;
 end if;
 new.updated_at:=now();
 after_value:=jsonb_build_object('name',new.full_name,'department',new.department,'job',new.job_title,'employee_no',new.employee_no,'enabled',new.enabled,'sections',new.sections,'details',new.detail_sections,'request_create',new.request_create);
 if before_value is distinct from after_value then
  insert into public.portfleet_staff_history(actor_id,target_id,target_email,previous,current_value)
  values(auth.uid(),new.user_id,(select email from auth.users where id=new.user_id),before_value,after_value);
 end if;
 return new;
end;
$$;
drop trigger if exists portfleet_staff_track_changes on public.portfleet_staff_access;
create trigger portfleet_staff_track_changes before insert or update on public.portfleet_staff_access
for each row execute function public.portfleet_staff_track();

create or replace function public.portfleet_staff_directory(p_search text default '',p_filter text default 'all',p_offset integer default 0)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
 result jsonb;
begin
 if not exists(select 1 from public.portfleet_owner where user_id=auth.uid()) then
  raise exception 'OWNER_REQUIRED' using errcode='42501';
 end if;
 if p_search is null or char_length(p_search)>200 or p_offset is null or p_offset<0 or p_filter is null or p_filter not in ('all','shared','personal','unconfirmed','staff') then
  raise exception 'INVALID_FILTER' using errcode='22023';
 end if;
 with accounts as (
 select u.id,u.email,u.created_at,(u.email_confirmed_at is not null) as confirmed,
 coalesce(a.enabled,false) as enabled,coalesce(a.sections,'{}'::text[]) as sections,
 coalesce(a.detail_sections,'{}'::text[]) as detail_sections,
 coalesce(a.request_create,false) as request_create,
 coalesce(a.full_name,'') as full_name,coalesce(a.department,'') as department,
 coalesce(a.job_title,'') as job_title,coalesce(a.employee_no,'') as employee_no,
 coalesce(a.revision,0) as revision,a.updated_at
 from auth.users u left join public.portfleet_staff_access a on a.user_id=u.id
 where u.email is not null and not exists(select 1 from public.portfleet_owner o where o.user_id=u.id)
 ), filtered as (
 select * from accounts where
 (p_filter='all' or (p_filter='shared' and enabled) or (p_filter='personal' and not enabled) or (p_filter='unconfirmed' and not confirmed) or (p_filter='staff' and (full_name<>'' or employee_no<>'')))
 and (p_search='' or strpos(lower(concat_ws(' ',email,full_name,department,job_title,employee_no)),lower(p_search))>0)
 ), page_rows as (select * from filtered order by created_at desc,id limit 50 offset p_offset)
 select jsonb_build_object(
 'total',(select count(*) from filtered),
 'counts',(select jsonb_build_object('all',count(*),'shared',count(*) filter(where enabled),'personal',count(*) filter(where not enabled),'unconfirmed',count(*) filter(where not confirmed)) from accounts),
 'rows',coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at desc,p.id) from page_rows p),'[]'::jsonb)
 ) into result;
 return result;
end;
$$;

create or replace function public.portfleet_staff_update(p_user uuid,p_expected bigint,p_enabled boolean,p_sections text[],p_name text,p_department text,p_job text,p_number text)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
 result bigint;
begin
 if not exists(select 1 from public.portfleet_owner where user_id=auth.uid()) then
  raise exception 'OWNER_REQUIRED' using errcode='42501';
 end if;
 if p_user is null or p_expected is null or p_expected<0 or p_enabled is null
 or p_sections is null or cardinality(p_sections)>6 or array_position(p_sections,null) is not null
 or not (p_sections <@ array['cranes','requests','assignments','parts','fuel','oils']::text[])
 or (p_enabled and cardinality(p_sections)=0)
 or not exists(select 1 from auth.users where id=p_user and email is not null)
 or exists(select 1 from public.portfleet_owner where user_id=p_user)
 or p_name is null or char_length(p_name)>120
 or p_department is null or char_length(p_department)>120
 or p_job is null or char_length(p_job)>120
 or p_number is null or char_length(p_number)>60 then
  raise exception 'INVALID_ACCESS' using errcode='22023';
 end if;
 if p_expected=0 then
  -- Lock on the account row so a stale insert cannot create a false history entry.
  perform 1 from auth.users where id=p_user for update;
  if exists(select 1 from public.portfleet_staff_access where user_id=p_user) then
   raise exception 'REVISION_CONFLICT' using errcode='40001';
  end if;
  insert into public.portfleet_staff_access(user_id,enabled,sections,full_name,department,job_title,employee_no)
  values(p_user,p_enabled,p_sections,btrim(p_name),btrim(p_department),btrim(p_job),btrim(p_number))
  returning revision into result;
 else
  update public.portfleet_staff_access set enabled=p_enabled,sections=p_sections,full_name=btrim(p_name),
  department=btrim(p_department),job_title=btrim(p_job),employee_no=btrim(p_number)
  where user_id=p_user and revision=p_expected returning revision into result;
 end if;
 if result is null then raise exception 'REVISION_CONFLICT' using errcode='40001'; end if;
 return result;
end;
$$;

create or replace function public.portfleet_staff_history_list()
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
 if not exists(select 1 from public.portfleet_owner where user_id=auth.uid()) then
  raise exception 'OWNER_REQUIRED' using errcode='42501';
 end if;
 return coalesce((select jsonb_agg(to_jsonb(q) order by q.id desc) from (
 select h.id,h.target_email,h.changed_at,h.previous,h.current_value,
 (select u.email from auth.users u where u.id=h.actor_id) as actor_email
 from public.portfleet_staff_history h order by h.id desc limit 100
 ) q),'[]'::jsonb);
end;
$$;
revoke all on function public.portfleet_staff_track() from public,anon,authenticated;
revoke all on function public.portfleet_staff_directory(text,text,integer) from public,anon,authenticated;
revoke all on function public.portfleet_staff_update(uuid,bigint,boolean,text[],text,text,text,text) from public,anon,authenticated;
revoke all on function public.portfleet_staff_history_list() from public,anon,authenticated;
grant execute on function public.portfleet_staff_directory(text,text,integer) to authenticated;
grant execute on function public.portfleet_staff_update(uuid,bigint,boolean,text[],text,text,text,text) to authenticated;
grant execute on function public.portfleet_staff_history_list() to authenticated;
-- Replace the old writer so older clients use the same revision-aware path.
create or replace function public.portfleet_staff_set(p_user uuid,p_enabled boolean,p_sections text[])
returns boolean language plpgsql security definer set search_path = '' as $$
declare
 a public.portfleet_staff_access%rowtype;
begin
 if not exists(select 1 from public.portfleet_owner where user_id=auth.uid()) then
  raise exception 'OWNER_REQUIRED' using errcode='42501';
 end if;
 select * into a from public.portfleet_staff_access where user_id=p_user;
 perform public.portfleet_staff_update(p_user,coalesce(a.revision,0),p_enabled,p_sections,coalesce(a.full_name,''),coalesce(a.department,''),coalesce(a.job_title,''),coalesce(a.employee_no,''));
 return true;
end;
$$;
revoke all on function public.portfleet_staff_set(uuid,boolean,text[]) from public,anon,authenticated;
grant execute on function public.portfleet_staff_set(uuid,boolean,text[]) to authenticated;
create or replace function public.portfleet_staff_update_v810(p_user uuid,p_expected bigint,p_enabled boolean,p_sections text[],p_name text,p_department text,p_job text,p_number text,p_details text[])
returns bigint language plpgsql security definer set search_path = '' as $$
declare
 result bigint;
begin
 if not exists(select 1 from public.portfleet_owner where user_id=auth.uid()) then
  raise exception 'OWNER_REQUIRED' using errcode='42501';
 end if;
 if p_user is null or p_expected is null or p_expected<0 or p_enabled is null
 or p_sections is null or cardinality(p_sections)>6 or array_position(p_sections,null) is not null
 or not (p_sections <@ array['cranes','requests','assignments','parts','fuel','oils']::text[])
 or (p_enabled and cardinality(p_sections)=0)
 or p_details is null or cardinality(p_details)>6 or array_position(p_details,null) is not null
 or not (p_details <@ p_sections) or (not p_enabled and cardinality(p_details)>0)
 or not exists(select 1 from auth.users where id=p_user and email is not null)
 or exists(select 1 from public.portfleet_owner where user_id=p_user)
 or p_name is null or char_length(p_name)>120
 or p_department is null or char_length(p_department)>120
 or p_job is null or char_length(p_job)>120
 or p_number is null or char_length(p_number)>60 then
  raise exception 'INVALID_ACCESS' using errcode='22023';
 end if;
 if p_expected=0 then
  -- Lock on the account row so a stale insert cannot create a false history entry.
  perform 1 from auth.users where id=p_user for update;
  if exists(select 1 from public.portfleet_staff_access where user_id=p_user) then
   raise exception 'REVISION_CONFLICT' using errcode='40001';
  end if;
  insert into public.portfleet_staff_access(user_id,enabled,sections,full_name,department,job_title,employee_no,detail_sections)
  values(p_user,p_enabled,p_sections,btrim(p_name),btrim(p_department),btrim(p_job),btrim(p_number),p_details)
  returning revision into result;
 else
  update public.portfleet_staff_access set enabled=p_enabled,sections=p_sections,full_name=btrim(p_name),
  department=btrim(p_department),job_title=btrim(p_job),employee_no=btrim(p_number),detail_sections=p_details
  where user_id=p_user and revision=p_expected returning revision into result;
 end if;
 if result is null then raise exception 'REVISION_CONFLICT' using errcode='40001'; end if;
 return result;
end;
$$;


revoke all on function public.portfleet_staff_update_v810(uuid,bigint,boolean,text[],text,text,text,text,text[]) from public,anon,authenticated;
grant execute on function public.portfleet_staff_update_v810(uuid,bigint,boolean,text[],text,text,text,text,text[]) to authenticated;

create or replace function public.portfleet_staff_records(p_section text,p_offset integer default 0)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
 snap jsonb;
 records jsonb;
 result jsonb;
begin
 if p_section is null or p_section not in ('cranes','requests','assignments','parts','fuel','oils')
 or p_offset is null or p_offset<0 then raise exception 'INVALID_FILTER' using errcode='22023'; end if;
 if not exists(
  select 1 from public.portfleet_staff_access a join auth.users u on u.id=a.user_id
  where a.user_id=auth.uid() and a.enabled and u.email_confirmed_at is not null
  and p_section=any(a.sections) and p_section=any(a.detail_sections)
 ) then raise exception 'STAFF_ACCESS_DENIED' using errcode='42501'; end if;
 select s.snapshot into snap from public.portfleet_state s
 join public.portfleet_owner o on o.user_id=s.owner_id limit 1;
 snap:=coalesce(snap,'{}'::jsonb);
 records:=coalesce(snap->p_section,'[]'::jsonb);
 with page_rows as (
 select x.value as r,x.ordinality as ord from jsonb_array_elements(records) with ordinality x(value,ordinality)
 order by x.ordinality desc limit 50 offset p_offset
 ), mapped as (
 select ord, case p_section
  when 'cranes' then jsonb_build_object('date',r->>'date','asset',asset_code,'shift',r->>'shift','work',r->>'work','tons',r->>'tons')
  when 'requests' then jsonb_build_object('department',r->>'dept','start',r->>'start','end',r->>'end','status',r->>'status','asset',asset_code)
  when 'assignments' then jsonb_build_object('asset',asset_code,'date',r->>'date','returned',r->>'returned')
  when 'parts' then jsonb_build_object('code',r->>'code','name',r->>'name','qty',r->>'qty','min',r->>'min','compat',r->>'compat')
  when 'fuel' then jsonb_build_object('date',r->>'date','asset',asset_code,'kind',r->>'kind','qty',r->>'qty','meter',r->>'meter')
  when 'oils' then jsonb_build_object('date',r->>'date','asset',asset_code,'oil',r->>'oil','qty',r->>'qty','meter',r->>'meter','nextDate',r->>'nextDate')
 end as row_value
 from page_rows
 cross join lateral (select (select a.value->>'code' from jsonb_array_elements(coalesce(snap->'assets','[]'::jsonb)) a(value) where a.value->>'id'=r->>'asset' limit 1) as asset_code) b
 )
 select jsonb_build_object('total',jsonb_array_length(records),'rows',coalesce(jsonb_agg(row_value order by ord desc),'[]'::jsonb)) into result from mapped;
 return result;
end;
$$;
revoke all on function public.portfleet_staff_records(text,integer) from public,anon,authenticated;
grant execute on function public.portfleet_staff_records(text,integer) to authenticated;

create or replace function public.portfleet_staff_detail_access()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare result jsonb;
begin
 select to_jsonb(a.detail_sections) into result from public.portfleet_staff_access a
 join auth.users u on u.id=a.user_id
 where a.user_id=auth.uid() and a.enabled and u.email_confirmed_at is not null;
 return coalesce(result,'[]'::jsonb);
end;
$$;
revoke all on function public.portfleet_staff_detail_access() from public,anon,authenticated;
grant execute on function public.portfleet_staff_detail_access() to authenticated;

create or replace function public.portfleet_staff_update_v811(p_user uuid,p_expected bigint,p_enabled boolean,p_sections text[],p_name text,p_department text,p_job text,p_number text,p_details text[],p_request_create boolean)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
 result bigint;
begin
 if not exists(select 1 from public.portfleet_owner where user_id=auth.uid()) then
  raise exception 'OWNER_REQUIRED' using errcode='42501';
 end if;
 if p_user is null or p_expected is null or p_expected<0 or p_enabled is null
 or p_sections is null or cardinality(p_sections)>6 or array_position(p_sections,null) is not null
 or not (p_sections <@ array['cranes','requests','assignments','parts','fuel','oils']::text[])
 or (p_enabled and cardinality(p_sections)=0)
 or p_details is null or cardinality(p_details)>6 or array_position(p_details,null) is not null
 or not (p_details <@ p_sections) or (not p_enabled and cardinality(p_details)>0)
 or p_request_create is null or (p_request_create and (not p_enabled or not ('requests'=any(p_sections)) or not ('requests'=any(p_details))))
 or not exists(select 1 from auth.users where id=p_user and email is not null)
 or exists(select 1 from public.portfleet_owner where user_id=p_user)
 or p_name is null or char_length(p_name)>120
 or p_department is null or char_length(p_department)>120
 or p_job is null or char_length(p_job)>120
 or p_number is null or char_length(p_number)>60 then
  raise exception 'INVALID_ACCESS' using errcode='22023';
 end if;
 if p_expected=0 then
  -- Lock on the account row so a stale insert cannot create a false history entry.
  perform 1 from auth.users where id=p_user for update;
  if exists(select 1 from public.portfleet_staff_access where user_id=p_user) then
   raise exception 'REVISION_CONFLICT' using errcode='40001';
  end if;
  insert into public.portfleet_staff_access(user_id,enabled,sections,full_name,department,job_title,employee_no,detail_sections,request_create)
  values(p_user,p_enabled,p_sections,btrim(p_name),btrim(p_department),btrim(p_job),btrim(p_number),p_details,p_request_create)
  returning revision into result;
 else
  update public.portfleet_staff_access set enabled=p_enabled,sections=p_sections,full_name=btrim(p_name),
  department=btrim(p_department),job_title=btrim(p_job),employee_no=btrim(p_number),detail_sections=p_details,request_create=p_request_create
  where user_id=p_user and revision=p_expected returning revision into result;
 end if;
 if result is null then raise exception 'REVISION_CONFLICT' using errcode='40001'; end if;
 return result;
end;
$$;



revoke all on function public.portfleet_staff_update_v811(uuid,bigint,boolean,text[],text,text,text,text,text[],boolean) from public,anon,authenticated;
grant execute on function public.portfleet_staff_update_v811(uuid,bigint,boolean,text[],text,text,text,text,text[],boolean) to authenticated;

create table if not exists public.portfleet_staff_operations (
 id uuid primary key,
 actor_id uuid not null,
 actor_email text not null,
 actor_name text not null,
 owner_id uuid not null,
 created_at timestamptz not null default now(),
 operation text not null,
 payload jsonb not null,
 resulting_revision bigint not null
);
alter table public.portfleet_staff_operations enable row level security;
revoke all on public.portfleet_staff_operations from public,anon,authenticated;

create or replace function public.portfleet_staff_can_create_request()
returns boolean language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.portfleet_staff_access a join auth.users u on u.id=a.user_id
 where a.user_id=auth.uid() and u.email_confirmed_at is not null and a.enabled and a.request_create
 and 'requests'=any(a.sections) and 'requests'=any(a.detail_sections));
$$;

create or replace function public.portfleet_staff_add_request(p_id uuid,p_department text,p_purpose text,p_start text,p_end text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
 v_actor uuid := auth.uid();
 v_email text;
 v_name text;
 v_owner uuid;
 v_state jsonb;
 v_revision bigint;
 v_request jsonb;
 v_existing public.portfleet_staff_operations%rowtype;
 v_start timestamp;
 v_end timestamp;
begin
 -- Lock the permission row until the write commits, so permission revocation is serialized.
 select u.email,a.full_name into v_email,v_name
 from public.portfleet_staff_access a join auth.users u on u.id=a.user_id
 where a.user_id=v_actor and u.email_confirmed_at is not null and a.enabled and a.request_create
 and 'requests'=any(a.sections) and 'requests'=any(a.detail_sections)
 for share of a;
 if not found then raise exception 'STAFF_ACCESS_DENIED' using errcode='42501'; end if;
 if p_id is null or p_department is null or char_length(btrim(p_department)) not between 1 and 120
 or p_purpose is null or char_length(btrim(p_purpose)) not between 1 and 500
 or p_start is null or p_end is null
 or p_start !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}$'
 or p_end !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}$'
 then raise exception 'INVALID_REQUEST' using errcode='22023'; end if;
 begin v_start:=p_start::timestamp;v_end:=p_end::timestamp;
 exception when others then raise exception 'INVALID_DATE' using errcode='22023'; end;
 if v_end<=v_start or to_char(v_start,'YYYY-MM-DD"T"HH24:MI')<>p_start
 or to_char(v_end,'YYYY-MM-DD"T"HH24:MI')<>p_end then
 raise exception 'INVALID_DATE' using errcode='22023'; end if;
 v_request:=jsonb_build_object('id',p_id::text,'dept',btrim(p_department),'purpose',btrim(p_purpose),
 'start',p_start,'end',p_end,'status','معلق','created_by',v_actor::text);
 select s.owner_id,s.snapshot,s.revision into v_owner,v_state,v_revision
 from public.portfleet_state s join public.portfleet_owner o on o.user_id=s.owner_id for update of s;
 if not found then raise exception 'OWNER_SNAPSHOT_REQUIRED' using errcode='22023'; end if;
 -- Same id and payload may safely be retried after a lost response.
 select * into v_existing from public.portfleet_staff_operations where id=p_id;
 if found then
  if v_existing.actor_id=v_actor and v_existing.owner_id=v_owner and v_existing.payload=v_request then
   return jsonb_build_object('id',p_id,'revision',v_existing.resulting_revision);
  end if;
  raise exception 'DUPLICATE_REQUEST_ID' using errcode='22023';
 end if;
 if exists(select 1 from jsonb_array_elements(v_state->'requests') as x(value) where x.value->>'id'=p_id::text) then
  raise exception 'DUPLICATE_REQUEST_ID' using errcode='22023';
 end if;
 v_state:=jsonb_set(v_state,'{requests}',(v_state->'requests')||jsonb_build_array(v_request));
 if octet_length(v_state::text)>2097152 then raise exception 'SNAPSHOT_LIMIT' using errcode='22023'; end if;
 update public.portfleet_state set snapshot=v_state,revision=revision+1,updated_at=now()
 where owner_id=v_owner returning revision into v_revision;
 insert into public.portfleet_staff_operations(id,actor_id,actor_email,actor_name,owner_id,operation,payload,resulting_revision)
 values(p_id,v_actor,coalesce(v_email,''),coalesce(v_name,''),v_owner,'create_service_request',v_request,v_revision);
 return jsonb_build_object('id',p_id,'revision',v_revision);
end;
$$;

create or replace function public.portfleet_staff_operation_list()
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
 if not exists(select 1 from public.portfleet_owner where user_id=auth.uid()) then
  raise exception 'OWNER_REQUIRED' using errcode='42501';
 end if;
 return coalesce((select jsonb_agg(to_jsonb(q) order by q.created_at desc,q.id desc) from (
 select id,actor_email,actor_name,created_at,operation,payload,resulting_revision
 from public.portfleet_staff_operations where owner_id=auth.uid()
 order by created_at desc,id desc limit 100
 ) q),'[]'::jsonb);
end;
$$;
revoke all on function public.portfleet_staff_can_create_request() from public,anon,authenticated;
revoke all on function public.portfleet_staff_add_request(uuid,text,text,text,text) from public,anon,authenticated;
revoke all on function public.portfleet_staff_operation_list() from public,anon,authenticated;
grant execute on function public.portfleet_staff_can_create_request() to authenticated;
grant execute on function public.portfleet_staff_add_request(uuid,text,text,text,text) to authenticated;
grant execute on function public.portfleet_staff_operation_list() to authenticated;



notify pgrst, 'reload schema';
commit;

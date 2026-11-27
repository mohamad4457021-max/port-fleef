-- V8.10: employee directory and independent detailed-read permissions.
-- Independent personal accounts remain accessible without owner approval.
begin;
alter table public.portfleet_staff_access
 add column if not exists full_name text not null default '',
 add column if not exists department text not null default '',
 add column if not exists job_title text not null default '',
 add column if not exists employee_no text not null default '',
 add column if not exists revision bigint not null default 1,
 add column if not exists detail_sections text[] not null default '{}';

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
 if tg_op='UPDATE' then
  if old.user_id<>new.user_id then raise exception 'INVALID_ACCOUNT' using errcode='22023'; end if;
  before_value:=jsonb_build_object('name',old.full_name,'department',old.department,'job',old.job_title,'employee_no',old.employee_no,'enabled',old.enabled,'sections',old.sections,'details',old.detail_sections);
  new.revision:=old.revision+1;
 else
  new.revision:=1;
 end if;
 new.updated_at:=now();
 after_value:=jsonb_build_object('name',new.full_name,'department',new.department,'job',new.job_title,'employee_no',new.employee_no,'enabled',new.enabled,'sections',new.sections,'details',new.detail_sections);
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

notify pgrst, 'reload schema';
commit;

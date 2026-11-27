-- STAGING ONLY until owner TOTP is enrolled and recovery tested.
-- Apply after phase1 and updated owner UI. Mandatory AAL2 for owner data, not personal or staff.
begin;
create function public.portfleet_owner_aal2()
returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and coalesce(auth.jwt()->>'aal','')='aal2'
 and exists(select 1 from public.portfleet_owner o where o.user_id=auth.uid());
$$;
revoke all on function public.portfleet_owner_aal2() from public,anon,authenticated;
grant execute on function public.portfleet_owner_aal2() to authenticated;
-- Keep owner identity lookup available at AAL1 for the challenge flow.
create policy pf_owner_mfa_read on public.portfleet_state as restrictive
for select to authenticated using ((select public.portfleet_owner_aal2()));
create or replace function public.portfleet_save(p_expected bigint, p_snapshot jsonb)
returns bigint
language plpgsql security definer set search_path = ''
as $$
declare
  v_owner uuid := auth.uid();
  v_revision bigint;
  v_key text;
begin
  if not public.portfleet_owner_aal2() then raise exception 'OWNER_AAL2_REQUIRED' using errcode = '42501'; end if;
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
    insert into public.portfleet_state(owner_id,revision,snapshot)
    values(v_owner,1,p_snapshot) on conflict(owner_id) do nothing
    returning revision into v_revision;
  else
    update public.portfleet_state set revision=revision+1,snapshot=p_snapshot,updated_at=now()
    where owner_id=v_owner and revision=p_expected returning revision into v_revision;
  end if;
  if v_revision is null then raise exception 'REVISION_CONFLICT' using errcode='40001'; end if;
  return v_revision;
end;
$$;
create or replace function public.portfleet_staff_list()
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
 if not public.portfleet_owner_aal2() then
  raise exception 'OWNER_AAL2_REQUIRED' using errcode='42501';
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
declare
 a public.portfleet_staff_access%rowtype;
begin
 if not public.portfleet_owner_aal2() then
  raise exception 'OWNER_AAL2_REQUIRED' using errcode='42501';
 end if;
 select * into a from public.portfleet_staff_access where user_id=p_user;
 perform public.portfleet_staff_update(p_user,coalesce(a.revision,0),p_enabled,p_sections,coalesce(a.full_name,''),coalesce(a.department,''),coalesce(a.job_title,''),coalesce(a.employee_no,''));
 return true;
end;
$$;

create or replace function public.portfleet_staff_track()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
 before_value jsonb;
 after_value jsonb;
begin
 if not public.portfleet_owner_aal2() then
  raise exception 'OWNER_AAL2_REQUIRED' using errcode='42501';
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

create or replace function public.portfleet_staff_directory(p_search text default '',p_filter text default 'all',p_offset integer default 0)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
 result jsonb;
begin
 if not public.portfleet_owner_aal2() then
  raise exception 'OWNER_AAL2_REQUIRED' using errcode='42501';
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
 if not public.portfleet_owner_aal2() then
  raise exception 'OWNER_AAL2_REQUIRED' using errcode='42501';
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
 if not public.portfleet_owner_aal2() then
  raise exception 'OWNER_AAL2_REQUIRED' using errcode='42501';
 end if;
 return coalesce((select jsonb_agg(to_jsonb(q) order by q.id desc) from (
 select h.id,h.target_email,h.changed_at,h.previous,h.current_value,
 (select u.email from auth.users u where u.id=h.actor_id) as actor_email
 from public.portfleet_staff_history h order by h.id desc limit 100
 ) q),'[]'::jsonb);
end;
$$;

create or replace function public.portfleet_staff_update_v810(p_user uuid,p_expected bigint,p_enabled boolean,p_sections text[],p_name text,p_department text,p_job text,p_number text,p_details text[])
returns bigint language plpgsql security definer set search_path = '' as $$
declare
 result bigint;
begin
 if not public.portfleet_owner_aal2() then
  raise exception 'OWNER_AAL2_REQUIRED' using errcode='42501';
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

create or replace function public.portfleet_staff_update_v811(p_user uuid,p_expected bigint,p_enabled boolean,p_sections text[],p_name text,p_department text,p_job text,p_number text,p_details text[],p_request_create boolean)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
 result bigint;
begin
 if not public.portfleet_owner_aal2() then
  raise exception 'OWNER_AAL2_REQUIRED' using errcode='42501';
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

create or replace function public.portfleet_staff_operation_list()
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
 if not public.portfleet_owner_aal2() then
  raise exception 'OWNER_AAL2_REQUIRED' using errcode='42501';
 end if;
 return coalesce((select jsonb_agg(to_jsonb(q) order by q.created_at desc,q.id desc) from (
 select id,actor_email,actor_name,created_at,operation,payload,resulting_revision
 from public.portfleet_staff_operations where owner_id=auth.uid()
 order by created_at desc,id desc limit 100
 ) q),'[]'::jsonb);
end;
$$;

create or replace function public.portfleet_archive_list()
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
 if not public.portfleet_owner_aal2() then
  raise exception 'OWNER_AAL2_REQUIRED' using errcode='42501';
 end if;
 return coalesce((select jsonb_agg(to_jsonb(q) order by q.revision desc) from (
 select a.revision,a.archived_at,
 (select u.email from auth.users u where u.id=a.changed_by) as actor_email,
 octet_length(a.snapshot::text) as bytes
 from public.portfleet_secure_archive a where a.owner_id=auth.uid()
 order by a.revision desc limit 5
 ) q),'[]'::jsonb);
end;
$$;

create or replace function public.portfleet_archive_read(p_revision bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare result jsonb;
begin
 if not public.portfleet_owner_aal2() then
  raise exception 'OWNER_AAL2_REQUIRED' using errcode='42501';
 end if;
 if p_revision is null or p_revision<1 then raise exception 'INVALID_REVISION' using errcode='22023'; end if;
 select a.snapshot into result from public.portfleet_secure_archive a where a.owner_id=auth.uid() and a.revision=p_revision;
 if not found then raise exception 'ARCHIVE_NOT_FOUND' using errcode='22023'; end if;
 return result;
end;
$$;
notify pgrst,'reload schema';
commit;

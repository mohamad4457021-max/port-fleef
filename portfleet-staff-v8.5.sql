begin;
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
notify pgrst, 'reload schema';
commit;

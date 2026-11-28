-- Database V2 / stage 3: read-only migration diagnostics.
-- Run after 001 in a separate test database. No changes to V1 or V2 data.
begin;
create function portfleet_v2.preflight(p_owner uuid)
returns table(section text,issue text,affected_count bigint)
language plpgsql security invoker set search_path='' as $$
declare s jsonb; k text; a jsonb;
begin
 select snapshot into s from public.portfleet_state where owner_id=p_owner;
 if s is null then raise exception 'SOURCE_NOT_FOUND'; end if;
 if jsonb_typeof(s) is distinct from 'object' or s->'version' is distinct from '1'::jsonb then
   section:='snapshot';issue:='INVALID_VERSION_OR_SHAPE';affected_count:=1;return next;return;
 end if;
 foreach k in array array['assets','staff','parts','plans','work','requests','assignments','cranes','fuel','moves','oils','audit'] loop
   a:=s->k;
   section:=k;
   if jsonb_typeof(a) is distinct from 'array' then
     issue:='INVALID_SECTION';affected_count:=1;return next;continue;
   end if;
   select count(*) into affected_count from jsonb_array_elements(a) r(v)
     where jsonb_typeof(v) is distinct from 'object'
        or jsonb_typeof(v->'id') is distinct from 'string' or btrim(v->>'id')='';
   if affected_count>0 then issue:='INVALID_ID';return next;end if;
   select coalesce(sum(n-1),0)::bigint into affected_count from (
     select count(*) n from jsonb_array_elements(a) r(v)
     where jsonb_typeof(v->'id')='string' group by v->>'id' having count(*)>1
   ) d;
   if affected_count>0 then issue:='DUPLICATE_ID';return next;end if;
   if k in ('assets','staff','parts') then
     select count(*) into affected_count from jsonb_array_elements(a) r(v)
       where jsonb_typeof(v->'code') is distinct from 'string' or btrim(v->>'code')='';
     if affected_count>0 then issue:='MISSING_CODE';return next;end if;
     select coalesce(sum(n-1),0)::bigint into affected_count from (
       select count(*) n from jsonb_array_elements(a) r(v)
       where jsonb_typeof(v->'code')='string'
       group by lower(regexp_replace(btrim(translate(v->>'code','٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹','01234567890123456789')),'[[:space:]]+',' ','g'))
       having count(*)>1
     ) d;
     if affected_count>0 then issue:='DUPLICATE_CODE';return next;end if;
   end if;
 end loop;
 -- Reference checks never cast historical values. Invalid arrays are reported above.
 return query
 with specs(src,field,target,required) as (values
 ('plans','asset','assets',true),('work','asset','assets',true),('work','plan','plans',false),
 ('requests','asset','assets',false),('requests','driver','staff',false),
 ('assignments','asset','assets',true),('cranes','asset','assets',true),
 ('cranes','operator','staff',true),('fuel','asset','assets',false),
 ('moves','part','parts',true),('moves','work','work',false),('oils','asset','assets',true)
 ), findings as (
 select sp.src,sp.field,count(*) n from specs sp
 cross join lateral jsonb_array_elements(case when jsonb_typeof(s->sp.src)='array' then s->sp.src else '[]'::jsonb end) r(v)
 where (sp.required and coalesce(r.v->>sp.field,'')='')
 or (coalesce(r.v->>sp.field,'')<>'' and not exists (
   select 1 from jsonb_array_elements(case when jsonb_typeof(s->sp.target)='array' then s->sp.target else '[]'::jsonb end) t(v)
   where t.v->>'id'=r.v->>sp.field
 ))
 group by sp.src,sp.field
 )
 select src,('MISSING_REFERENCE:'||field)::text,n from findings;
end; $$;
revoke all on function portfleet_v2.preflight(uuid) from public, anon, authenticated;
commit;

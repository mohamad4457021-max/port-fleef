-- Run only AFTER migration in staging; no changes to application records.
begin;
do $$
declare s jsonb; bad jsonb; k text; n integer;
begin
 s:='{"version":1,"assets":[],"staff":[],"requests":[],"assignments":[],"cranes":[],"fuel":[],"work":[],"plans":[],"parts":[],"moves":[],"oils":[],"audit":[]}'::jsonb;
 perform portfleet_v2.validate_snapshot(s);
 bad:=jsonb_set(s,'{assets}','[{"id":"a"},{"id":"a"}]'::jsonb);
 begin
  perform portfleet_v2.validate_snapshot(bad);
  raise exception 'TEST_FAILED duplicate accepted';
 exception when invalid_parameter_value then null;
 end;
 begin
  perform portfleet_v2.validate_snapshot(s-'fuel');
  raise exception 'TEST_FAILED missing collection accepted';
 exception when invalid_parameter_value then null;
 end;
 begin
  perform portfleet_v2.validate_snapshot(jsonb_set(s,'{assets}','[{"id":""}]'));
  raise exception 'TEST_FAILED empty id accepted';
 exception when invalid_parameter_value then null;
 end;
 bad:=jsonb_set(s,'{cranes}','[{"id":"c","asset":"missing","operator":""}]');
 select count(*) into n from portfleet_v2.snapshot_links(bad);
 if n<>1 then raise exception 'TEST_FAILED link extraction'; end if;
 if has_schema_privilege('anon','portfleet_v2','USAGE') or has_schema_privilege('authenticated','portfleet_v2','USAGE') then
  raise exception 'TEST_FAILED private schema grant';
 end if;
 foreach k in array array['workspaces','records','record_links','revision_events'] loop
  if has_table_privilege('authenticated','portfleet_v2.'||k,'SELECT,INSERT,UPDATE,DELETE')
  or has_table_privilege('anon','portfleet_v2.'||k,'SELECT,INSERT,UPDATE,DELETE') then
   raise exception 'TEST_FAILED table permissions: %',k;
  end if;
 end loop;
 if has_function_privilege('authenticated','portfleet_v2.project_snapshot(text,uuid,bigint,jsonb,text)','EXECUTE') then
  raise exception 'TEST_FAILED privileged function executable';
 end if;
 if exists(select 1 from public.portfleet_state s left join portfleet_v2.workspaces w on w.scope='central' and w.account_id=s.owner_id where w.revision is distinct from s.revision)
 or exists(select 1 from public.portfleet_personal_state s left join portfleet_v2.workspaces w on w.scope='personal' and w.account_id=s.user_id where w.revision is distinct from s.revision) then
  raise exception 'TEST_FAILED revision parity';
 end if;
end;
$$;
-- Exact payload and ordering parity across all collections.
with src as (
 select 'central'::text scope,owner_id account_id,snapshot from public.portfleet_state
 union all select 'personal',user_id,snapshot from public.portfleet_personal_state
), expected as (
 select s.scope,s.account_id,k.collection,x.v->>'id' record_id,x.v payload,(x.ord-1)::integer position
 from src s cross join unnest(array['assets','staff','requests','assignments','cranes','fuel','work','plans','parts','moves','oils','audit']) k(collection)
 cross join lateral jsonb_array_elements(s.snapshot->k.collection) with ordinality x(v,ord)
), differences as (
 (select * from expected except select scope,account_id,collection,record_id,payload,position from portfleet_v2.records)
 union all
 (select scope,account_id,collection,record_id,payload,position from portfleet_v2.records except select * from expected)
)
select count(*) as mismatched_records_expected_zero from differences;
rollback;

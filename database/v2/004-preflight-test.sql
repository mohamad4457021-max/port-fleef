-- Synthetic diagnostic tests. No real owner or source data needed. Run after 001 and 003.
begin;
do $$
declare s jsonb; broken jsonb; n bigint;
begin
 select jsonb_build_object('version',1)||jsonb_object_agg(k,'[]'::jsonb) into s
 from unnest(array['assets','staff','parts','plans','work','requests','assignments','cranes','fuel','moves','oils','audit']) k;
 if exists(select 1 from portfleet_v2.preflight_snapshot(s)) then raise exception 'EMPTY_FIXTURE_REJECTED';end if;
 broken:=jsonb_set(s,'{assets}','[{"id":"a","code":"CR-١","meter":0,"tank":5},{"id":"a","code":"cr-1","meter":-1,"tank":"NaN"}]'::jsonb);
 if not exists(select 1 from portfleet_v2.preflight_snapshot(broken) where section='assets' and issue='DUPLICATE_ID' and affected_count=1) then raise exception 'DUPLICATE_ID_NOT_FOUND';end if;
 if not exists(select 1 from portfleet_v2.preflight_snapshot(broken) where section='assets' and issue='DUPLICATE_CODE' and affected_count=1) then raise exception 'DUPLICATE_CODE_NOT_FOUND';end if;
 select count(*) into n from portfleet_v2.preflight_snapshot(broken) where section='assets' and issue in ('INVALID_NUMBER:meter','INVALID_NUMBER:tank') and affected_count=1;
 if n<>2 then raise exception 'INVALID_NUMBER_NOT_FOUND';end if;
 broken:=jsonb_set(s,'{plans}','[{"id":"p","asset":"missing","interval":0,"last":0}]'::jsonb);
 if not exists(select 1 from portfleet_v2.preflight_snapshot(broken) where section='plans' and issue='MISSING_REFERENCE:asset' and affected_count=1) then raise exception 'MISSING_REFERENCE_NOT_FOUND';end if;
 if not exists(select 1 from portfleet_v2.preflight_snapshot(broken) where section='plans' and issue='INVALID_NUMBER:interval') then raise exception 'ZERO_INTERVAL_NOT_FOUND';end if;
 broken:=jsonb_set(s,'{staff}','null'::jsonb);
 if not exists(select 1 from portfleet_v2.preflight_snapshot(broken) where section='staff' and issue='INVALID_SECTION') then raise exception 'INVALID_SECTION_NOT_FOUND';end if;
 if not exists(select 1 from portfleet_v2.preflight_snapshot('{}'::jsonb) where section='snapshot' and issue='INVALID_VERSION_OR_SHAPE') then raise exception 'INVALID_VERSION_NOT_FOUND';end if;
 if has_function_privilege('anon','portfleet_v2.preflight(uuid)','EXECUTE') or has_function_privilege('authenticated','portfleet_v2.preflight(uuid)','EXECUTE')
 or has_function_privilege('anon','portfleet_v2.preflight_snapshot(jsonb)','EXECUTE') or has_function_privilege('authenticated','portfleet_v2.preflight_snapshot(jsonb)','EXECUTE') then
 raise exception 'TEST_DIAGNOSTICS_EXPOSED';end if;
 raise notice 'PASS: 9 diagnostic and access scenarios';
end $$;
rollback;

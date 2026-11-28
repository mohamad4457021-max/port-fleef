-- Test migration diagnostics against an existing synthetic fixture in staging only.
begin;
do $$
declare o uuid; n bigint;
begin
 select owner_id into o from public.portfleet_state order by owner_id limit 1;
 if o is null then raise exception 'TEST_FIXTURE_REQUIRED'; end if;
 select count(*) into n from portfleet_v2.preflight(o);
 raise notice 'Diagnostic groups: % (zero means no issues covered by preflight; not full validation)',n;
 if has_function_privilege('anon','portfleet_v2.preflight(uuid)','EXECUTE')
 or has_function_privilege('authenticated','portfleet_v2.preflight(uuid)','EXECUTE') then
 raise exception 'TEST_DIAGNOSTICS_EXPOSED';end if;
end $$;
rollback;

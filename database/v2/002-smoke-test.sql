-- Run only in a test Supabase project after 001-shadow-schema.sql.
-- Requires a copied/test owner snapshot, not real operational data.
-- Everything in this test is rolled back, including the shadow import.
begin;
do $$
declare
  v_owner uuid;
  v_rev bigint;
  v_count bigint;
begin
  select owner_id,revision into v_owner,v_rev
    from public.portfleet_state order by owner_id limit 1;
  if v_owner is null then raise exception 'TEST_FIXTURE_REQUIRED'; end if;
  if exists(select 1 from portfleet_v2.workspace where owner_id=v_owner)
    then raise exception 'USE_FRESH_TEST_WORKSPACE'; end if;
  -- Explicit revision mismatch must not insert anything.
  begin
    perform portfleet_v2.stage_owner(v_owner,v_rev+1);
    raise exception 'TEST_EXPECTED_REVISION_FAILURE';
  exception when serialization_failure then null;
  end;
  if exists(select 1 from portfleet_v2.workspace where owner_id=v_owner)
    then raise exception 'TEST_UNEXPECTED_WRITE'; end if;
  if portfleet_v2.stage_owner(v_owner,v_rev)<>v_rev then
    raise exception 'TEST_WRONG_REVISION';
  end if;
  select count(*) into v_count from portfleet_v2.verify_owner(v_owner)
    where exact_match and source_count=staged_count;
  if v_count<>12 then raise exception 'TEST_RECONCILIATION_FAILED'; end if;
  -- Reimport must never overwrite the staged copy.
  begin
    perform portfleet_v2.stage_owner(v_owner,v_rev);
    raise exception 'TEST_EXPECTED_DUPLICATE_FAILURE';
  exception when raise_exception then
    if sqlerrm<>'ALREADY_STAGED' then raise; end if;
  end;
  if has_schema_privilege('anon','portfleet_v2','USAGE')
    or has_schema_privilege('authenticated','portfleet_v2','USAGE') then
    raise exception 'TEST_SCHEMA_EXPOSED';
  end if;
  if has_function_privilege('anon','portfleet_v2.stage_owner(uuid,bigint)','EXECUTE')
    or has_function_privilege('authenticated','portfleet_v2.stage_owner(uuid,bigint)','EXECUTE') then
    raise exception 'TEST_IMPORT_EXPOSED';
  end if;
  raise notice 'PASS: revision, exact reconciliation (12), duplicate import, schema/function privileges';
end $$;
rollback;

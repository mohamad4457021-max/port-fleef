-- Disposable synthetic database only, after 001 and 005. Rollback everything.
begin;
do $$
declare
 o uuid:='00000000-0000-4000-8000-000000000001';
 op1 uuid:='10000000-0000-4000-8000-000000000001';
 op2 uuid:='10000000-0000-4000-8000-000000000002';
 op3 uuid:='10000000-0000-4000-8000-000000000003';
 rev bigint; n bigint;
begin
 select revision into rev from public.portfleet_state where owner_id=o;
 if rev is null then raise exception 'SYNTHETIC_FIXTURE_REQUIRED';end if;
 perform portfleet_v2.stage_owner(o,rev);
 if portfleet_v2.post_fuel(o,op1,0,'صرف','a','2026-01-02',50,'TEST-1')<>1 then raise exception 'BAD_FIRST_SEQUENCE';end if;
 if portfleet_v2.post_fuel(o,op1,0,'صرف','a','2026-01-02',50,'TEST-1')<>1 then raise exception 'BAD_RETRY';end if;
 begin
  perform portfleet_v2.post_fuel(o,op1,0,'صرف','a','2026-01-02',51,'TEST-1');
  raise exception 'EXPECTED_IDEMPOTENCY_REJECTION';
 exception when invalid_parameter_value then
  if sqlerrm<>'IDEMPOTENCY_CONFLICT' then raise;end if;
 end;
 begin
  perform portfleet_v2.post_fuel(o,op2,0,'صرف','a','2026-01-02',1,'STALE');
  raise exception 'EXPECTED_STALE_REJECTION';
 exception when serialization_failure then null;end;
 begin
  perform portfleet_v2.post_fuel(o,op2,1,'صرف','a','2026-01-02',41,'OVERDRAW');
  raise exception 'EXPECTED_OVERDRAW_REJECTION';
 exception when invalid_parameter_value then
  if sqlerrm<>'INSUFFICIENT_HISTORICAL_FUEL' then raise;end if;
 end;
 begin
  perform portfleet_v2.post_fuel(o,op2,1,'صرف','a','2025-12-31',1,'BACKDATED');
  raise exception 'EXPECTED_BACKDATED_REJECTION';
 exception when invalid_parameter_value then
  if sqlerrm<>'INSUFFICIENT_HISTORICAL_FUEL' then raise;end if;
 end;
 if portfleet_v2.post_fuel(o,op2,1,'استلام',null,'2026-01-02',10,'TEST-2')<>2 then raise exception 'BAD_RECEIPT';end if;
 if portfleet_v2.post_fuel(o,op3,2,'صرف','a','2026-01-02',50,'TEST-3')<>3 then raise exception 'BAD_FINAL_SEQUENCE';end if;
 select count(*) into n from portfleet_v2.fuel_transaction where owner_id=o;
 if n<>3 then raise exception 'RETRY_OR_FAILURE_WROTE_ROW';end if;
 select count(*) into n from portfleet_v2.verify_owner(o) where exact_match;
 if n<>12 then raise exception 'STAGED_BASE_WAS_CHANGED';end if;
 if has_function_privilege('anon','portfleet_v2.post_fuel(uuid,uuid,bigint,text,text,date,numeric,text)','EXECUTE')
 or has_function_privilege('authenticated','portfleet_v2.post_fuel(uuid,uuid,bigint,text,text,date,numeric,text)','EXECUTE') then
  raise exception 'FUEL_PROTOTYPE_EXPOSED';end if;
 raise notice 'PASS: fuel transactions, exact retries, revision conflict, stock checks, base reconciliation, privileges';
end $$;
rollback;

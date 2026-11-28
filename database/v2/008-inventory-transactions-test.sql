-- Disposable synthetic database only. All writes rolled back.
begin;
do $$
declare
 o uuid:='00000000-0000-4000-8000-000000000001';
 op1 uuid:='20000000-0000-4000-8000-000000000001';
 op2 uuid:='20000000-0000-4000-8000-000000000002';
 op3 uuid:='20000000-0000-4000-8000-000000000003';
 rev bigint; n bigint; bal numeric;
begin
 select revision into rev from public.portfleet_state where owner_id=o;
 if rev is null then raise exception 'SYNTHETIC_FIXTURE_REQUIRED';end if;
 perform portfleet_v2.stage_owner(o,rev);
 if portfleet_v2.post_inventory(o,op1,0,'صرف','pt','w-open',5,'TEST-1')<>1 then raise exception 'BAD_SEQUENCE';end if;
 if portfleet_v2.post_inventory(o,op1,0,'صرف','pt','w-open',5,'TEST-1')<>1 then raise exception 'BAD_RETRY';end if;
 begin
  perform portfleet_v2.post_inventory(o,op1,0,'صرف','pt','w-open',4,'TEST-1');
  raise exception 'EXPECTED_REJECTION';
 exception when invalid_parameter_value then if sqlerrm<>'IDEMPOTENCY_CONFLICT' then raise;end if;end;
 begin
  perform portfleet_v2.post_inventory(o,op2,0,'صرف','pt','w-open',1,'STALE');
  raise exception 'EXPECTED_REJECTION';
 exception when serialization_failure then null;end;
 begin
  perform portfleet_v2.post_inventory(o,op2,1,'صرف','pt','w-open',5,'OVERDRAW');
  raise exception 'EXPECTED_REJECTION';
 exception when invalid_parameter_value then if sqlerrm<>'INSUFFICIENT_PART_STOCK' then raise;end if;end;
 begin
  perform portfleet_v2.post_inventory(o,op2,1,'صرف','pt','w',1,'CLOSED');
  raise exception 'EXPECTED_REJECTION';
 exception when invalid_parameter_value then if sqlerrm<>'WORK_ORDER_NOT_APPROVED' then raise;end if;end;
 begin
  perform portfleet_v2.post_inventory(o,op2,1,'صرف','pt','w-other',1,'INCOMPATIBLE');
  raise exception 'EXPECTED_REJECTION';
 exception when invalid_parameter_value then if sqlerrm<>'PART_NOT_COMPATIBLE' then raise;end if;end;
 if portfleet_v2.post_inventory(o,op2,1,'استلام','pt',null,2,'TEST-2')<>2 then raise exception 'BAD_RECEIPT';end if;
 if portfleet_v2.post_inventory(o,op3,2,'صرف','pt','w-open',6,'TEST-3')<>3 then raise exception 'BAD_FINAL_SEQUENCE';end if;
 select count(*) into n from portfleet_v2.inventory_transaction where owner_id=o and unit_cost=4;
 if n<>3 then raise exception 'RETRY_OR_FAILED_OPERATION_WROTE_ROW';end if;
 select balance_after into bal from portfleet_v2.inventory_transaction where owner_id=o and sequence_no=3;
 if bal is distinct from 0::numeric then raise exception 'BAD_FINAL_BALANCE';end if;
 select count(*) into n from portfleet_v2.verify_owner(o) where exact_match;
 if n<>12 then raise exception 'STAGED_BASE_WAS_CHANGED';end if;
 if has_function_privilege('anon','portfleet_v2.post_inventory(uuid,uuid,bigint,text,text,text,numeric,text)','EXECUTE')
 or has_function_privilege('authenticated','portfleet_v2.post_inventory(uuid,uuid,bigint,text,text,text,numeric,text)','EXECUTE') then
 raise exception 'INVENTORY_PROTOTYPE_EXPOSED';end if;
 raise notice 'PASS: inventory posting, exact retry, conflict, stock, work approval, compatibility, cost and isolation';
end $$;
rollback;

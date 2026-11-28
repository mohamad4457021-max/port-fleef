-- CI only, synthetic owner and staff; all data changes rolled back.
begin;
select portfleet_v2.stage_owner('00000000-0000-4000-8000-000000000001',1);
insert into portfleet_v2.api_workspace values ('00000000-0000-4000-8000-000000000001',true);
set local role authenticated;
do $$
declare
 o uuid:='00000000-0000-4000-8000-000000000001';
 u uuid:='00000000-0000-4000-8000-000000000002';
 op1 uuid:='80000000-0000-4000-8000-000000000001';
 op2 uuid:='80000000-0000-4000-8000-000000000002';
 op3 uuid:='80000000-0000-4000-8000-000000000003';
 inv uuid:='80000000-0000-4000-8000-000000000004';
 n bigint;
begin
 perform set_config('request.jwt.claim.sub',u::text,true);
 begin
  perform portfleet_v2_api.advance_maintenance(o,op1,'w-open','معتمد','قيد الإصلاح','CI',null,null);
  raise exception 'EXPECTED_STAFF_DENIAL';
 exception when insufficient_privilege then null;end;
 perform set_config('request.jwt.claim.sub',o::text,true);
 begin
  perform portfleet_v2_api.advance_maintenance(o,op1,'w-open','معتمد','مغلق','CI',null,true);
  raise exception 'EXPECTED_SKIP_DENIAL';
 exception when invalid_parameter_value then null;end;
 if portfleet_v2_api.advance_maintenance(o,op1,'w-open','معتمد','قيد الإصلاح','CI',null,null)<>1 then raise exception 'BAD_FIRST_TRANSITION';end if;
 if portfleet_v2_api.advance_maintenance(o,op1,'w-open','معتمد','قيد الإصلاح','CI',null,null)<>1 then raise exception 'BAD_RETRY';end if;
 begin
  perform portfleet_v2_api.advance_maintenance(o,op1,'w-open','معتمد','قيد الإصلاح','CHANGED',null,null);
  raise exception 'EXPECTED_IDEMPOTENCY_CONFLICT';
 exception when invalid_parameter_value then if sqlerrm<>'IDEMPOTENCY_CONFLICT' then raise;end if;end;
 begin
  perform portfleet_v2_api.advance_maintenance(o,op2,'w-open','معتمد','قيد الإصلاح','STALE',null,null);
  raise exception 'EXPECTED_STALE_CONFLICT';
 exception when serialization_failure then null;end;
 if portfleet_v2_api.post_inventory(o,inv,0,'صرف','pt','w-open',1,'CI')<>1 then raise exception 'REPAIR_STOCK_DENIED';end if;
 begin
  perform portfleet_v2_api.advance_maintenance(o,op2,'w-open','قيد الإصلاح','بانتظار الفحص','CI',-1,null);
  raise exception 'EXPECTED_NEGATIVE_COST_DENIAL';
 exception when invalid_parameter_value then null;end;
 if portfleet_v2_api.advance_maintenance(o,op2,'w-open','قيد الإصلاح','بانتظار الفحص','CI',25,null)<>2 then raise exception 'BAD_INSPECTION_TRANSITION';end if;
 begin
  perform portfleet_v2_api.post_inventory(o,'80000000-0000-4000-8000-000000000005',1,'صرف','pt','w-open',1,'CI');
  raise exception 'EXPECTED_STOCK_DENIAL_AFTER_REPAIR';
 exception when invalid_parameter_value then if sqlerrm<>'WORK_ORDER_NOT_APPROVED' then raise;end if;end;
 begin
  perform portfleet_v2_api.advance_maintenance(o,op3,'w-open','بانتظار الفحص','مغلق','CI',null,false);
  raise exception 'EXPECTED_FAILED_INSPECTION_DENIAL';
 exception when invalid_parameter_value then null;end;
 if portfleet_v2_api.advance_maintenance(o,op3,'w-open','بانتظار الفحص','مغلق','CI',null,true)<>3 then raise exception 'BAD_CLOSURE';end if;
 select count(*) into n from portfleet_v2_api.audit_page(o) a where a->>'action'='maintenance.advance';
 if n<>3 then raise exception 'MAINTENANCE_AUDIT_DUPLICATION';end if;
end $$;
reset role;
do $$
declare o uuid:='00000000-0000-4000-8000-000000000001';
begin
 if portfleet_v2.effective_work_status(o,'w-open') is distinct from 'مغلق' then raise exception 'BAD_PROJECTED_STATUS';end if;
 if (select status from portfleet_v2.work where owner_id=o and record_id='w-open') is distinct from 'معتمد' then raise exception 'BASELINE_CHANGED';end if;
 if (select count(*) from portfleet_v2.verify_owner(o) where exact_match)<>12 then raise exception 'RECONCILIATION_FAILED';end if;
 if has_function_privilege('anon','portfleet_v2_api.advance_maintenance(uuid,uuid,text,text,text,text,numeric,boolean)','EXECUTE') then raise exception 'ANONYMOUS_EXECUTE';end if;
 raise notice 'PASS: maintenance sequencing, stale/conflicting retries, inspection, costs, inventory integration, actor audit and baseline preservation';
end $$;
rollback;

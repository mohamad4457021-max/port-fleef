-- CI ONLY: exercise SQL roles with synthetic identity claims; rollback all test data.
begin;
insert into public.portfleet_owner values ('00000000-0000-4000-8000-000000000005');
insert into public.portfleet_state
select '00000000-0000-4000-8000-000000000005'::uuid,revision,snapshot
from public.portfleet_state where owner_id='00000000-0000-4000-8000-000000000001';
select portfleet_v2.stage_owner('00000000-0000-4000-8000-000000000001',1);
select portfleet_v2.stage_owner('00000000-0000-4000-8000-000000000005',1);
insert into portfleet_v2.api_workspace values
 ('00000000-0000-4000-8000-000000000001',true),
 ('00000000-0000-4000-8000-000000000005',true);

set local role authenticated;
do $$
declare
 o uuid:='00000000-0000-4000-8000-000000000001';
 staff uuid:='00000000-0000-4000-8000-000000000002';
 outsider uuid:='00000000-0000-4000-8000-000000000003';
 unconfirmed uuid:='00000000-0000-4000-8000-000000000004';
 other_owner uuid:='00000000-0000-4000-8000-000000000005';
 op uuid:='50000000-0000-4000-8000-000000000001';
 inv uuid:='50000000-0000-4000-8000-000000000002';
 n bigint; page_id bigint; actor uuid;
begin
 perform set_config('request.jwt.claim.sub',staff::text,true);
 begin
  perform portfleet_v2_api.post_fuel(o,op,0,'صرف','a','2026-01-02',10,'CI');
  raise exception 'EXPECTED_DENIAL';
 exception when insufficient_privilege then null;end;
 perform set_config('request.jwt.claim.sub',o::text,true);
 if not portfleet_v2_api.set_access(o,staff,'fuel.post',true) then raise exception 'GRANT_FAILED';end if;
 if portfleet_v2_api.set_access(o,staff,'fuel.post',true) then raise exception 'DUPLICATE_GRANT';end if;
 begin
  perform portfleet_v2_api.set_access(o,unconfirmed,'fuel.post',true);
  raise exception 'EXPECTED_UNCONFIRMED_REJECTION';
 exception when invalid_parameter_value then null;end;
 perform set_config('request.jwt.claim.sub',staff::text,true);
 if portfleet_v2_api.post_fuel(o,op,0,'صرف','a','2026-01-02',10,'CI')<>1 then raise exception 'STAFF_POST_FAILED';end if;
 if portfleet_v2_api.post_fuel(o,op,0,'صرف','a','2026-01-02',10,'CI')<>1 then raise exception 'STAFF_RETRY_FAILED';end if;
 begin
  perform portfleet_v2_api.post_inventory(o,inv,0,'صرف','pt','w-open',1,'CI');
  raise exception 'EXPECTED_INVENTORY_DENIAL';
 exception when insufficient_privilege then null;end;
 begin
  perform portfleet_v2_api.set_access(o,staff,'inventory.post',true);
  raise exception 'EXPECTED_ESCALATION_DENIAL';
 exception when insufficient_privilege then null;end;
 begin
  perform portfleet_v2_api.audit_page(o);
  raise exception 'EXPECTED_AUDIT_DENIAL';
 exception when insufficient_privilege then null;end;
 begin
  perform portfleet_v2_api.post_fuel(other_owner,op,0,'صرف','a','2026-01-02',10,'CI');
  raise exception 'EXPECTED_CROSS_WORKSPACE_DENIAL';
 exception when insufficient_privilege then null;end;
 perform set_config('request.jwt.claim.sub',outsider::text,true);
 begin
  perform portfleet_v2_api.post_fuel(o,op,0,'صرف','a','2026-01-02',10,'CI');
  raise exception 'EXPECTED_OUTSIDER_DENIAL';
 exception when insufficient_privilege then null;end;
 perform set_config('request.jwt.claim.sub',o::text,true);
 begin
  perform portfleet_v2_api.post_fuel(o,op,0,'صرف','a','2026-01-02',10,'CI');
  raise exception 'EXPECTED_ACTOR_CONFLICT';
 exception when insufficient_privilege then
  if sqlerrm<>'OPERATION_ACTOR_CONFLICT' then raise;end if;
 end;
 if not portfleet_v2_api.set_access(o,staff,'fuel.post',false) then raise exception 'REVOKE_FAILED';end if;
 if not portfleet_v2_api.set_access(o,staff,'inventory.post',true) then raise exception 'INVENTORY_GRANT_FAILED';end if;
 perform set_config('request.jwt.claim.sub',staff::text,true);
 begin
  perform portfleet_v2_api.post_fuel(o,op,0,'صرف','a','2026-01-02',10,'CI');
  raise exception 'EXPECTED_REVOKED_DENIAL';
 exception when insufficient_privilege then null;end;
 if portfleet_v2_api.post_inventory(o,inv,0,'صرف','pt','w-open',1,'CI')<>1 then raise exception 'INVENTORY_POST_FAILED';end if;
 perform set_config('request.jwt.claim.sub',o::text,true);
 select count(*) into n from portfleet_v2_api.audit_page(o);
 if n<>5 then raise exception 'WRONG_AUDIT_COUNT: %',n;end if;
 select (a->>'actor_id')::uuid into actor from portfleet_v2_api.audit_page(o) a where a->>'action'='fuel.post';
 if actor is distinct from staff then raise exception 'AUDIT_ACTOR_MISMATCH';end if;
 select (a->>'event_id')::bigint into page_id from portfleet_v2_api.audit_page(o,null,1) a;
 select count(*) into n from portfleet_v2_api.audit_page(o,page_id,100);
 if n<>4 then raise exception 'AUDIT_PAGINATION_FAILED';end if;
 begin
  perform count(*) from portfleet_v2.server_audit;
  raise exception 'EXPECTED_DIRECT_TABLE_DENIAL';
 exception when insufficient_privilege then null;end;
 perform set_config('request.jwt.claim.sub',other_owner::text,true);
 select count(*) into n from portfleet_v2_api.audit_page(other_owner);
 if n<>0 then raise exception 'AUDIT_WORKSPACE_LEAK';end if;
 begin
  perform portfleet_v2_api.audit_page(o);
  raise exception 'EXPECTED_CROSS_OWNER_AUDIT_DENIAL';
 exception when insufficient_privilege then null;end;
end $$;
reset role;
do $$
begin
 if (select count(*) from portfleet_v2.fuel_transaction)<>1 or (select count(*) from portfleet_v2.inventory_transaction)<>1 then
 raise exception 'UNEXPECTED_TRANSACTION_COUNT';end if;
 begin
  update portfleet_v2.server_audit set detail='{}'::jsonb;
  raise exception 'EXPECTED_AUDIT_IMMUTABILITY';
 exception when insufficient_privilege then
  if sqlerrm<>'AUDIT_APPEND_ONLY' then raise;end if;
 end;
 if has_schema_privilege('anon','portfleet_v2_api','USAGE') or has_schema_privilege('authenticated','portfleet_v2','USAGE') then
 raise exception 'SCHEMA_EXPOSED';end if;
 raise notice 'PASS: scoped role access, revocation, cross-owner isolation, actor-bound retries, server audit and pagination';
end $$;
rollback;

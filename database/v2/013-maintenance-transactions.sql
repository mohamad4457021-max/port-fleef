-- 013: maintenance progression prototype, staged workspace only.
-- Existing work/asset/plan records are untouched. Effective status is a projection.
-- Closing a work order here DOES NOT release an asset into service or update its plan.
begin;
alter table portfleet_v2.server_audit drop constraint server_audit_action_check;
alter table portfleet_v2.server_audit add constraint server_audit_action_check
 check(action in ('fuel.post','inventory.post','access.set','maintenance.advance'));
create table portfleet_v2.maintenance_transition (
 owner_id uuid not null references portfleet_v2.api_workspace(owner_id),
 operation_id uuid not null,
 sequence_no bigint not null check(sequence_no>0),
 work_id text not null,
 previous_status text not null,
 next_status text not null,
 note text not null check(btrim(note)<>'' and char_length(note)<=1000),
 labor_cost numeric check(labor_cost>=0 and labor_cost::text not in ('NaN','Infinity','-Infinity')),
 inspection_passed boolean,
 actor_id uuid not null,
 occurred_at timestamptz not null default clock_timestamp(),
 primary key(owner_id,operation_id),
 unique(owner_id,sequence_no),
 foreign key(owner_id,work_id) references portfleet_v2.work(owner_id,record_id),
 check ((previous_status='بلاغ' and next_status='تشخيص')
 or (previous_status='تشخيص' and next_status='معتمد')
 or (previous_status='معتمد' and next_status='قيد الإصلاح')
 or (previous_status='قيد الإصلاح' and next_status='بانتظار الفحص')
 or (previous_status='بانتظار الفحص' and next_status='مغلق')),
 check ((next_status='بانتظار الفحص' and labor_cost is not null)
 or (next_status<>'بانتظار الفحص' and labor_cost is null)),
 check ((next_status='مغلق' and inspection_passed is true)
 or (next_status<>'مغلق' and inspection_passed is null))
);
alter table portfleet_v2.maintenance_transition enable row level security;
revoke all on portfleet_v2.maintenance_transition from public,anon,authenticated;
create index maintenance_work_sequence_idx on portfleet_v2.maintenance_transition(owner_id,work_id,sequence_no desc);
create trigger maintenance_no_mutation before update or delete or truncate on portfleet_v2.maintenance_transition
 for each statement execute function portfleet_v2.reject_audit_mutation();
create function portfleet_v2.effective_work_status(p_owner uuid,p_work text)
returns text language sql stable security invoker set search_path='' as $$
 select coalesce(
 (select next_status from portfleet_v2.maintenance_transition where owner_id=p_owner and work_id=p_work order by sequence_no desc limit 1),
 (select status from portfleet_v2.work where owner_id=p_owner and record_id=p_work))
$$;
revoke all on function portfleet_v2.effective_work_status(uuid,text) from public,anon,authenticated;

-- Owner-only API for the prototype. Delegated maintenance roles not enabled.
create function portfleet_v2_api.advance_maintenance(p_owner uuid,p_operation uuid,p_work text,p_expected text,p_next text,p_note text,p_cost numeric,p_passed boolean)
returns bigint language plpgsql security definer set search_path='' as $$
declare v_actor uuid; v_source bigint; v_stage bigint; v_status text; v_seq bigint;
 v_old portfleet_v2.maintenance_transition%rowtype;
begin
 v_actor:=portfleet_v2.require_actor(p_owner,'owner');
 if p_operation is null or p_work is null or btrim(p_work)='' or p_expected is null or p_next is null
 or p_note is null or btrim(p_note)='' or char_length(p_note)>1000
 or (p_next='بانتظار الفحص' and (p_cost is null or p_cost<0 or p_cost::text in ('NaN','Infinity','-Infinity')))
 or (p_next<>'بانتظار الفحص' and p_cost is not null)
 or (p_next='مغلق' and p_passed is distinct from true)
 or (p_next<>'مغلق' and p_passed is not null)
 then raise exception 'INVALID_MAINTENANCE_TRANSITION' using errcode='22023';end if;
 select revision into v_source from public.portfleet_state where owner_id=p_owner for share;
 select source_revision into v_stage from portfleet_v2.workspace where owner_id=p_owner for update;
 if v_source is null or v_stage is null or v_source<>v_stage then raise exception 'STALE_OR_MISSING_STAGE' using errcode='40001';end if;
 select * into v_old from portfleet_v2.maintenance_transition where owner_id=p_owner and operation_id=p_operation;
 if found then
  if v_old.actor_id is distinct from v_actor or v_old.work_id is distinct from p_work
  or v_old.previous_status is distinct from p_expected or v_old.next_status is distinct from p_next
  or v_old.note is distinct from p_note or v_old.labor_cost is distinct from p_cost
  or v_old.inspection_passed is distinct from p_passed then
   raise exception 'IDEMPOTENCY_CONFLICT' using errcode='22023';end if;
  return v_old.sequence_no;
 end if;
 v_status:=portfleet_v2.effective_work_status(p_owner,p_work);
 if v_status is null then raise exception 'WORK_ORDER_NOT_FOUND' using errcode='22023';end if;
 if v_status<>p_expected then raise exception 'WORK_STATUS_CONFLICT' using errcode='40001';end if;
 if not ((v_status='بلاغ' and p_next='تشخيص') or (v_status='تشخيص' and p_next='معتمد')
 or (v_status='معتمد' and p_next='قيد الإصلاح') or (v_status='قيد الإصلاح' and p_next='بانتظار الفحص')
 or (v_status='بانتظار الفحص' and p_next='مغلق')) then
  raise exception 'INVALID_WORK_STATUS_SEQUENCE' using errcode='22023';end if;
 select coalesce(max(sequence_no),0)+1 into v_seq from portfleet_v2.maintenance_transition where owner_id=p_owner;
 insert into portfleet_v2.maintenance_transition(owner_id,operation_id,sequence_no,work_id,previous_status,next_status,note,labor_cost,inspection_passed,actor_id)
 values(p_owner,p_operation,v_seq,p_work,p_expected,p_next,p_note,p_cost,p_passed,v_actor);
 insert into portfleet_v2.server_audit(owner_id,actor_id,action,operation_id,sequence_no,detail)
 values(p_owner,v_actor,'maintenance.advance',p_operation,v_seq,jsonb_build_object('work',p_work,'previous',p_expected,'next',p_next,'note',p_note,'cost',p_cost,'inspection_passed',p_passed));
 return v_seq;
end; $$;
revoke all on function portfleet_v2_api.advance_maintenance(uuid,uuid,text,text,text,text,numeric,boolean) from public,anon,authenticated;
grant execute on function portfleet_v2_api.advance_maintenance(uuid,uuid,text,text,text,text,numeric,boolean) to authenticated;

-- Update inventory's authorization check to use the projected maintenance state.
-- Existing inventory semantics and permissions remain unchanged.
create or replace function portfleet_v2.post_inventory(p_owner uuid,p_operation uuid,p_expected bigint,p_kind text,p_part text,p_work text,p_qty numeric,p_reference text)
returns bigint language plpgsql security invoker set search_path='' as $$
declare
 v_source bigint; v_stage bigint; v_last bigint; v_opening numeric; v_cost numeric;
 v_compat text; v_asset_type text; v_work_status text; v_balance numeric;
 v_existing portfleet_v2.inventory_transaction%rowtype;
begin
 if p_operation is null or p_expected is null or p_expected<0
 or p_kind is null or p_kind not in ('استلام','صرف')
 or p_part is null or btrim(p_part)=''
 or p_qty is null or p_qty::text in ('NaN','Infinity','-Infinity') or p_qty<=0
 or p_qty>=100000000000000 or p_qty<>round(p_qty,6)
 or p_reference is null or btrim(p_reference)='' or char_length(p_reference)>200
 or (p_kind='صرف' and (p_work is null or btrim(p_work)=''))
 or (p_kind='استلام' and p_work is not null)
 then raise exception 'INVALID_INVENTORY_TRANSACTION' using errcode='22023';end if;
 -- Same order as fuel engine. Reject stage if V1 source changed.
 select revision into v_source from public.portfleet_state where owner_id=p_owner for share;
 select source_revision into v_stage from portfleet_v2.workspace where owner_id=p_owner for update;
 if v_source is null or v_stage is null or v_source<>v_stage then
 raise exception 'STALE_OR_MISSING_STAGE' using errcode='40001';end if;
 select * into v_existing from portfleet_v2.inventory_transaction where owner_id=p_owner and operation_id=p_operation;
 if found then
  if v_existing.kind is distinct from p_kind or v_existing.part_id is distinct from p_part
  or v_existing.work_id is distinct from p_work or v_existing.qty is distinct from p_qty
  or v_existing.document_ref is distinct from p_reference then
   raise exception 'IDEMPOTENCY_CONFLICT' using errcode='22023';end if;
  return v_existing.sequence_no;
 end if;
 select coalesce(max(sequence_no),0) into v_last from portfleet_v2.inventory_transaction where owner_id=p_owner;
 if v_last<>p_expected then raise exception 'TRANSACTION_REVISION_CONFLICT' using errcode='40001';end if;
 select qty,unit_cost,payload->>'compat' into v_opening,v_cost,v_compat
 from portfleet_v2.parts where owner_id=p_owner and record_id=p_part;
 if not found then raise exception 'PART_NOT_FOUND' using errcode='22023';end if;
 if v_opening::text in ('NaN','Infinity','-Infinity') or v_cost::text in ('NaN','Infinity','-Infinity') then
  raise exception 'INVALID_STAGED_PART' using errcode='22023';end if;
 if p_kind='صرف' then
  select portfleet_v2.effective_work_status(p_owner,p_work),a.kind into v_work_status,v_asset_type
  from portfleet_v2.work w join portfleet_v2.assets a on a.owner_id=w.owner_id and a.record_id=w.asset_id
  where w.owner_id=p_owner and w.record_id=p_work;
  if not found or v_work_status not in ('معتمد','قيد الإصلاح') then
   raise exception 'WORK_ORDER_NOT_APPROVED' using errcode='22023';end if;
  if v_compat is distinct from v_asset_type then
   raise exception 'PART_NOT_COMPATIBLE' using errcode='22023';end if;
 end if;
 select v_opening+coalesce(sum(case when kind='استلام' then qty else -qty end),0)
 into v_balance from portfleet_v2.inventory_transaction where owner_id=p_owner and part_id=p_part;
 v_balance:=v_balance+case when p_kind='استلام' then p_qty else -p_qty end;
 if v_balance<0 then raise exception 'INSUFFICIENT_PART_STOCK' using errcode='22023';end if;
 insert into portfleet_v2.inventory_transaction(owner_id,operation_id,sequence_no,part_id,work_id,kind,qty,unit_cost,balance_after,document_ref)
 values(p_owner,p_operation,v_last+1,p_part,p_work,p_kind,p_qty,v_cost,v_balance,p_reference);
 return v_last+1;
end; $$;
revoke all on function portfleet_v2.post_inventory(uuid,uuid,bigint,text,text,text,numeric,text) from public,anon,authenticated;
commit;

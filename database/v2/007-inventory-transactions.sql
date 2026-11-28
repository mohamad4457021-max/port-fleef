-- V2 private inventory transaction prototype. Run after 001 in test database.
-- Staged qty is the opening balance; staged historical moves are NOT counted twice.
-- No edits to V1 or the staged baseline. No public RPC or staff grants.
begin;
create table portfleet_v2.inventory_transaction (
 owner_id uuid not null references portfleet_v2.workspace(owner_id),
 operation_id uuid not null,
 sequence_no bigint not null check(sequence_no>0),
 part_id text not null,
 work_id text,
 kind text not null check(kind in ('استلام','صرف')),
 qty numeric(20,6) not null check(qty>0),
 unit_cost numeric not null check(unit_cost>=0 and unit_cost::text not in ('NaN','Infinity','-Infinity')),
 balance_after numeric not null check(balance_after>=0 and balance_after::text not in ('NaN','Infinity','-Infinity')),
 document_ref text not null check(btrim(document_ref)<>'' and char_length(document_ref)<=200),
 recorded_at timestamptz not null default clock_timestamp(),
 db_actor text not null default session_user,
 primary key(owner_id,operation_id),
 unique(owner_id,sequence_no),
 foreign key(owner_id,part_id) references portfleet_v2.parts(owner_id,record_id),
 foreign key(owner_id,work_id) references portfleet_v2.work(owner_id,record_id),
 check ((kind='صرف' and work_id is not null) or (kind='استلام' and work_id is null))
);
alter table portfleet_v2.inventory_transaction enable row level security;
revoke all on table portfleet_v2.inventory_transaction from public, anon, authenticated;
create index inventory_transaction_part_idx on portfleet_v2.inventory_transaction(owner_id,part_id,sequence_no);
create index inventory_transaction_work_idx on portfleet_v2.inventory_transaction(owner_id,work_id);

create function portfleet_v2.post_inventory(p_owner uuid,p_operation uuid,p_expected bigint,p_kind text,p_part text,p_work text,p_qty numeric,p_reference text)
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
  select w.status,a.kind into v_work_status,v_asset_type
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
revoke all on function portfleet_v2.post_inventory(uuid,uuid,bigint,text,text,text,numeric,text) from public, anon, authenticated;
commit;

-- V2 private transaction prototype: append-only fuel ledger overlay.
-- Not connected to the live application. Never changes legacy or staged source rows.
-- Only DBA/test runner can execute; a future authenticated API must authorize actors.
begin;
create table portfleet_v2.fuel_transaction (
 owner_id uuid not null references portfleet_v2.workspace(owner_id),
 operation_id uuid not null,
 sequence_no bigint not null check(sequence_no>0),
 kind text not null check(kind in ('استلام','صرف')),
 asset_id text,
 movement_date date not null,
 qty numeric(20,6) not null check(qty>0),
 document_ref text not null check(btrim(document_ref)<>'' and char_length(document_ref)<=200),
 recorded_at timestamptz not null default clock_timestamp(),
 db_actor text not null default session_user,
 primary key(owner_id,operation_id),
 unique(owner_id,sequence_no),
 foreign key(owner_id,asset_id) references portfleet_v2.assets(owner_id,record_id),
 check ((kind='صرف' and asset_id is not null) or (kind='استلام' and asset_id is null))
);
alter table portfleet_v2.fuel_transaction enable row level security;
revoke all on table portfleet_v2.fuel_transaction from public, anon, authenticated;
create index fuel_transaction_date_idx on portfleet_v2.fuel_transaction(owner_id,movement_date);

create function portfleet_v2.post_fuel(p_owner uuid,p_operation uuid,p_expected bigint,p_kind text,p_asset text,p_date date,p_qty numeric,p_reference text)
returns bigint language plpgsql security invoker set search_path='' as $$
declare
 v_source bigint; v_stage bigint; v_last bigint; v_tank numeric;
 v_existing portfleet_v2.fuel_transaction%rowtype;
begin
 if p_operation is null or p_expected is null or p_expected<0
  or p_kind is null or p_kind not in ('استلام','صرف')
  or p_date is null or not isfinite(p_date) or p_date>(now() at time zone 'Asia/Damascus')::date
  or p_qty is null or p_qty::text in ('NaN','Infinity','-Infinity') or p_qty<=0
  or p_qty>=100000000000000 or p_qty<>round(p_qty,6)
  or p_reference is null or btrim(p_reference)='' or char_length(p_reference)>200
  or (p_kind='صرف' and (p_asset is null or btrim(p_asset)=''))
  or (p_kind='استلام' and p_asset is not null)
 then raise exception 'INVALID_FUEL_TRANSACTION' using errcode='22023';end if;
 -- Always lock in the same order: source revision then workspace.
 -- Workspace lock serializes all writes for this prototype owner.
 select revision into v_source from public.portfleet_state where owner_id=p_owner for share;
 select source_revision into v_stage from portfleet_v2.workspace where owner_id=p_owner for update;
 if v_source is null or v_stage is null or v_source<>v_stage then
  raise exception 'STALE_OR_MISSING_STAGE' using errcode='40001';end if;
 -- Exact retry returns previous receipt; changed payload with same UUID is rejected.
 select * into v_existing from portfleet_v2.fuel_transaction where owner_id=p_owner and operation_id=p_operation;
 if found then
  if v_existing.kind is distinct from p_kind or v_existing.asset_id is distinct from p_asset
   or v_existing.movement_date is distinct from p_date or v_existing.qty is distinct from p_qty
   or v_existing.document_ref is distinct from p_reference then
   raise exception 'IDEMPOTENCY_CONFLICT' using errcode='22023';end if;
  return v_existing.sequence_no;
 end if;
 select coalesce(max(sequence_no),0) into v_last from portfleet_v2.fuel_transaction where owner_id=p_owner;
 if v_last<>p_expected then raise exception 'TRANSACTION_REVISION_CONFLICT' using errcode='40001';end if;
 if p_kind='صرف' then
  select tank into v_tank from portfleet_v2.assets where owner_id=p_owner and record_id=p_asset;
  if not found then raise exception 'ASSET_NOT_FOUND' using errcode='22023';end if;
  if v_tank>0 and p_qty>v_tank then raise exception 'TANK_CAPACITY_EXCEEDED' using errcode='22023';end if;
 end if;
 -- Check each end-of-day cumulative balance including the proposed operation.
 -- The same date can contain multiple receipts/issues; no intra-day order is claimed.
 if exists(
  with ledger as (
   select movement_date d,case when kind='استلام' then qty else -qty end q from portfleet_v2.fuel where owner_id=p_owner
   union all
   select movement_date,case when kind='استلام' then qty else -qty end from portfleet_v2.fuel_transaction where owner_id=p_owner
   union all
   select p_date,case when p_kind='استلام' then p_qty else -p_qty end
  ), daily as (select d,sum(q) q from ledger group by d),
  running as (select sum(q) over(order by d) balance from daily)
  select 1 from running where balance< -0.00000001
 ) then raise exception 'INSUFFICIENT_HISTORICAL_FUEL' using errcode='22023';end if;
 insert into portfleet_v2.fuel_transaction(owner_id,operation_id,sequence_no,kind,asset_id,movement_date,qty,document_ref)
 values(p_owner,p_operation,v_last+1,p_kind,p_asset,p_date,p_qty,p_reference);
 return v_last+1;
end; $$;
revoke all on function portfleet_v2.post_fuel(uuid,uuid,bigint,text,text,date,numeric,text) from public, anon, authenticated;
commit;

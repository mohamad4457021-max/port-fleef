-- V2 shadow relational foundation. DBA-only, staging database first.
-- Existing v1 snapshots, RPCs and web app remain unchanged. Do not expose this schema.
begin;
create schema portfleet_v2;
revoke all on schema portfleet_v2 from public, anon, authenticated;
create table portfleet_v2.workspace (
 owner_id uuid primary key references public.portfleet_owner(user_id),
 source_revision bigint not null check(source_revision>0),
 staged_at timestamptz not null default now()
);
alter table portfleet_v2.workspace enable row level security;
revoke all on table portfleet_v2.workspace from public, anon, authenticated;

create table portfleet_v2.assets (
  owner_id uuid not null references portfleet_v2.workspace(owner_id),
  record_id text not null check (btrim(record_id)<>''),
  source_position bigint not null check (source_position>0),
  payload jsonb not null check (jsonb_typeof(payload)='object' and payload->>'id'=record_id),
  code text not null check (btrim(code)<>''),
  kind text not null check (kind in ('رافعة','آلية ثقيلة','سيارة خدمة','سيارة مخصصة')),
  meter numeric not null check (meter>=0),
  tank numeric not null check (tank>=0),
  status text not null check (status in ('جاهزة','قيد التشغيل','صيانة','متوقفة')),
  safe text not null check (safe in ('نعم','لا')),
  check (status not in ('صيانة','متوقفة') or safe='لا'),
  primary key(owner_id,record_id),
  unique(owner_id,source_position)
);
alter table portfleet_v2.assets enable row level security;
revoke all on table portfleet_v2.assets from public, anon, authenticated;

create table portfleet_v2.staff (
  owner_id uuid not null references portfleet_v2.workspace(owner_id),
  record_id text not null check (btrim(record_id)<>''),
  source_position bigint not null check (source_position>0),
  payload jsonb not null check (jsonb_typeof(payload)='object' and payload->>'id'=record_id),
  code text not null check (btrim(code)<>''),
  name text not null check (btrim(name)<>''),
  expiry date,
  primary key(owner_id,record_id),
  unique(owner_id,source_position)
);
alter table portfleet_v2.staff enable row level security;
revoke all on table portfleet_v2.staff from public, anon, authenticated;

create table portfleet_v2.parts (
  owner_id uuid not null references portfleet_v2.workspace(owner_id),
  record_id text not null check (btrim(record_id)<>''),
  source_position bigint not null check (source_position>0),
  payload jsonb not null check (jsonb_typeof(payload)='object' and payload->>'id'=record_id),
  code text not null check (btrim(code)<>''),
  name text not null check (btrim(name)<>''),
  qty numeric not null check (qty>=0),
  min_qty numeric not null check (min_qty>=0),
  unit_cost numeric not null check (unit_cost>=0),
  primary key(owner_id,record_id),
  unique(owner_id,source_position)
);
alter table portfleet_v2.parts enable row level security;
revoke all on table portfleet_v2.parts from public, anon, authenticated;

create table portfleet_v2.plans (
  owner_id uuid not null references portfleet_v2.workspace(owner_id),
  record_id text not null check (btrim(record_id)<>''),
  source_position bigint not null check (source_position>0),
  payload jsonb not null check (jsonb_typeof(payload)='object' and payload->>'id'=record_id),
  asset_id text not null,
  interval_units numeric not null check (interval_units>0),
  last_meter numeric not null check (last_meter>=0),
  due_date date,
  foreign key (owner_id,asset_id) references portfleet_v2.assets(owner_id,record_id),
  primary key(owner_id,record_id),
  unique(owner_id,source_position)
);
alter table portfleet_v2.plans enable row level security;
revoke all on table portfleet_v2.plans from public, anon, authenticated;

create table portfleet_v2.work (
  owner_id uuid not null references portfleet_v2.workspace(owner_id),
  record_id text not null check (btrim(record_id)<>''),
  source_position bigint not null check (source_position>0),
  payload jsonb not null check (jsonb_typeof(payload)='object' and payload->>'id'=record_id),
  asset_id text not null,
  plan_id text,
  work_date date not null,
  status text not null check (status in ('بلاغ','تشخيص','معتمد','قيد الإصلاح','بانتظار الفحص','مغلق')),
  cost numeric not null check (cost>=0),
  foreign key (owner_id,asset_id) references portfleet_v2.assets(owner_id,record_id),
  foreign key (owner_id,plan_id) references portfleet_v2.plans(owner_id,record_id),
  primary key(owner_id,record_id),
  unique(owner_id,source_position)
);
alter table portfleet_v2.work enable row level security;
revoke all on table portfleet_v2.work from public, anon, authenticated;

create table portfleet_v2.requests (
  owner_id uuid not null references portfleet_v2.workspace(owner_id),
  record_id text not null check (btrim(record_id)<>''),
  source_position bigint not null check (source_position>0),
  payload jsonb not null check (jsonb_typeof(payload)='object' and payload->>'id'=record_id),
  asset_id text,
  driver_id text,
  status text not null check (status in ('معلق','معتمد','منطلق','مغلق','مرفوض')),
  start_at timestamp not null,
  end_at timestamp not null,
  check (end_at>start_at),
  foreign key (owner_id,asset_id) references portfleet_v2.assets(owner_id,record_id),
  foreign key (owner_id,driver_id) references portfleet_v2.staff(owner_id,record_id),
  primary key(owner_id,record_id),
  unique(owner_id,source_position)
);
alter table portfleet_v2.requests enable row level security;
revoke all on table portfleet_v2.requests from public, anon, authenticated;

create table portfleet_v2.assignments (
  owner_id uuid not null references portfleet_v2.workspace(owner_id),
  record_id text not null check (btrim(record_id)<>''),
  source_position bigint not null check (source_position>0),
  payload jsonb not null check (jsonb_typeof(payload)='object' and payload->>'id'=record_id),
  asset_id text not null,
  assigned_on date not null,
  returned_on date,
  quota numeric not null check (quota>=0),
  check (returned_on is null or returned_on>=assigned_on),
  foreign key (owner_id,asset_id) references portfleet_v2.assets(owner_id,record_id),
  primary key(owner_id,record_id),
  unique(owner_id,source_position)
);
alter table portfleet_v2.assignments enable row level security;
revoke all on table portfleet_v2.assignments from public, anon, authenticated;

create table portfleet_v2.cranes (
  owner_id uuid not null references portfleet_v2.workspace(owner_id),
  record_id text not null check (btrim(record_id)<>''),
  source_position bigint not null check (source_position>0),
  payload jsonb not null check (jsonb_typeof(payload)='object' and payload->>'id'=record_id),
  asset_id text not null,
  operator_id text not null,
  shift_date date not null,
  shift text not null,
  work_hours numeric not null check (work_hours>=0),
  wait_hours numeric not null check (wait_hours>=0),
  down_hours numeric not null check (down_hours>=0),
  tonnes numeric not null check (tonnes>=0),
  fuel_litres numeric not null check (fuel_litres>=0),
  foreign key (owner_id,asset_id) references portfleet_v2.assets(owner_id,record_id),
  foreign key (owner_id,operator_id) references portfleet_v2.staff(owner_id,record_id),
  primary key(owner_id,record_id),
  unique(owner_id,source_position)
);
alter table portfleet_v2.cranes enable row level security;
revoke all on table portfleet_v2.cranes from public, anon, authenticated;

create table portfleet_v2.fuel (
  owner_id uuid not null references portfleet_v2.workspace(owner_id),
  record_id text not null check (btrim(record_id)<>''),
  source_position bigint not null check (source_position>0),
  payload jsonb not null check (jsonb_typeof(payload)='object' and payload->>'id'=record_id),
  asset_id text,
  movement_date date not null,
  kind text not null check (kind in ('استلام','صرف')),
  qty numeric not null check (qty>0),
  meter numeric not null check (meter>=0),
  check ((kind='صرف' and asset_id is not null) or (kind='استلام' and asset_id is null)),
  foreign key (owner_id,asset_id) references portfleet_v2.assets(owner_id,record_id),
  primary key(owner_id,record_id),
  unique(owner_id,source_position)
);
alter table portfleet_v2.fuel enable row level security;
revoke all on table portfleet_v2.fuel from public, anon, authenticated;

create table portfleet_v2.moves (
  owner_id uuid not null references portfleet_v2.workspace(owner_id),
  record_id text not null check (btrim(record_id)<>''),
  source_position bigint not null check (source_position>0),
  payload jsonb not null check (jsonb_typeof(payload)='object' and payload->>'id'=record_id),
  part_id text not null,
  work_id text,
  movement_date date not null,
  kind text not null check (kind in ('استلام','صرف')),
  qty numeric not null check (qty>0),
  unit_cost numeric not null check (unit_cost>=0),
  check ((kind='صرف' and work_id is not null) or (kind='استلام' and work_id is null)),
  foreign key (owner_id,part_id) references portfleet_v2.parts(owner_id,record_id),
  foreign key (owner_id,work_id) references portfleet_v2.work(owner_id,record_id),
  primary key(owner_id,record_id),
  unique(owner_id,source_position)
);
alter table portfleet_v2.moves enable row level security;
revoke all on table portfleet_v2.moves from public, anon, authenticated;

create table portfleet_v2.oils (
  owner_id uuid not null references portfleet_v2.workspace(owner_id),
  record_id text not null check (btrim(record_id)<>''),
  source_position bigint not null check (source_position>0),
  payload jsonb not null check (jsonb_typeof(payload)='object' and payload->>'id'=record_id),
  asset_id text not null,
  oil_type text not null,
  changed_on date not null,
  meter numeric not null check (meter>=0),
  qty numeric not null check (qty>0),
  interval_units numeric not null check (interval_units>0),
  cost numeric not null check (cost>=0),
  foreign key (owner_id,asset_id) references portfleet_v2.assets(owner_id,record_id),
  primary key(owner_id,record_id),
  unique(owner_id,source_position)
);
alter table portfleet_v2.oils enable row level security;
revoke all on table portfleet_v2.oils from public, anon, authenticated;

create table portfleet_v2.audit (
  owner_id uuid not null references portfleet_v2.workspace(owner_id),
  record_id text not null check (btrim(record_id)<>''),
  source_position bigint not null check (source_position>0),
  payload jsonb not null check (jsonb_typeof(payload)='object' and payload->>'id'=record_id),
  occurred_at timestamptz not null,
  primary key(owner_id,record_id),
  unique(owner_id,source_position)
);
alter table portfleet_v2.audit enable row level security;
revoke all on table portfleet_v2.audit from public, anon, authenticated;

-- Indexed lookup and range queries. Unique codes normalize Arabic/Persian digits,
-- case and whitespace. Unicode NFKC equivalence still needs application parity.
create unique index assets_code_uq on portfleet_v2.assets(owner_id,lower(regexp_replace(btrim(translate(code,'٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹','01234567890123456789')),'[[:space:]]+',' ','g')));
create unique index staff_code_uq on portfleet_v2.staff(owner_id,lower(regexp_replace(btrim(translate(code,'٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹','01234567890123456789')),'[[:space:]]+',' ','g')));
create unique index parts_code_uq on portfleet_v2.parts(owner_id,lower(regexp_replace(btrim(translate(code,'٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹','01234567890123456789')),'[[:space:]]+',' ','g')));
create index assets_kind_status_idx on portfleet_v2.assets(owner_id,kind,status);
create index staff_expiry_idx on portfleet_v2.staff(owner_id,expiry);
create index plans_asset_due_idx on portfleet_v2.plans(owner_id,asset_id,due_date);
create index work_asset_date_idx on portfleet_v2.work(owner_id,asset_id,work_date);
create index work_plan_idx on portfleet_v2.work(owner_id,plan_id);
create index requests_status_start_idx on portfleet_v2.requests(owner_id,status,start_at);
create index requests_asset_idx on portfleet_v2.requests(owner_id,asset_id);
create index requests_driver_idx on portfleet_v2.requests(owner_id,driver_id);
create index assignments_asset_idx on portfleet_v2.assignments(owner_id,asset_id);
create index cranes_asset_date_idx on portfleet_v2.cranes(owner_id,asset_id,shift_date);
create index cranes_operator_idx on portfleet_v2.cranes(owner_id,operator_id);
create index fuel_asset_date_idx on portfleet_v2.fuel(owner_id,asset_id,movement_date);
create index fuel_date_idx on portfleet_v2.fuel(owner_id,movement_date);
create index moves_part_date_idx on portfleet_v2.moves(owner_id,part_id,movement_date);
create index moves_work_idx on portfleet_v2.moves(owner_id,work_id);
create index oils_asset_date_idx on portfleet_v2.oils(owner_id,asset_id,changed_on);
create index audit_date_idx on portfleet_v2.audit(owner_id,occurred_at);
create unique index active_assignment_uq on portfleet_v2.assignments(owner_id,asset_id) where returned_on is null;
create unique index crane_shift_uq on portfleet_v2.cranes(owner_id,asset_id,shift_date,shift);
create unique index operator_shift_uq on portfleet_v2.cranes(owner_id,operator_id,shift_date,shift);

-- Read-only comparisons of all array payloads and their original order.
-- No sensitive payload returned: only counts and equality flags.
create function portfleet_v2.verify_owner(p_owner uuid)
returns table(section text,source_count bigint,staged_count bigint,exact_match boolean)
language plpgsql security invoker set search_path='' as $$
declare s jsonb; rev bigint; stage_rev bigint; k text; staged jsonb;
begin
 select revision,snapshot into rev,s from public.portfleet_state where owner_id=p_owner;
 select source_revision into stage_rev from portfleet_v2.workspace where owner_id=p_owner;
 if rev is null or stage_rev is null or rev<>stage_rev then
   raise exception 'SOURCE_REVISION_CHANGED_OR_NOT_STAGED' using errcode='40001';
 end if;
 foreach k in array array['assets','staff','parts','plans','work','requests','assignments','cranes','fuel','moves','oils','audit'] loop
   execute format('select coalesce(jsonb_agg(payload order by source_position),''[]''::jsonb) from portfleet_v2.%I where owner_id=$1',k)
     into staged using p_owner;
   section:=k; source_count:=jsonb_array_length(s->k); staged_count:=jsonb_array_length(staged);
   exact_match:=(s->k=staged); return next;
 end loop;
end; $$;
revoke all on function portfleet_v2.verify_owner(uuid) from public, anon, authenticated;

-- Initial one-time import of a single owner at an explicit source revision.
-- All inserts and validation are atomic; any error rolls back the statement.
create function portfleet_v2.stage_owner(p_owner uuid,p_expected bigint)
returns bigint language plpgsql security invoker set search_path='' as $$
declare v_snapshot jsonb; v_revision bigint; k text;
begin
 select revision,snapshot into v_revision,v_snapshot
 from public.portfleet_state where owner_id=p_owner for share;
 if p_expected is null or v_revision is null or p_expected<>v_revision then
   raise exception 'SOURCE_REVISION_CHANGED' using errcode='40001';
 end if;
 if jsonb_typeof(v_snapshot) is distinct from 'object' or v_snapshot->'version' is distinct from '1'::jsonb then
   raise exception 'INVALID_SNAPSHOT';
 end if;
 foreach k in array array['assets','staff','parts','plans','work','requests','assignments','cranes','fuel','moves','oils','audit'] loop
   if jsonb_typeof(v_snapshot->k) is distinct from 'array' then raise exception 'INVALID_SECTION: %',k; end if;
   if exists(select 1 from jsonb_array_elements(v_snapshot->k) r(value)
      where jsonb_typeof(r.value) is distinct from 'object'
         or jsonb_typeof(r.value->'id') is distinct from 'string'
         or btrim(r.value->>'id')='') then raise exception 'INVALID_RECORD: %',k; end if;
 end loop;
 if exists(select 1 from portfleet_v2.workspace where owner_id=p_owner) then
   raise exception 'ALREADY_STAGED';
 end if;
 insert into portfleet_v2.workspace(owner_id,source_revision) values(p_owner,v_revision);

  insert into portfleet_v2.assets(owner_id,record_id,source_position,payload,code,kind,meter,tank,status,safe)
  select p_owner,r.value->>'id',r.ord,r.value,nullif(r.value->>'code',''),nullif(r.value->>'type',''),nullif(r.value->>'meter','')::numeric,nullif(r.value->>'tank','')::numeric,nullif(r.value->>'status',''),nullif(r.value->>'safe','')
  from jsonb_array_elements(v_snapshot->'assets') with ordinality as r(value,ord);

  insert into portfleet_v2.staff(owner_id,record_id,source_position,payload,code,name,expiry)
  select p_owner,r.value->>'id',r.ord,r.value,nullif(r.value->>'code',''),nullif(r.value->>'name',''),nullif(r.value->>'expiry','')::date
  from jsonb_array_elements(v_snapshot->'staff') with ordinality as r(value,ord);

  insert into portfleet_v2.parts(owner_id,record_id,source_position,payload,code,name,qty,min_qty,unit_cost)
  select p_owner,r.value->>'id',r.ord,r.value,nullif(r.value->>'code',''),nullif(r.value->>'name',''),nullif(r.value->>'qty','')::numeric,nullif(r.value->>'min','')::numeric,nullif(r.value->>'cost','')::numeric
  from jsonb_array_elements(v_snapshot->'parts') with ordinality as r(value,ord);

  insert into portfleet_v2.plans(owner_id,record_id,source_position,payload,asset_id,interval_units,last_meter,due_date)
  select p_owner,r.value->>'id',r.ord,r.value,nullif(r.value->>'asset',''),nullif(r.value->>'interval','')::numeric,nullif(r.value->>'last','')::numeric,nullif(r.value->>'due','')::date
  from jsonb_array_elements(v_snapshot->'plans') with ordinality as r(value,ord);

  insert into portfleet_v2.work(owner_id,record_id,source_position,payload,asset_id,plan_id,work_date,status,cost)
  select p_owner,r.value->>'id',r.ord,r.value,nullif(r.value->>'asset',''),nullif(r.value->>'plan',''),nullif(r.value->>'date','')::date,nullif(r.value->>'status',''),nullif(r.value->>'cost','')::numeric
  from jsonb_array_elements(v_snapshot->'work') with ordinality as r(value,ord);

  insert into portfleet_v2.requests(owner_id,record_id,source_position,payload,asset_id,driver_id,status,start_at,end_at)
  select p_owner,r.value->>'id',r.ord,r.value,nullif(r.value->>'asset',''),nullif(r.value->>'driver',''),nullif(r.value->>'status',''),nullif(r.value->>'start','')::timestamp,nullif(r.value->>'end','')::timestamp
  from jsonb_array_elements(v_snapshot->'requests') with ordinality as r(value,ord);

  insert into portfleet_v2.assignments(owner_id,record_id,source_position,payload,asset_id,assigned_on,returned_on,quota)
  select p_owner,r.value->>'id',r.ord,r.value,nullif(r.value->>'asset',''),nullif(r.value->>'date','')::date,nullif(r.value->>'returned','')::date,nullif(r.value->>'quota','')::numeric
  from jsonb_array_elements(v_snapshot->'assignments') with ordinality as r(value,ord);

  insert into portfleet_v2.cranes(owner_id,record_id,source_position,payload,asset_id,operator_id,shift_date,shift,work_hours,wait_hours,down_hours,tonnes,fuel_litres)
  select p_owner,r.value->>'id',r.ord,r.value,nullif(r.value->>'asset',''),nullif(r.value->>'operator',''),nullif(r.value->>'date','')::date,nullif(r.value->>'shift',''),nullif(r.value->>'work','')::numeric,nullif(r.value->>'wait','')::numeric,nullif(r.value->>'down','')::numeric,nullif(r.value->>'tons','')::numeric,nullif(r.value->>'fuel','')::numeric
  from jsonb_array_elements(v_snapshot->'cranes') with ordinality as r(value,ord);

  insert into portfleet_v2.fuel(owner_id,record_id,source_position,payload,asset_id,movement_date,kind,qty,meter)
  select p_owner,r.value->>'id',r.ord,r.value,nullif(r.value->>'asset',''),nullif(r.value->>'date','')::date,nullif(r.value->>'kind',''),nullif(r.value->>'qty','')::numeric,nullif(r.value->>'meter','')::numeric
  from jsonb_array_elements(v_snapshot->'fuel') with ordinality as r(value,ord);

  insert into portfleet_v2.moves(owner_id,record_id,source_position,payload,part_id,work_id,movement_date,kind,qty,unit_cost)
  select p_owner,r.value->>'id',r.ord,r.value,nullif(r.value->>'part',''),nullif(r.value->>'work',''),nullif(r.value->>'date','')::date,nullif(r.value->>'kind',''),nullif(r.value->>'qty','')::numeric,nullif(r.value->>'cost','')::numeric
  from jsonb_array_elements(v_snapshot->'moves') with ordinality as r(value,ord);

  insert into portfleet_v2.oils(owner_id,record_id,source_position,payload,asset_id,oil_type,changed_on,meter,qty,interval_units,cost)
  select p_owner,r.value->>'id',r.ord,r.value,nullif(r.value->>'asset',''),nullif(r.value->>'oil',''),nullif(r.value->>'date','')::date,nullif(r.value->>'meter','')::numeric,nullif(r.value->>'qty','')::numeric,nullif(r.value->>'interval','')::numeric,nullif(r.value->>'cost','')::numeric
  from jsonb_array_elements(v_snapshot->'oils') with ordinality as r(value,ord);

  insert into portfleet_v2.audit(owner_id,record_id,source_position,payload,occurred_at)
  select p_owner,r.value->>'id',r.ord,r.value,nullif(r.value->>'date','')::timestamptz
  from jsonb_array_elements(v_snapshot->'audit') with ordinality as r(value,ord);

 -- Historical fuel stock check by day, matching the current app's day-level policy.
 if exists(
   select 1 from (
     select sum(sum(case when kind='استلام' then qty else -qty end)) over(order by movement_date) as balance
     from portfleet_v2.fuel where owner_id=p_owner group by movement_date
   ) q where balance < -0.00000001
 ) then raise exception 'NEGATIVE_HISTORICAL_FUEL_BALANCE'; end if;
 if exists(select 1 from portfleet_v2.verify_owner(p_owner) where exact_match is distinct from true) then
   raise exception 'RECONCILIATION_FAILED';
 end if;
 return v_revision;
end; $$;
revoke all on function portfleet_v2.stage_owner(uuid,bigint) from public, anon, authenticated;
commit;

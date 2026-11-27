-- Port Fleet database/security phase 1. STAGING FIRST.
-- Requires existing V8.1 central state and V9.3 security/personal tables.
-- This migration is additive: existing snapshot APIs remain authoritative.
-- Do not apply to fish-market or production before backup and staging tests.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '120s';
select pg_advisory_xact_lock(71420261127);
lock table public.portfleet_state, public.portfleet_personal_state in share row exclusive mode;

create schema portfleet_v2;
revoke all on schema portfleet_v2 from public, anon, authenticated;

create table portfleet_v2.workspaces (
 scope text not null check (scope in ('central','personal')),
 account_id uuid not null references auth.users(id) on delete cascade,
 revision bigint not null check (revision > 0),
 indexed_at timestamptz not null default clock_timestamp(),
 primary key(scope,account_id)
);
create table portfleet_v2.records (
 scope text not null,
 account_id uuid not null,
 collection text not null check (collection in ('assets','staff','requests','assignments','cranes','fuel','work','plans','parts','moves','oils','audit')),
 record_id text not null check (char_length(record_id) between 1 and 128 and record_id=btrim(record_id)),
 payload jsonb not null check (jsonb_typeof(payload)='object' and jsonb_typeof(payload->'id')='string' and payload->>'id'=record_id),
 position integer not null check (position>=0),
 primary key(scope,account_id,collection,record_id),
 foreign key(scope,account_id) references portfleet_v2.workspaces(scope,account_id) on delete cascade
);
create index pf_v2_records_order on portfleet_v2.records(scope,account_id,collection,position);
create table portfleet_v2.record_links (
 scope text not null,
 account_id uuid not null,
 source_collection text not null,
 source_id text not null,
 field_name text not null,
 target_collection text not null,
 target_id text not null,
 primary key(scope,account_id,source_collection,source_id,field_name),
 foreign key(scope,account_id,source_collection,source_id) references portfleet_v2.records(scope,account_id,collection,record_id) on delete cascade,
 foreign key(scope,account_id,target_collection,target_id) references portfleet_v2.records(scope,account_id,collection,record_id) on delete no action deferrable initially deferred
);
create index pf_v2_links_target on portfleet_v2.record_links(scope,account_id,target_collection,target_id);
-- Server-side audit metadata only; no employee names or payload duplicated into audit.
-- No app-facing delete/update grant. DB administrators still control retention.
create table portfleet_v2.revision_events (
 event_id bigint generated always as identity primary key,
 scope text not null check (scope in ('central','personal')),
 account_id uuid not null,
 revision bigint not null check (revision>0),
 actor_id uuid,
 event_type text not null check (event_type in ('baseline','insert','update','delete')),
 occurred_at timestamptz not null default clock_timestamp(),
 inserted_count integer not null check (inserted_count>=0),
 updated_count integer not null check (updated_count>=0),
 deleted_count integer not null check (deleted_count>=0)
);
create index pf_v2_events_workspace on portfleet_v2.revision_events(scope,account_id,occurred_at desc);
alter table portfleet_v2.workspaces enable row level security;
alter table portfleet_v2.records enable row level security;
alter table portfleet_v2.record_links enable row level security;
alter table portfleet_v2.revision_events enable row level security;
revoke all on all tables in schema portfleet_v2 from public,anon,authenticated;
revoke all on all sequences in schema portfleet_v2 from public,anon,authenticated;

create function portfleet_v2.validate_snapshot(s jsonb)
returns void language plpgsql security invoker set search_path='' as $$
declare k text;
begin
 if jsonb_typeof(s) is distinct from 'object' or s->'version' is distinct from '1'::jsonb
 or octet_length(s::text)>2097152 then
  raise exception 'PF_INVALID_SNAPSHOT' using errcode='22023';
 end if;
 foreach k in array array['assets','staff','requests','assignments','cranes','fuel','work','plans','parts','moves','oils','audit'] loop
  if jsonb_typeof(s->k) is distinct from 'array' then
   raise exception 'PF_MISSING_COLLECTION: %',k using errcode='22023';
  end if;
  if exists(select 1 from jsonb_array_elements(s->k) as x(v)
   where jsonb_typeof(v) is distinct from 'object' or jsonb_typeof(v->'id') is distinct from 'string'
   or char_length(v->>'id') not between 1 and 128 or btrim(v->>'id')<>v->>'id'
   or (v->>'id') ~ '[[:cntrl:]]') then
   raise exception 'PF_INVALID_RECORD_ID: %',k using errcode='22023';
  end if;
  if exists(select 1 from jsonb_array_elements(s->k) as x(v) group by v->>'id' having count(*)>1) then
   raise exception 'PF_DUPLICATE_RECORD_ID: %',k using errcode='22023';
  end if;
 end loop;
end;
$$;

-- Explicitly list legacy relationships. Optional empty links (e.g. unassigned request)
-- remain empty. Reject nonempty references that have no same-workspace target.
create function portfleet_v2.snapshot_links(s jsonb)
returns table(source_collection text,source_id text,field_name text,target_collection text,target_id text)
language sql immutable security invoker set search_path='' as $$
 select m.src, r.v->>'id',m.fld,m.dst,r.v->>m.fld
 from (values
 ('requests','asset','assets'),('requests','driver','staff'),
 ('assignments','asset','assets'),('cranes','asset','assets'),('cranes','operator','staff'),
 ('fuel','asset','assets'),('work','asset','assets'),('work','plan','plans'),
 ('plans','asset','assets'),('moves','part','parts'),('moves','work','work'),
 ('oils','asset','assets')) as m(src,fld,dst)
 cross join lateral jsonb_array_elements(s->m.src) as r(v)
 where nullif(r.v->>m.fld,'') is not null;
$$;

create function portfleet_v2.project_snapshot(p_scope text,p_account uuid,p_revision bigint,p_snapshot jsonb,p_event text)
returns void language plpgsql security definer set search_path='' as $$
declare
 inserted_n integer; updated_n integer; deleted_n integer;
begin
 perform portfleet_v2.validate_snapshot(p_snapshot);
 if exists(select 1 from portfleet_v2.snapshot_links(p_snapshot) l
 where not exists(select 1 from jsonb_array_elements(p_snapshot->l.target_collection) t(v) where t.v->>'id'=l.target_id)) then
  raise exception 'PF_ORPHAN_REFERENCE' using errcode='23503';
 end if;
 insert into portfleet_v2.workspaces(scope,account_id,revision)
 values(p_scope,p_account,p_revision)
 on conflict(scope,account_id) do update set revision=excluded.revision,indexed_at=clock_timestamp();
 -- Clear only this workspace's edges; rebuild in same transaction.
 delete from portfleet_v2.record_links where scope=p_scope and account_id=p_account;
 delete from portfleet_v2.records r where r.scope=p_scope and r.account_id=p_account
 and not exists(select 1 from jsonb_array_elements(p_snapshot->r.collection) x(v) where x.v->>'id'=r.record_id);
 get diagnostics deleted_n=row_count;
 select count(*) into inserted_n
 from unnest(array['assets','staff','requests','assignments','cranes','fuel','work','plans','parts','moves','oils','audit']) k(collection)
 cross join lateral jsonb_array_elements(p_snapshot->k.collection) x(v)
 where not exists(select 1 from portfleet_v2.records r where r.scope=p_scope and r.account_id=p_account and r.collection=k.collection and r.record_id=x.v->>'id');
 select count(*) into updated_n
 from unnest(array['assets','staff','requests','assignments','cranes','fuel','work','plans','parts','moves','oils','audit']) k(collection)
 cross join lateral jsonb_array_elements(p_snapshot->k.collection) x(v)
 join portfleet_v2.records r on r.scope=p_scope and r.account_id=p_account and r.collection=k.collection and r.record_id=x.v->>'id'
 where r.payload is distinct from x.v;
 insert into portfleet_v2.records as dst(scope,account_id,collection,record_id,payload,position)
 select p_scope,p_account,k.collection,x.v->>'id',x.v,(x.ord-1)::integer
 from unnest(array['assets','staff','requests','assignments','cranes','fuel','work','plans','parts','moves','oils','audit']) k(collection)
 cross join lateral jsonb_array_elements(p_snapshot->k.collection) with ordinality x(v,ord)
 on conflict(scope,account_id,collection,record_id) do update set payload=excluded.payload,position=excluded.position
 where dst.payload is distinct from excluded.payload or dst.position is distinct from excluded.position;
 insert into portfleet_v2.record_links(scope,account_id,source_collection,source_id,field_name,target_collection,target_id)
 select p_scope,p_account,l.source_collection,l.source_id,l.field_name,l.target_collection,l.target_id
 from portfleet_v2.snapshot_links(p_snapshot) l;
 insert into portfleet_v2.revision_events(scope,account_id,revision,actor_id,event_type,inserted_count,updated_count,deleted_count)
 values(p_scope,p_account,p_revision,auth.uid(),p_event,inserted_n,updated_n,deleted_n);
end;
$$;

create function portfleet_v2.snapshot_guard()
returns trigger language plpgsql security definer set search_path='' as $$
declare sc text; uid uuid;
begin
 if tg_table_schema <> 'public' then raise exception 'PF_INVALID_SOURCE'; end if;
 if tg_table_name='portfleet_state' then sc:='central'; uid:=new.owner_id;
 elsif tg_table_name='portfleet_personal_state' then sc:='personal'; uid:=new.user_id;
 else raise exception 'PF_INVALID_SOURCE'; end if;
 if tg_op='INSERT' then
  if new.revision is distinct from 1::bigint then raise exception 'PF_INVALID_REVISION' using errcode='22023'; end if;
 else
  if new.revision is distinct from old.revision+1 then raise exception 'PF_INVALID_REVISION' using errcode='22023'; end if;
  if sc='central' then
   if new.owner_id is distinct from old.owner_id then raise exception 'PF_IMMUTABLE_OWNER' using errcode='22023'; end if;
  else
   if new.user_id is distinct from old.user_id then raise exception 'PF_IMMUTABLE_OWNER' using errcode='22023'; end if;
  end if;
 end if;
 perform portfleet_v2.project_snapshot(sc,uid,new.revision,new.snapshot,lower(tg_op));
 return new;
end;
$$;

-- Never grant these helper functions to browser clients.
revoke all on all functions in schema portfleet_v2 from public,anon,authenticated;
-- Backfill under locks. Any invalid legacy row aborts the ENTIRE transaction,
-- leaving live snapshots untouched. Do not repair legacy data automatically.
do $$
declare r record;
begin
 for r in select owner_id,revision,snapshot from public.portfleet_state loop
  perform portfleet_v2.project_snapshot('central',r.owner_id,r.revision,r.snapshot,'baseline');
 end loop;
 for r in select user_id,revision,snapshot from public.portfleet_personal_state loop
  perform portfleet_v2.project_snapshot('personal',r.user_id,r.revision,r.snapshot,'baseline');
 end loop;
end;
$$;
create trigger pf_v2_central_sync after insert or update on public.portfleet_state
for each row execute function portfleet_v2.snapshot_guard();
create trigger pf_v2_personal_sync after insert or update on public.portfleet_personal_state
for each row execute function portfleet_v2.snapshot_guard();
-- Deleting a snapshot is not supported by the app. Clean mirror if an administrator
-- deletes a source row, retaining the server revision event.
create function portfleet_v2.snapshot_delete()
returns trigger language plpgsql security definer set search_path='' as $$
declare sc text; uid uuid; n integer;
begin
 if tg_table_schema <> 'public' then raise exception 'PF_INVALID_SOURCE'; end if;
 if tg_table_name='portfleet_state' then sc:='central'; uid:=old.owner_id;
 elsif tg_table_name='portfleet_personal_state' then sc:='personal'; uid:=old.user_id;
 else raise exception 'PF_INVALID_SOURCE'; end if;
 select count(*) into n from portfleet_v2.records where scope=sc and account_id=uid;
 delete from portfleet_v2.workspaces where scope=sc and account_id=uid;
 insert into portfleet_v2.revision_events(scope,account_id,revision,actor_id,event_type,inserted_count,updated_count,deleted_count)
 values(sc,uid,old.revision,auth.uid(),'delete',0,0,n);
 return old;
end;
$$;
revoke all on function portfleet_v2.snapshot_delete() from public,anon,authenticated;
create trigger pf_v2_central_delete after delete on public.portfleet_state for each row execute function portfleet_v2.snapshot_delete();
create trigger pf_v2_personal_delete after delete on public.portfleet_personal_state for each row execute function portfleet_v2.snapshot_delete();
commit;

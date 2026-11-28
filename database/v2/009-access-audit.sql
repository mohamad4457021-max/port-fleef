-- V2 staging-only authorization and server audit. Run after 001, 005 and 007.
-- API schema is NOT exposed through PostgREST. Explicit DBA opt-in per test workspace.
-- No existing RPC, V1 data or V1 access policy is changed.
begin;
create schema portfleet_v2_api;
revoke all on schema portfleet_v2_api from public, anon, authenticated;
grant usage on schema portfleet_v2_api to authenticated;

create table portfleet_v2.api_workspace (
 owner_id uuid primary key references portfleet_v2.workspace(owner_id),
 enabled boolean not null default false
);
create table portfleet_v2.api_grant (
 owner_id uuid not null references portfleet_v2.api_workspace(owner_id),
 actor_id uuid not null references auth.users(id),
 permission text not null check(permission in ('fuel.post','inventory.post')),
 primary key(owner_id,actor_id,permission)
);
create table portfleet_v2.server_audit (
 event_id bigint generated always as identity primary key,
 owner_id uuid not null references portfleet_v2.api_workspace(owner_id),
 actor_id uuid not null,
 action text not null check(action in ('fuel.post','inventory.post','access.set')),
 operation_id uuid,
 sequence_no bigint,
 detail jsonb not null,
 occurred_at timestamptz not null default clock_timestamp(),
 check ((action='access.set' and operation_id is null and sequence_no is null)
     or (action<>'access.set' and operation_id is not null and sequence_no>0))
);
create unique index server_audit_operation_uq on portfleet_v2.server_audit(owner_id,action,operation_id) where operation_id is not null;
create index server_audit_owner_event_idx on portfleet_v2.server_audit(owner_id,event_id desc);
alter table portfleet_v2.api_workspace enable row level security;
alter table portfleet_v2.api_grant enable row level security;
alter table portfleet_v2.server_audit enable row level security;
revoke all on portfleet_v2.api_workspace,portfleet_v2.api_grant,portfleet_v2.server_audit from public,anon,authenticated;
revoke all on sequence portfleet_v2.server_audit_event_id_seq from public,anon,authenticated;

-- Defense against accidental update/delete. A privileged DBA can still alter schema.
create function portfleet_v2.reject_audit_mutation()
returns trigger language plpgsql set search_path='' as $$
begin raise exception 'AUDIT_APPEND_ONLY' using errcode='42501';end; $$;
create trigger server_audit_no_mutation before update or delete or truncate on portfleet_v2.server_audit
for each statement execute function portfleet_v2.reject_audit_mutation();
revoke all on function portfleet_v2.reject_audit_mutation() from public,anon,authenticated;

-- All callers use the same workspace lock BEFORE checking permissions.
-- Grants and operations serialize, so revocation cannot race a later authorized write.
create function portfleet_v2.require_actor(p_owner uuid,p_permission text)
returns uuid language plpgsql security invoker set search_path='' as $$
declare v_actor uuid:=auth.uid(); v_enabled boolean;
begin
 if v_actor is null or not exists(select 1 from auth.users u where u.id=v_actor and u.email_confirmed_at is not null) then
  raise exception 'ACCESS_DENIED' using errcode='42501';end if;
 select enabled into v_enabled from portfleet_v2.api_workspace where owner_id=p_owner for update;
 if v_enabled is distinct from true then raise exception 'ACCESS_DENIED' using errcode='42501';end if;
 if exists(select 1 from public.portfleet_owner where user_id=p_owner and user_id=v_actor) then return v_actor;end if;
 if p_permission in ('fuel.post','inventory.post') and exists(
  select 1 from portfleet_v2.api_grant where owner_id=p_owner and actor_id=v_actor and permission=p_permission
 ) then return v_actor;end if;
 raise exception 'ACCESS_DENIED' using errcode='42501';
end; $$;
revoke all on function portfleet_v2.require_actor(uuid,text) from public,anon,authenticated;

create function portfleet_v2_api.set_access(p_owner uuid,p_actor uuid,p_permission text,p_enabled boolean)
returns boolean language plpgsql security definer set search_path='' as $$
declare v_actor uuid; v_changed bigint;
begin
 v_actor:=portfleet_v2.require_actor(p_owner,'owner');
 if p_actor is null or p_actor=p_owner or p_permission is null or p_permission not in ('fuel.post','inventory.post') or p_enabled is null
 or not exists(select 1 from auth.users u where u.id=p_actor and u.email_confirmed_at is not null)
 or exists(select 1 from public.portfleet_owner o where o.user_id=p_actor) then
  raise exception 'INVALID_GRANT' using errcode='22023';end if;
 if p_enabled then
  insert into portfleet_v2.api_grant values(p_owner,p_actor,p_permission) on conflict do nothing;
 else
  delete from portfleet_v2.api_grant where owner_id=p_owner and actor_id=p_actor and permission=p_permission;
 end if;
 get diagnostics v_changed=row_count;
 if v_changed>0 then
  insert into portfleet_v2.server_audit(owner_id,actor_id,action,detail)
  values(p_owner,v_actor,'access.set',jsonb_build_object('target',p_actor,'permission',p_permission,'enabled',p_enabled));
 end if;
 return v_changed>0;
end; $$;

-- For an exact retry, only the original actor may reuse an existing operation UUID.
-- Do not adopt a transaction posted directly by a DBA without matching audit.
create function portfleet_v2_api.post_fuel(p_owner uuid,p_operation uuid,p_expected bigint,p_kind text,p_asset text,p_date date,p_qty numeric,p_reference text)
returns bigint language plpgsql security definer set search_path='' as $$
declare v_actor uuid; v_seq bigint; v_prior uuid;
begin
 v_actor:=portfleet_v2.require_actor(p_owner,'fuel.post');
 select actor_id into v_prior from portfleet_v2.server_audit where owner_id=p_owner and action='fuel.post' and operation_id=p_operation;
 if found then
  if v_prior<>v_actor then raise exception 'OPERATION_ACTOR_CONFLICT' using errcode='42501';end if;
 elsif exists(select 1 from portfleet_v2.fuel_transaction where owner_id=p_owner and operation_id=p_operation) then
  raise exception 'UNAUDITED_OPERATION' using errcode='42501';
 end if;
 v_seq:=portfleet_v2.post_fuel(p_owner,p_operation,p_expected,p_kind,p_asset,p_date,p_qty,p_reference);
 insert into portfleet_v2.server_audit(owner_id,actor_id,action,operation_id,sequence_no,detail)
 values(p_owner,v_actor,'fuel.post',p_operation,v_seq,jsonb_build_object('kind',p_kind,'asset',p_asset,'date',p_date,'qty',p_qty,'reference',p_reference))
 on conflict(owner_id,action,operation_id) where operation_id is not null do nothing;
 return v_seq;
end; $$;

create function portfleet_v2_api.post_inventory(p_owner uuid,p_operation uuid,p_expected bigint,p_kind text,p_part text,p_work text,p_qty numeric,p_reference text)
returns bigint language plpgsql security definer set search_path='' as $$
declare v_actor uuid; v_seq bigint; v_prior uuid;
begin
 v_actor:=portfleet_v2.require_actor(p_owner,'inventory.post');
 select actor_id into v_prior from portfleet_v2.server_audit where owner_id=p_owner and action='inventory.post' and operation_id=p_operation;
 if found then
  if v_prior<>v_actor then raise exception 'OPERATION_ACTOR_CONFLICT' using errcode='42501';end if;
 elsif exists(select 1 from portfleet_v2.inventory_transaction where owner_id=p_owner and operation_id=p_operation) then
  raise exception 'UNAUDITED_OPERATION' using errcode='42501';
 end if;
 v_seq:=portfleet_v2.post_inventory(p_owner,p_operation,p_expected,p_kind,p_part,p_work,p_qty,p_reference);
 insert into portfleet_v2.server_audit(owner_id,actor_id,action,operation_id,sequence_no,detail)
 values(p_owner,v_actor,'inventory.post',p_operation,v_seq,jsonb_build_object('kind',p_kind,'part',p_part,'work',p_work,'qty',p_qty,'reference',p_reference))
 on conflict(owner_id,action,operation_id) where operation_id is not null do nothing;
 return v_seq;
end; $$;

-- Owner-only keyset pagination. No unbounded audit dumps.
create function portfleet_v2_api.audit_page(p_owner uuid,p_before bigint default null,p_limit integer default 50)
returns setof jsonb language plpgsql security definer set search_path='' as $$
begin
 perform portfleet_v2.require_actor(p_owner,'owner');
 if p_limit is null or p_limit not between 1 and 100 or (p_before is not null and p_before<=0) then
 raise exception 'INVALID_PAGE' using errcode='22023';end if;
 return query select to_jsonb(a) from portfleet_v2.server_audit a
 where a.owner_id=p_owner and (p_before is null or a.event_id<p_before)
 order by a.event_id desc limit p_limit;
end; $$;

revoke all on all functions in schema portfleet_v2_api from public,anon,authenticated;
grant execute on function portfleet_v2_api.set_access(uuid,uuid,text,boolean) to authenticated;
grant execute on function portfleet_v2_api.post_fuel(uuid,uuid,bigint,text,text,date,numeric,text) to authenticated;
grant execute on function portfleet_v2_api.post_inventory(uuid,uuid,bigint,text,text,text,numeric,text) to authenticated;
grant execute on function portfleet_v2_api.audit_page(uuid,bigint,integer) to authenticated;
commit;

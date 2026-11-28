-- CI only. Staged test accounts and data; no actual tokens are used.
begin;
select portfleet_v2.stage_owner('00000000-0000-4000-8000-000000000001',1);
insert into portfleet_v2.api_workspace values ('00000000-0000-4000-8000-000000000001',true);
set local role authenticated;
do $$
declare
 o uuid:='00000000-0000-4000-8000-000000000001';
 u uuid:='00000000-0000-4000-8000-000000000002';
 op uuid:='60000000-0000-4000-8000-000000000001';
 v jsonb;
begin
 perform set_config('request.jwt.claim.sub',o::text,true);
 perform portfleet_v2_api.set_access(o,u,'fuel.post',true);
 v:=portfleet_v2_api.sync_state(o,'fuel');
 if v->>'sequence' is distinct from '0' or v->>'source_revision' is distinct from '1' then raise exception 'BAD_INITIAL_STATE';end if;
 perform set_config('request.jwt.claim.sub',u::text,true);
 if portfleet_v2_api.sync_receipt(o,'fuel',op) is not null then raise exception 'UNKNOWN_RECEIPT';end if;
 perform portfleet_v2_api.post_fuel(o,op,0,'صرف','a','2026-01-02',1,'SYNC');
 v:=portfleet_v2_api.sync_receipt(o,'fuel',op);
 if v->>'actor' is distinct from u::text or v->>'operation' is distinct from op::text or v->>'sequence' is distinct from '1' then raise exception 'BAD_RECEIPT';end if;
 v:=portfleet_v2_api.sync_state(o,'fuel');
 if v->>'sequence' is distinct from '1' then raise exception 'BAD_SEQUENCE';end if;
 begin
  perform portfleet_v2_api.sync_state(o,'inventory');
  raise exception 'EXPECTED_STREAM_DENIAL';
 exception when insufficient_privilege then null;end;
 perform set_config('request.jwt.claim.sub',o::text,true);
 if portfleet_v2_api.sync_receipt(o,'fuel',op) is not null then raise exception 'OTHER_ACTOR_RECEIPT_LEAK';end if;
 perform portfleet_v2_api.set_access(o,u,'fuel.post',false);
 perform set_config('request.jwt.claim.sub',u::text,true);
 begin
  perform portfleet_v2_api.sync_receipt(o,'fuel',op);
  raise exception 'EXPECTED_REVOKED_DENIAL';
 exception when insufficient_privilege then null;end;
end $$;
reset role;
update public.portfleet_state set revision=revision+1 where owner_id='00000000-0000-4000-8000-000000000001';
set local role authenticated;
do $$
begin
 perform set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000001',true);
 begin
  perform portfleet_v2_api.sync_state('00000000-0000-4000-8000-000000000001','fuel');
  raise exception 'EXPECTED_STALE_DENIAL';
 exception when serialization_failure then null;end;
end $$;
reset role;
do $$
begin
 if has_function_privilege('anon','portfleet_v2_api.sync_state(uuid,text)','EXECUTE') or has_function_privilege('anon','portfleet_v2_api.sync_receipt(uuid,text,uuid)','EXECUTE') then raise exception 'ANON_SYNC_EXPOSURE';end if;
 raise notice 'PASS: stream revision, own receipt, permission isolation, stale source, no anonymous grants';
end $$;
rollback;

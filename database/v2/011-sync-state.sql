-- 011: private staging sync read endpoint. No live API exposure.
begin;
create function portfleet_v2_api.sync_state(p_owner uuid,p_stream text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_actor uuid; v_source bigint; v_stage bigint; v_last bigint;
begin
 if p_stream is null or p_stream not in ('fuel','inventory') then
  raise exception 'INVALID_STREAM' using errcode='22023';end if;
 v_actor:=portfleet_v2.require_actor(p_owner,p_stream||'.post');
 select revision into v_source from public.portfleet_state where owner_id=p_owner for share;
 select source_revision into v_stage from portfleet_v2.workspace where owner_id=p_owner for share;
 if v_source is null or v_stage is null or v_source<>v_stage then
  raise exception 'STALE_OR_MISSING_STAGE' using errcode='40001';end if;
 if p_stream='fuel' then
  select coalesce(max(sequence_no),0) into v_last from portfleet_v2.fuel_transaction where owner_id=p_owner;
 else
  select coalesce(max(sequence_no),0) into v_last from portfleet_v2.inventory_transaction where owner_id=p_owner;
 end if;
 -- Bigint counters are transmitted as strings to avoid JS precision loss.
 return jsonb_build_object('owner',p_owner,'actor',v_actor,'stream',p_stream,'source_revision',v_stage::text,'sequence',v_last::text);
end; $$;
revoke all on function portfleet_v2_api.sync_state(uuid,text) from public,anon,authenticated;
grant execute on function portfleet_v2_api.sync_state(uuid,text) to authenticated;

-- Exact own-operation receipt. No other employee's transaction details returned.
-- The current permission is checked even if the receipt already exists.
create function portfleet_v2_api.sync_receipt(p_owner uuid,p_stream text,p_operation uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_actor uuid; v_result jsonb;
begin
 if p_stream is null or p_stream not in ('fuel','inventory') or p_operation is null then
  raise exception 'INVALID_RECEIPT_QUERY' using errcode='22023';end if;
 v_actor:=portfleet_v2.require_actor(p_owner,p_stream||'.post');
 select jsonb_build_object('owner',owner_id,'actor',actor_id,'stream',p_stream,
 'operation',operation_id,'sequence',sequence_no::text,'recorded_at',occurred_at)
 into v_result from portfleet_v2.server_audit
 where owner_id=p_owner and actor_id=v_actor and action=p_stream||'.post' and operation_id=p_operation;
 return v_result;
end; $$;
revoke all on function portfleet_v2_api.sync_receipt(uuid,text,uuid) from public,anon,authenticated;
grant execute on function portfleet_v2_api.sync_receipt(uuid,text,uuid) to authenticated;
commit;

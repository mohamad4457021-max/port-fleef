-- Real PostgreSQL integration checks against migration and existing RPCs.
-- Disposable fixture only. No live user data.
\set ON_ERROR_STOP on
begin;
do $$begin
 if (select count(*) from portfleet_v2.workspaces)<>3 then raise exception 'FAIL baseline'; end if;
 if (select count(*) from portfleet_v2.revision_events where event_type='baseline')<>3 then raise exception 'FAIL audit baseline'; end if;
 raise notice 'PASS: backfill three isolated workspaces';
end$$;
set local role anon;
do $$begin
 begin perform public.portfleet_save(1,fixture.snapshot('ATTACK')); raise exception 'FAIL anon write accepted'; exception when insufficient_privilege then null; end;
 begin perform 1 from portfleet_v2.records; raise exception 'FAIL anon read accepted'; exception when insufficient_privilege then null; end;
 raise notice 'PASS: anonymous access rejected';
end$$;
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000002',true);
do $$begin
 if (select count(*) from public.portfleet_personal_state)<>1 or exists(select 1 from public.portfleet_personal_state where snapshot->'assets'->0->>'code'<>'PERSONAL-A') then raise exception 'FAIL personal isolation'; end if;
 if exists(select 1 from public.portfleet_state) then raise exception 'FAIL central exposed'; end if;
 begin perform public.portfleet_save(1,fixture.snapshot('ATTACK')); raise exception 'FAIL central write'; exception when insufficient_privilege then null; end;
 begin perform 1 from portfleet_v2.records; raise exception 'FAIL direct read'; exception when insufficient_privilege then null; end;
 begin update public.portfleet_personal_state set snapshot=fixture.snapshot('ATTACK'); raise exception 'FAIL direct write'; exception when insufficient_privilege then null; end;
 raise notice 'PASS: personal isolation and direct access denial';
end$$;
do $$begin
 if public.portfleet_personal_save(1,fixture.snapshot('PERSONAL-A-UPDATED'))<>2 then raise exception 'FAIL revision'; end if;
 begin perform public.portfleet_personal_save(1,fixture.snapshot('STALE')); raise exception 'FAIL stale write'; exception when serialization_failure then null; end;
 begin perform public.portfleet_personal_save(2,jsonb_set(fixture.snapshot('A'),'{assets}','[{"id":"a"},{"id":"a"}]')); raise exception 'FAIL duplicate'; exception when invalid_parameter_value then null; end;
 begin perform public.portfleet_personal_save(2,jsonb_set(fixture.snapshot('A'),'{cranes}','[{"id":"c","asset":"other-workspace"}]')); raise exception 'FAIL orphan'; exception when foreign_key_violation then null; end;
 if (select revision from public.portfleet_personal_state)<>2 then raise exception 'FAIL atomicity'; end if;
 raise notice 'PASS: valid update, stale rejection, duplicate and orphan rollback';
end$$;
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000005',true);
do $$begin
 begin perform public.portfleet_personal_save(0,fixture.snapshot('UNCONFIRMED')); raise exception 'FAIL unconfirmed'; exception when insufficient_privilege then null; end;
 raise notice 'PASS: unconfirmed user rejected';
end$$;
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000004',true);
do $$begin
 if not public.portfleet_staff_can_create_request() then raise exception 'FAIL staff permission'; end if;
 perform public.portfleet_staff_add_request('00000000-0000-4000-8000-000000000010','Operations','Test request','2026-11-27T08:00','2026-11-27T09:00');
 perform public.portfleet_staff_add_request('00000000-0000-4000-8000-000000000010','Operations','Test request','2026-11-27T08:00','2026-11-27T09:00');
 raise notice 'PASS: authorized staff request and idempotent retry';
end$$;
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000001',true);
do $$declare s jsonb; begin
 select snapshot into s from public.portfleet_state;
 if jsonb_array_length(s->'requests')<>1 then raise exception 'FAIL staff retry duplicate'; end if;
 s:=jsonb_set(s,'{cranes}','[{"id":"c","asset":"a"}]');
 if public.portfleet_save(2,s)<>3 then raise exception 'FAIL central update'; end if;
 begin perform public.portfleet_save(3,jsonb_set(s,'{assets}','[]')); raise exception 'FAIL linked asset deletion'; exception when foreign_key_violation then null; end;
 if (select revision from public.portfleet_state)<>3 then raise exception 'FAIL central rollback'; end if;
 raise notice 'PASS: central update and linked deletion rejection';
end$$;
reset role;
do $$begin
 if not exists(select 1 from portfleet_v2.records where scope='personal' and account_id='00000000-0000-4000-8000-000000000002' and payload->>'code'='PERSONAL-A-UPDATED') then raise exception 'FAIL mirror'; end if;
 if not exists(select 1 from portfleet_v2.records where scope='personal' and account_id='00000000-0000-4000-8000-000000000003' and payload->>'code'='PERSONAL-B') then raise exception 'FAIL other account changed'; end if;
 if (select count(*) from portfleet_v2.record_links where scope='central')<>1 then raise exception 'FAIL foreign-key link'; end if;
 if not exists(select 1 from portfleet_v2.revision_events where scope='central' and revision=2 and actor_id='00000000-0000-4000-8000-000000000004' and inserted_count=1) then raise exception 'FAIL staff audit'; end if;
 if not exists(select 1 from public.portfleet_secure_archive where revision=2) then raise exception 'FAIL existing archive'; end if;
 raise notice 'PASS: projection, audit identity, preserved archive';
end$$;
-- Force deferred FK evaluation prior to rollback.
set constraints all immediate;
rollback;

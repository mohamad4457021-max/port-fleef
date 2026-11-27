-- PostgreSQL-only AAL enforcement checks; does not test real TOTP verification.
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000001',true);
select set_config('request.jwt.claim.aal','aal1',true);
do $$begin
 if not exists(select 1 from public.portfleet_owner) then raise exception 'FAIL role lookup'; end if;
 if exists(select 1 from public.portfleet_state) then raise exception 'FAIL AAL1 read'; end if;
 begin perform public.portfleet_save(1,fixture.snapshot('DENIED')); raise exception 'FAIL AAL1 save'; exception when insufficient_privilege then null; end;
 begin perform public.portfleet_archive_list(); raise exception 'FAIL AAL1 archive'; exception when insufficient_privilege then null; end;
 begin perform public.portfleet_archive_read(1); raise exception 'FAIL AAL1 archive read'; exception when insufficient_privilege then null; end;
 begin perform public.portfleet_staff_directory(); raise exception 'FAIL AAL1 directory'; exception when insufficient_privilege then null; end;
 begin perform public.portfleet_staff_list(); raise exception 'FAIL AAL1 list'; exception when insufficient_privilege then null; end;
 begin perform public.portfleet_staff_history_list(); raise exception 'FAIL AAL1 history'; exception when insufficient_privilege then null; end;
 begin perform public.portfleet_staff_operation_list(); raise exception 'FAIL AAL1 operations'; exception when insufficient_privilege then null; end;
 begin perform public.portfleet_staff_set('00000000-0000-4000-8000-000000000004',false,array[]::text[]); raise exception 'FAIL AAL1 staff set'; exception when insufficient_privilege then null; end;
 begin perform public.portfleet_staff_update('00000000-0000-4000-8000-000000000004',1,false,array[]::text[],'','','',''); raise exception 'FAIL AAL1 staff update'; exception when insufficient_privilege then null; end;
 begin perform public.portfleet_staff_update_v811('00000000-0000-4000-8000-000000000004',1,false,array[]::text[],'','','','',array[]::text[],false); raise exception 'FAIL AAL1 staff update v811'; exception when insufficient_privilege then null; end;
 raise notice 'PASS owner AAL1 denied for read/write/archive/staff RPCs';
end$$;
select set_config('request.jwt.claim.aal','aal2',true);
do $$begin
 if (select count(*) from public.portfleet_state)<>1 then raise exception 'FAIL AAL2 read'; end if;
 if public.portfleet_save(1,fixture.snapshot('AAL2'))<>2 then raise exception 'FAIL AAL2 save'; end if;
 perform public.portfleet_archive_list();
 perform public.portfleet_staff_directory();
 raise notice 'PASS owner AAL2 allowed';
end$$;
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000002',true);
do $$begin
 if exists(select 1 from public.portfleet_state) then raise exception 'FAIL non-owner AAL2 read'; end if;
 begin perform public.portfleet_save(2,fixture.snapshot('DENIED')); raise exception 'FAIL non-owner AAL2 write'; exception when insufficient_privilege then null; end;
 raise notice 'PASS non-owner AAL2 denied';
end$$;
select set_config('request.jwt.claim.aal','aal1',true);
do $$begin
 if public.portfleet_personal_save(1,fixture.snapshot('PERSONAL'))<>2 then raise exception 'FAIL personal AAL1'; end if;
 raise notice 'PASS personal remains independent';
end$$;
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000004',true);
do $$begin
 perform public.portfleet_staff_add_request('00000000-0000-4000-8000-000000000011','Ops','MFA staff test','2026-11-27T08:00','2026-11-27T09:00');
 raise notice 'PASS authorized staff request at AAL1';
end$$;
reset role;
set constraints all immediate;
rollback;

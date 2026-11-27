-- Establish real pre-migration rows via the legacy RPCs, not by bypassing them.
set role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000001',false);
select public.portfleet_save(0,fixture.snapshot('CENTRAL'));
select public.portfleet_staff_update_v811('00000000-0000-4000-8000-000000000004',0,true,array['requests'],'Test Staff','Operations','Staff','001',array['requests'],true);
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000002',false);
select public.portfleet_personal_save(0,fixture.snapshot('PERSONAL-A'));
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000003',false);
select public.portfleet_personal_save(0,fixture.snapshot('PERSONAL-B'));
reset role;
select set_config('request.jwt.claim.sub','',false);

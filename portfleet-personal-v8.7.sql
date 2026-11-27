-- Port Fleet V8.7: isolated personal snapshot per authenticated account.
-- Run in the dedicated Port Fleet Supabase SQL editor, not the fish-market project.
begin;
create table if not exists public.portfleet_personal_state (
  user_id uuid primary key references auth.users(id) on delete cascade,
  revision bigint not null check (revision > 0),
  snapshot jsonb not null check (jsonb_typeof(snapshot) = 'object'),
  updated_at timestamptz not null default now()
);
alter table public.portfleet_personal_state enable row level security;
revoke all on public.portfleet_personal_state from public, anon, authenticated;
grant select on public.portfleet_personal_state to authenticated;
drop policy if exists portfleet_personal_state_self_read on public.portfleet_personal_state;
create policy portfleet_personal_state_self_read on public.portfleet_personal_state
for select to authenticated
using (user_id = (select auth.uid()));
create or replace function public.portfleet_personal_save(p_expected bigint, p_snapshot jsonb)
returns bigint
language plpgsql security definer set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_revision bigint;
  v_key text;
begin
  if v_user is null or not exists (
    select 1 from auth.users u where u.id = v_user and u.email_confirmed_at is not null
  ) then raise exception 'CONFIRMED_ACCOUNT_REQUIRED' using errcode = '42501'; end if;
  if p_expected is null or p_expected < 0
     or jsonb_typeof(p_snapshot) is distinct from 'object'
     or p_snapshot->'version' is distinct from '1'::jsonb
     or octet_length(p_snapshot::text) > 2097152
  then raise exception 'INVALID_SNAPSHOT' using errcode = '22023'; end if;
  foreach v_key in array array['assets','staff','requests','assignments','cranes','fuel','work','plans','parts','moves','oils','audit'] loop
    if jsonb_typeof(p_snapshot->v_key) is distinct from 'array' then
      raise exception 'INVALID_SNAPSHOT' using errcode = '22023';
    end if;
    if exists(select 1 from jsonb_array_elements(p_snapshot->v_key) as x(value)
      where jsonb_typeof(x.value) is distinct from 'object'
         or jsonb_typeof(x.value->'id') is distinct from 'string') then
      raise exception 'INVALID_RECORD' using errcode = '22023';
    end if;
  end loop;
  if p_expected = 0 then
    insert into public.portfleet_personal_state(user_id,revision,snapshot)
    values(v_user,1,p_snapshot) on conflict(user_id) do nothing
    returning revision into v_revision;
  else
    update public.portfleet_personal_state set revision=revision+1,snapshot=p_snapshot,updated_at=now()
    where user_id=v_user and revision=p_expected returning revision into v_revision;
  end if;
  if v_revision is null then raise exception 'REVISION_CONFLICT' using errcode='40001'; end if;
  return v_revision;
end;
$$;
revoke all on function public.portfleet_personal_save(bigint,jsonb) from public, anon, authenticated;
grant execute on function public.portfleet_personal_save(bigint,jsonb) to authenticated;
notify pgrst, 'reload schema';
commit;

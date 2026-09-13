-- ELYRA: Maximum 2 active devices per account
-- Run this once in Supabase SQL Editor.

create table if not exists public.user_device_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id text not null,
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique(user_id, device_id)
);

create index if not exists user_device_sessions_user_id_idx
  on public.user_device_sessions(user_id);

alter table public.user_device_sessions enable row level security;

-- Users do not get direct table access. Device-limit operations happen through RPCs.
revoke all on table public.user_device_sessions from anon, authenticated;

create or replace function public.claim_device(p_device_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_count integer;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  if p_device_id is null or length(trim(p_device_id)) < 16 then
    raise exception 'Invalid device';
  end if;

  -- A device that has not checked in for 30 days is considered inactive.
  delete from public.user_device_sessions
  where user_id = v_user_id
    and last_seen_at < now() - interval '30 days';

  -- Refresh an existing device first.
  update public.user_device_sessions
  set last_seen_at = now()
  where user_id = v_user_id
    and device_id = trim(p_device_id);

  if found then
    return jsonb_build_object('allowed', true, 'device_count',
      (select count(*) from public.user_device_sessions where user_id = v_user_id));
  end if;

  select count(*) into v_count
  from public.user_device_sessions
  where user_id = v_user_id;

  if v_count >= 2 then
    return jsonb_build_object('allowed', false, 'device_count', v_count);
  end if;

  insert into public.user_device_sessions(user_id, device_id, last_seen_at)
  values (v_user_id, trim(p_device_id), now());

  return jsonb_build_object('allowed', true, 'device_count', v_count + 1);
end;
$$;

create or replace function public.release_device(p_device_id text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    return false;
  end if;

  delete from public.user_device_sessions
  where user_id = auth.uid()
    and device_id = trim(p_device_id);

  return true;
end;
$$;

revoke all on function public.claim_device(text) from public;
revoke all on function public.release_device(text) from public;
grant execute on function public.claim_device(text) to authenticated;
grant execute on function public.release_device(text) to authenticated;

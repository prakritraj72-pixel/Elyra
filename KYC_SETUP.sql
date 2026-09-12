-- ELYRA KYC FOUNDATION
-- Run this once in Supabase SQL Editor.
-- This creates the KYC state + secure booking/public-profile gates.
-- Actual identity verification must be connected to an approved KYC provider;
-- do not store Aadhaar/PAN images or full ID numbers in Elyra.

create table if not exists public.kyc_verifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  user_type text not null check (user_type in ('customer','creator')),
  status text not null default 'not_started'
    check (status in ('not_started','pending','verified','rejected','expired')),
  provider text,
  provider_reference text,
  rejection_reason text,
  verified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id)
);

create index if not exists kyc_verifications_user_id_idx
  on public.kyc_verifications(user_id);

create index if not exists kyc_verifications_status_idx
  on public.kyc_verifications(status);

alter table public.kyc_verifications enable row level security;

drop policy if exists "Users can view own KYC status" on public.kyc_verifications;
create policy "Users can view own KYC status"
on public.kyc_verifications
for select
to authenticated
using (user_id = auth.uid());

-- Users cannot mark themselves verified. Status changes must happen through
-- the admin/provider workflow below.
drop policy if exists "Users can create own KYC request" on public.kyc_verifications;
create policy "Users can create own KYC request"
on public.kyc_verifications
for insert
to authenticated
with check (
  user_id = auth.uid()
  and status in ('not_started','pending')
);

create or replace function public.has_verified_kyc(p_user_id uuid)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.kyc_verifications
    where user_id = p_user_id
      and status = 'verified'
      and verified_at is not null
  );
$$;

revoke all on function public.has_verified_kyc(uuid) from public;
grant execute on function public.has_verified_kyc(uuid) to authenticated;

create or replace function public.get_my_kyc_status()
returns jsonb
language sql
security definer
set search_path = public
as $$
  select coalesce(
    (
      select jsonb_build_object(
        'status', k.status,
        'user_type', k.user_type,
        'provider', k.provider,
        'provider_reference', k.provider_reference,
        'rejection_reason', k.rejection_reason,
        'verified_at', k.verified_at
      )
      from public.kyc_verifications k
      where k.user_id = auth.uid()
      limit 1
    ),
    jsonb_build_object('status','not_started')
  );
$$;

revoke all on function public.get_my_kyc_status() from public;
grant execute on function public.get_my_kyc_status() to authenticated;

create or replace function public.submit_kyc_request()
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_type text;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if exists (select 1 from public.creator_profiles where user_id = auth.uid()) then
    v_user_type := 'creator';
  else
    v_user_type := 'customer';
  end if;

  insert into public.kyc_verifications(user_id, user_type, status, updated_at)
  values (auth.uid(), v_user_type, 'pending', now())
  on conflict (user_id) do update
  set status = case
                 when public.kyc_verifications.status = 'rejected'
                   then 'pending'
                 when public.kyc_verifications.status = 'expired'
                   then 'pending'
                 else public.kyc_verifications.status
               end,
      rejection_reason = case
                           when public.kyc_verifications.status in ('rejected','expired') then null
                           else public.kyc_verifications.rejection_reason
                         end,
      updated_at = now();

  return true;
end;
$$;

revoke all on function public.submit_kyc_request() from public;
grant execute on function public.submit_kyc_request() to authenticated;

create or replace function public.admin_list_kyc()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Not authorized';
  end if;

  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'id', k.id,
        'user_id', k.user_id,
        'user_type', k.user_type,
        'status', k.status,
        'provider', k.provider,
        'provider_reference', k.provider_reference,
        'rejection_reason', k.rejection_reason,
        'verified_at', k.verified_at,
        'created_at', k.created_at,
        'updated_at', k.updated_at
      )
      order by k.created_at desc
    )
    from public.kyc_verifications k
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.admin_list_kyc() from public;
grant execute on function public.admin_list_kyc() to authenticated;

create or replace function public.admin_set_kyc_status(
  p_user_id uuid,
  p_status text,
  p_rejection_reason text default null,
  p_provider text default null,
  p_provider_reference text default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_type text;
begin
  if not public.is_admin() then
    raise exception 'Not authorized';
  end if;

  if p_status not in ('pending','verified','rejected','expired','not_started') then
    raise exception 'Invalid KYC status';
  end if;

  if exists (select 1 from public.creator_profiles where user_id = p_user_id) then
    v_user_type := 'creator';
  else
    v_user_type := 'customer';
  end if;

  insert into public.kyc_verifications(
    user_id, user_type, status, provider, provider_reference,
    rejection_reason, verified_at, updated_at
  )
  values (
    p_user_id,
    v_user_type,
    p_status,
    p_provider,
    p_provider_reference,
    case when p_status = 'rejected' then p_rejection_reason else null end,
    case when p_status = 'verified' then now() else null end,
    now()
  )
  on conflict (user_id) do update
  set user_type = excluded.user_type,
      status = excluded.status,
      provider = excluded.provider,
      provider_reference = excluded.provider_reference,
      rejection_reason = excluded.rejection_reason,
      verified_at = excluded.verified_at,
      updated_at = now();

  return true;
end;
$$;

revoke all on function public.admin_set_kyc_status(uuid,text,text,text,text) from public;
grant execute on function public.admin_set_kyc_status(uuid,text,text,text,text) to authenticated;

-- Replace the public creator view so an activated creator is visible only
-- after KYC is verified.
drop view if exists public.public_creator_profiles;
create view public.public_creator_profiles
with (security_invoker = false)
as
select
  cp.id,
  cp.creator_username,
  cp.display_name,
  cp.age,
  cp.gender,
  cp.city,
  cp.area,
  cp.hourly_rate,
  cp.availability,
  cp.bio,
  cp.photo_url,
  cp.photo_2_url,
  cp.photo_3_url,
  cp.created_at
from public.creator_profiles cp
where cp.profile_status = 'active'
  and exists (
    select 1
    from public.kyc_verifications k
    where k.user_id = cp.user_id
      and k.status = 'verified'
      and k.verified_at is not null
  );

grant usage on schema public to anon, authenticated;
grant select on public.public_creator_profiles to anon, authenticated;

-- IMPORTANT: enforce customer KYC + active subscription at database level.
drop policy if exists "Customers can create bookings with active subscription" on public.bookings;
create policy "Customers can create bookings with active subscription and KYC"
on public.bookings
for insert
to authenticated
with check (
  customer_id = auth.uid()
  and public.has_active_subscription(auth.uid())
  and public.has_verified_kyc(auth.uid())
  and exists (
    select 1
    from public.creator_profiles cp
    where cp.id = creator_id
      and cp.profile_status = 'active'
      and exists (
        select 1
        from public.kyc_verifications ck
        where ck.user_id = cp.user_id
          and ck.status = 'verified'
          and ck.verified_at is not null
      )
  )
);

-- Make the creator side safe as well: an unverified creator cannot receive
-- a new booking, even if an old client/browser tries to bypass the UI.
drop policy if exists "Customers can create bookings with active subscription and KYC" on public.bookings;
create policy "Customers can create bookings with subscription and KYC"
on public.bookings
for insert
to authenticated
with check (
  customer_id = auth.uid()
  and public.has_active_subscription(auth.uid())
  and public.has_verified_kyc(auth.uid())
  and exists (
    select 1
    from public.creator_profiles cp
    where cp.id = creator_id
      and cp.profile_status = 'active'
      and exists (
        select 1
        from public.kyc_verifications ck
        where ck.user_id = cp.user_id
          and ck.status = 'verified'
          and ck.verified_at is not null
      )
  )
);

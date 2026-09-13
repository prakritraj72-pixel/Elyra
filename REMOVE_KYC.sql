-- ELYRA: REMOVE KYC GATES
-- Run this once in Supabase SQL Editor after removing KYC from the website.

-- Restore public creator visibility to active-profile status only.
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
where cp.profile_status = 'active';

grant usage on schema public to anon, authenticated;
grant select on public.public_creator_profiles to anon, authenticated;

-- Remove the KYC booking gate and restore subscription-only booking.
drop policy if exists "Customers can create bookings with subscription and KYC"
on public.bookings;

drop policy if exists "Customers can create bookings with active subscription and KYC"
on public.bookings;

drop policy if exists "Customers can create bookings with active subscription"
on public.bookings;

create policy "Customers can create bookings with active subscription"
on public.bookings
for insert
to authenticated
with check (
  customer_id = auth.uid()
  and public.has_active_subscription(auth.uid())
  and exists (
    select 1
    from public.creator_profiles cp
    where cp.id = creator_id
      and cp.profile_status = 'active'
  )
);

-- Optional cleanup: remove KYC records/functions after confirming everything works.
-- Uncomment these only if you want the KYC database objects removed completely.
-- drop function if exists public.admin_set_kyc_status(uuid,text,text,text,text);
-- drop function if exists public.admin_list_kyc();
-- drop function if exists public.submit_kyc_request();
-- drop function if exists public.get_my_kyc_status();
-- drop function if exists public.has_verified_kyc(uuid);
-- drop table if exists public.kyc_verifications;

-- Elyra identity verification: latest status + submission time + rejection reason
-- Run this once in Supabase SQL Editor.

drop function if exists public.my_identity_status();

create or replace function public.my_identity_status()
returns table (
  verification_status text,
  identity_verified boolean,
  age_verified boolean,
  provider text,
  provider_reference text,
  verified_at timestamptz,
  expires_at timestamptz,
  created_at timestamptz,
  updated_at timestamptz,
  rejection_reason text
)
language sql
security definer
set search_path = public, auth
as $$
  select
    iv.verification_status,
    iv.identity_verified,
    iv.age_verified,
    iv.provider,
    iv.provider_reference,
    iv.verified_at,
    iv.expires_at,
    iv.created_at,
    iv.updated_at,
    iv.rejection_reason
  from public.identity_verifications iv
  where iv.user_id = auth.uid()
  order by iv.updated_at desc
  limit 1;
$$;

revoke execute on function public.my_identity_status() from public, anon;
grant execute on function public.my_identity_status() to authenticated;

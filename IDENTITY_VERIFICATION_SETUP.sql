-- ELYRA IDENTITY VERIFICATION GATE
-- Phase 1: database security gate for government-ID + live-face verification.
-- IMPORTANT: This file does NOT perform biometric/KYC verification by itself.
-- A compliant KYC provider (e.g. Cashfree Secure ID / HyperVerge / Signzy) must
-- call the server-side verification endpoint and set identity_status='verified'.
-- Never put provider API secrets in GitHub Pages/frontend code.

alter table public.creator_profiles
  add column if not exists identity_status text not null default 'unverified'
    check (identity_status in ('unverified','pending','verified','rejected')),
  add column if not exists identity_provider text,
  add column if not exists identity_reference text,
  add column if not exists identity_verified_at timestamptz,
  add column if not exists identity_rejection_reason text;

create index if not exists creator_profiles_identity_status_idx
  on public.creator_profiles(identity_status);

-- Customer identity state is stored separately from subscriptions.
create table if not exists public.identity_verifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references auth.users(id) on delete cascade,
  role text not null check (role in ('customer','creator')),
  status text not null default 'unverified'
    check (status in ('unverified','pending','verified','rejected')),
  provider text,
  provider_reference text,
  document_type text,
  masked_document text,
  name_match boolean,
  face_match boolean,
  liveness_passed boolean,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  verified_at timestamptz,
  rejection_reason text
);

alter table public.identity_verifications enable row level security;
revoke all on public.identity_verifications from anon, authenticated;

-- Safe status read for the logged-in user. No ID images, document numbers or biometrics.
drop function if exists public.my_identity_status();
create or replace function public.my_identity_status()
returns table (
  status text,
  role text,
  provider text,
  verified_at timestamptz,
  rejection_reason text
)
language sql
security definer
set search_path = public, auth
as $$
  select status, role, provider, verified_at, rejection_reason
  from public.identity_verifications
  where user_id = auth.uid();
$$;
revoke execute on function public.my_identity_status() from public, anon;
grant execute on function public.my_identity_status() to authenticated;

-- Creates/updates a pending verification record. Actual verification must happen
-- through the provider/server-side flow; clients cannot mark themselves verified.
drop function if exists public.start_identity_verification(text);
create or replace function public.start_identity_verification(p_role text)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    return jsonb_build_object('success',false,'message','Please sign in first.');
  end if;
  if p_role not in ('customer','creator') then
    return jsonb_build_object('success',false,'message','Invalid verification role.');
  end if;

  insert into public.identity_verifications(user_id,role,status,updated_at)
  values(v_user,p_role,'pending',now())
  on conflict(user_id) do update set role=excluded.role,status='pending',
    rejection_reason=null,updated_at=now();

  if p_role='creator' then
    update public.creator_profiles
      set identity_status='pending', identity_rejection_reason=null, updated_at=now()
      where user_id=v_user;
  end if;

  return jsonb_build_object(
    'success',true,
    'message','Identity verification started. Complete government-ID and live-face verification.'
  );
end;
$$;
revoke execute on function public.start_identity_verification(text) from public, anon;
grant execute on function public.start_identity_verification(text) to authenticated;

-- Server/admin/provider webhook only. Frontend users do NOT receive execute permission.
drop function if exists public.complete_identity_verification(uuid,text,text,text,boolean,boolean,boolean,text,text);
create or replace function public.complete_identity_verification(
  p_user_id uuid,
  p_role text,
  p_status text,
  p_provider text,
  p_name_match boolean,
  p_face_match boolean,
  p_liveness_passed boolean,
  p_provider_reference text,
  p_rejection_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_verified boolean;
begin
  -- This function intentionally has NO authenticated grant. It must only be called
  -- from a trusted server-side provider webhook/Edge Function.
  if p_role not in ('customer','creator') then
    return jsonb_build_object('success',false,'message','Invalid role.');
  end if;
  if p_status not in ('pending','verified','rejected') then
    return jsonb_build_object('success',false,'message','Invalid status.');
  end if;

  v_verified := p_status='verified' and coalesce(p_name_match,false)
    and coalesce(p_face_match,false) and coalesce(p_liveness_passed,false);

  if p_status='verified' and not v_verified then
    return jsonb_build_object('success',false,'message','Verification cannot be marked verified unless ID/name match, face match and liveness all pass.');
  end if;

  insert into public.identity_verifications(
    user_id,role,status,provider,provider_reference,name_match,face_match,
    liveness_passed,updated_at,verified_at,rejection_reason
  ) values (
    p_user_id,p_role,p_status,p_provider,p_provider_reference,p_name_match,
    p_face_match,p_liveness_passed,now(),case when v_verified then now() else null end,
    nullif(trim(coalesce(p_rejection_reason,'')),'')
  )
  on conflict(user_id) do update set
    role=excluded.role,status=case when v_verified then 'verified' else excluded.status end,
    provider=excluded.provider,provider_reference=excluded.provider_reference,
    name_match=excluded.name_match,face_match=excluded.face_match,
    liveness_passed=excluded.liveness_passed,updated_at=now(),
    verified_at=case when v_verified then now() else null end,
    rejection_reason=excluded.rejection_reason;

  if p_role='creator' then
    update public.creator_profiles
      set identity_status=case when v_verified then 'verified' else p_status end,
          identity_provider=p_provider,
          identity_reference=p_provider_reference,
          identity_verified_at=case when v_verified then now() else null end,
          identity_rejection_reason=nullif(trim(coalesce(p_rejection_reason,'')),'') ,
          -- A creator must not remain publicly active if identity verification fails.
          profile_status=case when v_verified then profile_status else 'inactive' end,
          updated_at=now()
      where user_id=p_user_id;
  end if;

  return jsonb_build_object('success',true,'verified',v_verified);
end;
$$;
revoke all on function public.complete_identity_verification(uuid,text,text,text,boolean,boolean,boolean,text,text) from public, anon, authenticated;

-- SECURITY GATE: booking creation is allowed only when BOTH customer and creator
-- have completed identity verification. This is enforced server-side in the RPC.
drop function if exists public.can_user_book(uuid);
create or replace function public.can_user_book(p_creator_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_customer_verified boolean;
  v_creator_verified boolean;
  v_subscription boolean;
begin
  select exists(
    select 1 from public.identity_verifications
    where user_id=auth.uid() and role='customer' and status='verified'
      and coalesce(name_match,false) and coalesce(face_match,false) and coalesce(liveness_passed,false)
  ) into v_customer_verified;

  select exists(
    select 1 from public.identity_verifications
    where user_id=p_creator_user_id and role='creator' and status='verified'
      and coalesce(name_match,false) and coalesce(face_match,false) and coalesce(liveness_passed,false)
  ) into v_creator_verified;

  select exists(
    select 1 from public.subscriptions
    where user_id=auth.uid() and status='active'
      and (expires_at is null or expires_at>now())
  ) into v_subscription;

  return jsonb_build_object(
    'allowed',v_customer_verified and v_creator_verified and v_subscription,
    'customer_verified',v_customer_verified,
    'creator_verified',v_creator_verified,
    'active_subscription',v_subscription
  );
end;
$$;
revoke execute on function public.can_user_book(uuid) from public, anon;
grant execute on function public.can_user_book(uuid) to authenticated;

-- Existing active creators are forced through identity verification before they
-- can be shown as active again. Existing payment records are not deleted.
update public.creator_profiles
set profile_status='inactive', identity_status='unverified', updated_at=now()
where profile_status='active';

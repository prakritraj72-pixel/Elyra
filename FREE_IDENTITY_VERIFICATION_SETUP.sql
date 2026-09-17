-- ELYRA — FREE / MANUAL IDENTITY VERIFICATION
-- Phase 1: no paid KYC provider required.
-- Users upload a government-ID image and a selfie.
-- An authorized Elyra admin manually reviews both and marks the record verified/rejected.
-- IMPORTANT: This is NOT automated KYC, biometric liveness, or government verification.
-- Do not describe a manually reviewed upload as provider/KYC verified.
-- Keep the bucket private and delete documents when no longer needed.

-- 1) Identity status columns for creator profiles.
alter table public.creator_profiles
  add column if not exists identity_status text default 'unverified',
  add column if not exists identity_provider text,
  add column if not exists identity_reference text,
  add column if not exists identity_verified_at timestamptz,
  add column if not exists identity_rejection_reason text;

-- Keep creator identity states controlled.
drop constraint if exists creator_profiles_identity_status_check on public.creator_profiles;
alter table public.creator_profiles
  add constraint creator_profiles_identity_status_check
  check (identity_status in ('unverified','pending','verified','rejected'));

-- 2) Identity verification records.
create table if not exists public.identity_verifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references auth.users(id) on delete cascade,
  role text not null check (role in ('customer','creator')),
  status text not null default 'unverified' check (status in ('unverified','pending','verified','rejected')),
  provider text,
  provider_reference text,
  document_type text,
  masked_document text,
  name_match boolean,
  face_match boolean,
  liveness_passed boolean,
  id_document_path text,
  selfie_path text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  verified_at timestamptz,
  rejection_reason text
);

alter table public.identity_verifications enable row level security;
revoke all on public.identity_verifications from anon, authenticated;

-- 3) Private storage bucket.
insert into storage.buckets (id, name, public)
values ('identity-documents', 'identity-documents', false)
on conflict (id) do update set public=false;

-- Users may upload/delete only inside their own UUID folder.
drop policy if exists "Identity users upload own files" on storage.objects;
create policy "Identity users upload own files"
on storage.objects for insert to authenticated
with check (
  bucket_id='identity-documents'
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists "Identity users read own files" on storage.objects;
create policy "Identity users read own files"
on storage.objects for select to authenticated
using (
  bucket_id='identity-documents'
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists "Identity users delete own files" on storage.objects;
create policy "Identity users delete own files"
on storage.objects for delete to authenticated
using (
  bucket_id='identity-documents'
  and (storage.foldername(name))[1] = auth.uid()::text
);

-- Only the Elyra admin can read submitted identity files for manual review.
drop policy if exists "Identity admin read files" on storage.objects;
create policy "Identity admin read files"
on storage.objects for select to authenticated
using (
  bucket_id='identity-documents'
  and auth.uid() = '2b6e3748-1702-4cdc-b38d-b826577af65a'::uuid
);

-- 4) User submission RPC.
drop function if exists public.start_manual_identity_verification(text,text,text,text);
create or replace function public.start_manual_identity_verification(
  p_role text,
  p_id_document_path text,
  p_selfie_path text,
  p_document_type text default 'government_id'
)
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
  if coalesce(trim(p_id_document_path),'') = '' or coalesce(trim(p_selfie_path),'') = '' then
    return jsonb_build_object('success',false,'message','Both ID document and selfie are required.');
  end if;
  if split_part(p_id_document_path,'/',1) <> v_user::text or split_part(p_selfie_path,'/',1) <> v_user::text then
    return jsonb_build_object('success',false,'message','Invalid file ownership.');
  end if;

  insert into public.identity_verifications(
    user_id,role,status,provider,provider_reference,document_type,
    id_document_path,selfie_path,updated_at,verified_at,rejection_reason,
    name_match,face_match,liveness_passed
  ) values (
    v_user,p_role,'pending','manual_admin',null,p_document_type,
    p_id_document_path,p_selfie_path,now(),null,null,null,null,null
  )
  on conflict(user_id) do update set
    role=excluded.role,
    status='pending',
    provider='manual_admin',
    provider_reference=null,
    document_type=excluded.document_type,
    id_document_path=excluded.id_document_path,
    selfie_path=excluded.selfie_path,
    updated_at=now(),
    verified_at=null,
    rejection_reason=null,
    name_match=null,
    face_match=null,
    liveness_passed=null;

  if p_role='creator' then
    update public.creator_profiles
    set identity_status='pending',
        identity_provider='manual_admin',
        identity_reference=null,
        identity_verified_at=null,
        identity_rejection_reason=null,
        updated_at=now()
    where user_id=v_user;
  end if;

  return jsonb_build_object('success',true,'message','Verification submitted for admin review.');
end;
$$;
revoke execute on function public.start_manual_identity_verification(text,text,text,text) from public, anon;
grant execute on function public.start_manual_identity_verification(text,text,text,text) to authenticated;

-- 5) Logged-in user's safe verification status.
drop function if exists public.my_identity_status();
create or replace function public.my_identity_status()
returns table(status text, role text, provider text, verified_at timestamptz, rejection_reason text)
language sql
security definer
set search_path=public,auth
as $$
  select status,role,provider,verified_at,rejection_reason
  from public.identity_verifications
  where user_id=auth.uid();
$$;
revoke execute on function public.my_identity_status() from public, anon;
grant execute on function public.my_identity_status() to authenticated;

-- 6) Admin review queue.
drop function if exists public.admin_list_identity_verifications();
create or replace function public.admin_list_identity_verifications()
returns table(
  id uuid,user_id uuid,role text,status text,document_type text,
  id_document_path text,selfie_path text,created_at timestamptz,
  updated_at timestamptz,rejection_reason text,user_email text
)
language plpgsql
security definer
set search_path=public,auth
as $$
begin
  if auth.uid() <> '2b6e3748-1702-4cdc-b38d-b826577af65a'::uuid then
    raise exception 'Admin access required';
  end if;
  return query
  select i.id,i.user_id,i.role,i.status,i.document_type,i.id_document_path,
         i.selfie_path,i.created_at,i.updated_at,i.rejection_reason,
         coalesce(u.email,'')::text
  from public.identity_verifications i
  left join auth.users u on u.id=i.user_id
  order by case when i.status='pending' then 0 else 1 end, i.created_at desc;
end;
$$;
revoke execute on function public.admin_list_identity_verifications() from public, anon;
grant execute on function public.admin_list_identity_verifications() to authenticated;

-- 7) Admin approve/reject.
drop function if exists public.admin_review_identity_verification(uuid,text,text);
create or replace function public.admin_review_identity_verification(
  p_id uuid,
  p_status text,
  p_rejection_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth
as $$
declare
  v identity_verifications%rowtype;
begin
  if auth.uid() <> '2b6e3748-1702-4cdc-b38d-b826577af65a'::uuid then
    return jsonb_build_object('success',false,'message','Admin access required.');
  end if;
  if p_status not in ('verified','rejected') then
    return jsonb_build_object('success',false,'message','Status must be verified or rejected.');
  end if;

  select * into v from public.identity_verifications where id=p_id;
  if not found then
    return jsonb_build_object('success',false,'message','Verification request not found.');
  end if;

  if p_status='verified' and (coalesce(v.id_document_path,'')='' or coalesce(v.selfie_path,'')='') then
    return jsonb_build_object('success',false,'message','Both ID and selfie must be uploaded before approval.');
  end if;

  update public.identity_verifications
  set status=p_status,
      provider='manual_admin',
      provider_reference=null,
      name_match=null,
      face_match=null,
      liveness_passed=null,
      verified_at=case when p_status='verified' then now() else null end,
      rejection_reason=nullif(trim(coalesce(p_rejection_reason,'')),''),
      updated_at=now()
  where id=p_id;

  if v.role='creator' then
    update public.creator_profiles cp
    set identity_status=p_status,
        identity_provider='manual_admin',
        identity_reference=v.id::text,
        identity_verified_at=case when p_status='verified' then now() else null end,
        identity_rejection_reason=nullif(trim(coalesce(p_rejection_reason,'')),''),
        profile_status=case
          when p_status='verified' and coalesce(cp.activation_payment_status,'')='paid' then 'active'
          else 'inactive'
        end,
        updated_at=now()
    where cp.user_id=v.user_id;
  end if;

  return jsonb_build_object('success',true,'status',p_status);
end;
$$;
revoke execute on function public.admin_review_identity_verification(uuid,text,text) from public, anon;
grant execute on function public.admin_review_identity_verification(uuid,text,text) to authenticated;

-- 8) Booking gate: active subscription + verified customer + verified creator.
drop function if exists public.can_user_book(uuid);
create or replace function public.can_user_book(p_creator_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public,auth
as $$
declare
  v_customer_verified boolean;
  v_creator_verified boolean;
  v_subscription boolean;
begin
  select exists(
    select 1 from public.identity_verifications
    where user_id=auth.uid() and role='customer' and status='verified'
  ) into v_customer_verified;

  select exists(
    select 1 from public.identity_verifications
    where user_id=p_creator_user_id and role='creator' and status='verified'
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

-- 9) Enforce the booking gate in the database, not only in browser JavaScript.
drop policy if exists "Users can create bookings" on public.bookings;
drop policy if exists "Customers can create bookings" on public.bookings;
create policy "Customers can create bookings"
on public.bookings
for insert
to authenticated
with check (
  customer_id=auth.uid()
  and (public.can_user_book(creator_id)->>'allowed')::boolean = true
);

-- IMPORTANT:
-- This manual system is not automated KYC/liveness/biometric verification.
-- Admin approval means the admin reviewed the submitted files; it must not be marketed as Aadhaar/KYC/provider verified.

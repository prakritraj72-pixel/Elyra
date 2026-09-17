-- ELYRA CREATOR ACTIVATION GATE
-- Run once in Supabase SQL Editor AFTER the identity verification SQL is installed.
-- A creator becomes LIVE only when BOTH conditions are true:
-- 1) ₹20 activation payment is approved
-- 2) identity verification is approved (identity + age verified)

create or replace function public.sync_creator_activation(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_identity_ok boolean := false;
  v_payment_ok boolean := false;
  v_profile_id uuid;
begin
  select cp.id into v_profile_id
  from public.creator_profiles cp
  where cp.user_id = p_user_id
  limit 1;

  if v_profile_id is null then
    return;
  end if;

  select exists (
    select 1
    from public.identity_verifications iv
    where iv.user_id = p_user_id
      and iv.verification_status = 'verified'
      and iv.identity_verified = true
      and iv.age_verified = true
  ) into v_identity_ok;

  select exists (
    select 1
    from public.creator_profiles cp
    where cp.id = v_profile_id
      and cp.activation_payment_status = 'paid'
  ) into v_payment_ok;

  update public.creator_profiles
  set profile_status = case when v_identity_ok and v_payment_ok then 'active' else 'inactive' end,
      updated_at = now()
  where id = v_profile_id;
end;
$$;

revoke execute on function public.sync_creator_activation(uuid) from public, anon;
grant execute on function public.sync_creator_activation(uuid) to authenticated;

-- Replace creator activation admin review so payment approval alone cannot make a profile live.
create or replace function public.admin_review_creator_activation(
  p_request_id uuid,
  p_action text,
  p_rejection_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_request public.creator_activation_payment_requests%rowtype;
  v_identity_ok boolean := false;
begin
  if auth.uid() <> '2b6e3748-1702-4cdc-b38d-b826577af65a'::uuid then
    return jsonb_build_object('success',false,'message','Access denied.');
  end if;

  select * into v_request
  from public.creator_activation_payment_requests
  where id=p_request_id
  for update;

  if not found then
    return jsonb_build_object('success',false,'message','Payment request not found.');
  end if;
  if v_request.status <> 'pending' then
    return jsonb_build_object('success',false,'message','This request has already been reviewed.');
  end if;

  if p_action='reject' then
    update public.creator_activation_payment_requests
      set status='rejected', reviewed_at=now(), reviewed_by=auth.uid(),
          rejection_reason=nullif(trim(coalesce(p_rejection_reason,'')),'')
    where id=p_request_id;
    return jsonb_build_object('success',true,'status','rejected');
  end if;

  if p_action <> 'approve' then
    return jsonb_build_object('success',false,'message','Invalid review action.');
  end if;

  update public.creator_activation_payment_requests
    set status='approved', reviewed_at=now(), reviewed_by=auth.uid()
  where id=p_request_id;

  update public.creator_profiles
    set activation_payment_status='paid', updated_at=now()
  where id=v_request.creator_profile_id;

  select exists (
    select 1 from public.identity_verifications iv
    where iv.user_id=v_request.user_id
      and iv.verification_status='verified'
      and iv.identity_verified=true
      and iv.age_verified=true
  ) into v_identity_ok;

  update public.creator_profiles
    set profile_status = case when v_identity_ok then 'active' else 'inactive' end,
        updated_at=now()
  where id=v_request.creator_profile_id;

  return jsonb_build_object(
    'success',true,
    'status','approved',
    'identity_verified',v_identity_ok,
    'profile_active',v_identity_ok
  );
end;
$$;
revoke execute on function public.admin_review_creator_activation(uuid,text,text) from public, anon;
grant execute on function public.admin_review_creator_activation(uuid,text,text) to authenticated;

-- Replace identity approval so approving identity can automatically make an already-paid creator live.
create or replace function public.admin_review_identity_verification(
  p_verification_id uuid,
  p_decision text,
  p_rejection_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_user uuid;
  v_creator_id uuid;
  v_payment_paid boolean := false;
begin
  if auth.uid() <> '2b6e3748-1702-4cdc-b38d-b826577af65a'::uuid then
    return jsonb_build_object('success',false,'message','Unauthorized.');
  end if;

  if p_decision not in ('approved','rejected') then
    return jsonb_build_object('success',false,'message','Invalid decision.');
  end if;

  select user_id into v_user
  from public.identity_verifications
  where id=p_verification_id and verification_status='pending';

  if v_user is null then
    return jsonb_build_object('success',false,'message','Verification request not found or already reviewed.');
  end if;

  if p_decision='approved' then
    update public.identity_verifications
    set verification_status='verified', identity_verified=true, age_verified=true,
        provider='manual', rejection_reason=null, verified_at=now(), expires_at=null, updated_at=now()
    where id=p_verification_id;

    select cp.id into v_creator_id
    from public.creator_profiles cp
    where cp.user_id=v_user
    limit 1;

    if v_creator_id is not null then
      select exists(
        select 1 from public.creator_profiles cp
        where cp.id=v_creator_id and cp.activation_payment_status='paid'
      ) into v_payment_paid;

      update public.creator_profiles
      set profile_status=case when v_payment_paid then 'active' else 'inactive' end,
          updated_at=now()
      where id=v_creator_id;
    end if;

    return jsonb_build_object('success',true,'message','Identity verification approved.','creator_activated',v_payment_paid);
  else
    update public.identity_verifications
    set verification_status='rejected', identity_verified=false, age_verified=false,
        rejection_reason=nullif(trim(coalesce(p_rejection_reason,'')),''), verified_at=null, updated_at=now()
    where id=p_verification_id;

    select cp.id into v_creator_id
    from public.creator_profiles cp where cp.user_id=v_user limit 1;

    if v_creator_id is not null then
      update public.creator_profiles
      set profile_status='inactive', updated_at=now()
      where id=v_creator_id;
    end if;

    return jsonb_build_object('success',true,'message','Identity verification rejected.');
  end if;
end;
$$;
revoke execute on function public.admin_review_identity_verification(uuid,text,text) from public, anon;
grant execute on function public.admin_review_identity_verification(uuid,text,text) to authenticated;

-- ELYRA IDENTITY + BOOKING ENFORCEMENT
-- Run AFTER IDENTITY_VERIFICATION_SETUP.sql.
-- This is the server-side safety gate: UI checks are not trusted.

-- A booking can only be inserted when:
-- 1) customer has active subscription
-- 2) customer identity is verified (ID/name + face match + liveness)
-- 3) creator identity is verified (ID/name + face match + liveness)
-- 4) creator profile is active

create or replace function public.enforce_verified_booking()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_customer_ok boolean;
  v_creator_ok boolean;
  v_subscription_ok boolean;
  v_creator_active boolean;
begin
  if new.customer_id is null or new.creator_id is null then
    raise exception 'Customer and creator are required.';
  end if;

  select exists(
    select 1 from public.subscriptions s
    where s.user_id=new.customer_id
      and s.status='active'
      and (s.expires_at is null or s.expires_at>now())
  ) into v_subscription_ok;

  select exists(
    select 1 from public.identity_verifications v
    where v.user_id=new.customer_id
      and v.role='customer'
      and v.status='verified'
      and coalesce(v.name_match,false)
      and coalesce(v.face_match,false)
      and coalesce(v.liveness_passed,false)
  ) into v_customer_ok;

  select exists(
    select 1 from public.identity_verifications v
    where v.user_id=new.creator_id
      and v.role='creator'
      and v.status='verified'
      and coalesce(v.name_match,false)
      and coalesce(v.face_match,false)
      and coalesce(v.liveness_passed,false)
  ) into v_creator_ok;

  select exists(
    select 1 from public.creator_profiles cp
    where cp.user_id=new.creator_id
      and cp.profile_status='active'
      and coalesce(cp.identity_status,'unverified')='verified'
  ) into v_creator_active;

  if not v_subscription_ok then
    raise exception 'An active Elyra subscription is required before booking.';
  end if;
  if not v_customer_ok then
    raise exception 'Identity verification is required before booking. Please complete government-ID and live-face verification.';
  end if;
  if not v_creator_ok or not v_creator_active then
    raise exception 'This creator is not identity verified and available for booking.';
  end if;

  return new;
end;
$$;

drop trigger if exists enforce_verified_booking on public.bookings;
create trigger enforce_verified_booking
before insert on public.bookings
for each row
execute function public.enforce_verified_booking();

-- Update the creator activation review function so admin approval cannot bypass KYC.
drop function if exists public.admin_review_creator_activation(uuid,text,text);
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
  v_identity text;
begin
  if auth.uid()<>'2b6e3748-1702-4cdc-b38d-b826577af65a'::uuid then
    return jsonb_build_object('success',false,'message','Access denied.');
  end if;

  select * into v_request from public.creator_activation_payment_requests
  where id=p_request_id for update;
  if not found then return jsonb_build_object('success',false,'message','Payment request not found.'); end if;
  if v_request.status<>'pending' then return jsonb_build_object('success',false,'message','This request has already been reviewed.'); end if;

  if p_action='reject' then
    update public.creator_activation_payment_requests
      set status='rejected',reviewed_at=now(),reviewed_by=auth.uid(),
          rejection_reason=nullif(trim(coalesce(p_rejection_reason,'')),'')
      where id=p_request_id;
    return jsonb_build_object('success',true,'status','rejected');
  end if;

  if p_action<>'approve' then return jsonb_build_object('success',false,'message','Invalid review action.'); end if;

  select coalesce(identity_status,'unverified') into v_identity
  from public.creator_profiles where id=v_request.creator_profile_id;

  if v_identity<>'verified' then
    return jsonb_build_object('success',false,'message','Creator identity verification must pass before activation.');
  end if;

  update public.creator_profiles
    set activation_payment_status='paid',profile_status='active',updated_at=now()
  where id=v_request.creator_profile_id;

  update public.creator_activation_payment_requests
    set status='approved',reviewed_at=now(),reviewed_by=auth.uid()
  where id=p_request_id;

  return jsonb_build_object('success',true,'status','approved');
end;
$$;
revoke execute on function public.admin_review_creator_activation(uuid,text,text) from public, anon;
grant execute on function public.admin_review_creator_activation(uuid,text,text) to authenticated;

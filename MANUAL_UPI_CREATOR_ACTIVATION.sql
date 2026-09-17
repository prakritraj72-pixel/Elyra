-- ELYRA MANUAL UPI CREATOR ACTIVATION
-- Run this whole file once in Supabase SQL Editor.
-- Creator pays ₹20 by UPI, submits UTR, and only the admin can approve/reject.

create table if not exists public.creator_activation_payment_requests (
  id uuid primary key default gen_random_uuid(),
  creator_profile_id uuid not null references public.creator_profiles(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  amount numeric(10,2) not null default 20 check (amount = 20),
  transaction_id text not null,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id),
  rejection_reason text
);

create unique index if not exists creator_activation_payment_requests_transaction_idx
  on public.creator_activation_payment_requests (lower(transaction_id));
create unique index if not exists creator_activation_payment_requests_pending_creator_idx
  on public.creator_activation_payment_requests (creator_profile_id)
  where status = 'pending';
create index if not exists creator_activation_payment_requests_status_idx
  on public.creator_activation_payment_requests (status, created_at desc);

alter table public.creator_activation_payment_requests enable row level security;
revoke all on table public.creator_activation_payment_requests from anon, authenticated;

-- Creator submits a UTR.
drop function if exists public.submit_creator_activation_payment(text);
create or replace function public.submit_creator_activation_payment(p_transaction_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_user uuid := auth.uid();
  v_profile public.creator_profiles%rowtype;
  v_id uuid;
begin
  if v_user is null then
    return jsonb_build_object('success',false,'message','Please sign in first.');
  end if;

  select * into v_profile
  from public.creator_profiles
  where user_id = v_user
  limit 1;

  if not found then
    return jsonb_build_object('success',false,'message','Creator profile not found.');
  end if;

  if v_profile.activation_payment_status = 'paid'
     or v_profile.profile_status = 'active' then
    return jsonb_build_object('success',false,'message','Your creator profile is already activated.');
  end if;

  if length(trim(coalesce(p_transaction_id,''))) < 6 then
    return jsonb_build_object('success',false,'message','Please enter a valid transaction ID / UTR.');
  end if;

  if exists (
    select 1 from public.creator_activation_payment_requests r
    where lower(r.transaction_id) = lower(trim(p_transaction_id))
  ) then
    return jsonb_build_object('success',false,'message','This transaction ID has already been submitted.');
  end if;

  if exists (
    select 1 from public.creator_activation_payment_requests r
    where r.creator_profile_id = v_profile.id and r.status = 'pending'
  ) then
    return jsonb_build_object('success',false,'message','You already have a pending activation payment request.');
  end if;

  insert into public.creator_activation_payment_requests
    (creator_profile_id,user_id,amount,transaction_id)
  values
    (v_profile.id,v_user,20,trim(p_transaction_id))
  returning id into v_id;

  return jsonb_build_object('success',true,'request_id',v_id,'message','Activation payment request submitted.');
end;
$$;
revoke execute on function public.submit_creator_activation_payment(text) from public, anon;
grant execute on function public.submit_creator_activation_payment(text) to authenticated;

-- Creator can view only their own activation payment history.
drop function if exists public.creator_activation_payment_history();
create or replace function public.creator_activation_payment_history()
returns table (
  id uuid,
  amount numeric,
  transaction_id text,
  status text,
  created_at timestamptz,
  reviewed_at timestamptz,
  rejection_reason text
)
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if auth.uid() is null then raise exception 'Please sign in first'; end if;
  return query
  select r.id,r.amount,r.transaction_id,r.status,r.created_at,r.reviewed_at,r.rejection_reason
  from public.creator_activation_payment_requests r
  where r.user_id = auth.uid()
  order by r.created_at desc;
end;
$$;
revoke execute on function public.creator_activation_payment_history() from public, anon;
grant execute on function public.creator_activation_payment_history() to authenticated;

-- Admin list.
drop function if exists public.admin_list_creator_activation_requests();
create or replace function public.admin_list_creator_activation_requests()
returns table (
  id uuid,
  creator_profile_id uuid,
  user_id uuid,
  user_email text,
  creator_name text,
  city text,
  amount numeric,
  transaction_id text,
  status text,
  created_at timestamptz,
  reviewed_at timestamptz,
  rejection_reason text
)
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if auth.uid() <> '2b6e3748-1702-4cdc-b38d-b826577af65a'::uuid then
    raise exception 'Access denied';
  end if;
  return query
  select r.id,r.creator_profile_id,r.user_id,u.email::text,
         cp.display_name,cp.city,r.amount,r.transaction_id,r.status,
         r.created_at,r.reviewed_at,r.rejection_reason
  from public.creator_activation_payment_requests r
  left join auth.users u on u.id=r.user_id
  left join public.creator_profiles cp on cp.id=r.creator_profile_id
  order by r.created_at desc;
end;
$$;
revoke execute on function public.admin_list_creator_activation_requests() from public, anon;
grant execute on function public.admin_list_creator_activation_requests() to authenticated;

-- Admin approves/rejects. Approval is the only path that activates the creator.
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
      set status='rejected',reviewed_at=now(),reviewed_by=auth.uid(),
          rejection_reason=nullif(trim(coalesce(p_rejection_reason,'')),'')
    where id=p_request_id;
    return jsonb_build_object('success',true,'status','rejected');
  end if;

  if p_action <> 'approve' then
    return jsonb_build_object('success',false,'message','Invalid review action.');
  end if;

  update public.creator_profiles
    set activation_payment_status='paid',profile_status='active',updated_at=now()
  where id=v_request.creator_profile_id;

  if not found then
    return jsonb_build_object('success',false,'message','Creator profile not found.');
  end if;

  update public.creator_activation_payment_requests
    set status='approved',reviewed_at=now(),reviewed_by=auth.uid()
  where id=p_request_id;

  return jsonb_build_object('success',true,'status','approved');
end;
$$;
revoke execute on function public.admin_review_creator_activation(uuid,text,text) from public, anon;
grant execute on function public.admin_review_creator_activation(uuid,text,text) to authenticated;

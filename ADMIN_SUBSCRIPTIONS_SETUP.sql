-- ELYRA ADMIN SUBSCRIPTIONS SETUP
-- Adds the missing admin subscription list/cancel RPCs.
-- Run once in Supabase SQL Editor.

-- Admin: list all subscriptions

drop function if exists public.admin_list_subscriptions();

create or replace function public.admin_list_subscriptions()
returns table (
  id uuid,
  user_id uuid,
  plan text,
  amount numeric,
  status text,
  started_at timestamptz,
  expires_at timestamptz,
  payment_id text,
  payment_provider text
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
  select
    s.id,
    s.user_id,
    s.plan,
    s.amount,
    s.status,
    s.started_at,
    s.expires_at,
    s.payment_id,
    s.payment_provider
  from public.subscriptions s
  order by s.created_at desc nulls last, s.started_at desc nulls last;
end;
$$;

revoke execute on function public.admin_list_subscriptions() from public, anon;
grant execute on function public.admin_list_subscriptions() to authenticated;


-- Admin: cancel an active subscription

drop function if exists public.admin_cancel_subscription(uuid);

create or replace function public.admin_cancel_subscription(
  p_subscription_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if auth.uid() <> '2b6e3748-1702-4cdc-b38d-b826577af65a'::uuid then
    return jsonb_build_object('success',false,'message','Access denied.');
  end if;

  update public.subscriptions
  set status = 'cancelled'
  where id = p_subscription_id
    and status = 'active';

  if not found then
    return jsonb_build_object('success',false,'message','Active subscription not found.');
  end if;

  return jsonb_build_object('success',true,'status','cancelled');
end;
$$;

revoke execute on function public.admin_cancel_subscription(uuid) from public, anon;
grant execute on function public.admin_cancel_subscription(uuid) to authenticated;


-- Customer: secure payment history

drop function if exists public.subscription_payment_history();

create or replace function public.subscription_payment_history()
returns table (
  id uuid,
  plan text,
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
  if auth.uid() is null then
    raise exception 'Please sign in first';
  end if;

  return query
  select
    r.id,
    r.plan,
    r.amount,
    r.transaction_id,
    r.status,
    r.created_at,
    r.reviewed_at,
    r.rejection_reason
  from public.subscription_payment_requests r
  where r.user_id = auth.uid()
  order by r.created_at desc;
end;
$$;

revoke execute on function public.subscription_payment_history() from public, anon;
grant execute on function public.subscription_payment_history() to authenticated;

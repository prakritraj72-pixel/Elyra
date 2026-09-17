-- ELYRA subscription pricing update
-- Run after MANUAL_UPI_SUBSCRIPTIONS.sql
-- Final pricing: 1 Month ₹199, 1 Year ₹699

alter table public.subscription_payment_requests
  drop constraint if exists subscription_payment_requests_amount_check;
alter table public.subscription_payment_requests
  add constraint subscription_payment_requests_amount_check check (amount in (199,699));

drop function if exists public.submit_subscription_payment(text,text);
create or replace function public.submit_subscription_payment(p_plan text,p_transaction_id text)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare v_user uuid:=auth.uid(); v_amount numeric(10,2); v_id uuid;
begin
 if v_user is null then return jsonb_build_object('success',false,'message','Please sign in first.'); end if;
 if p_plan='monthly' then v_amount:=199; elsif p_plan='yearly' then v_amount:=699; else return jsonb_build_object('success',false,'message','Invalid subscription plan.'); end if;
 if length(trim(coalesce(p_transaction_id,'')))<6 then return jsonb_build_object('success',false,'message','Please enter a valid transaction ID / UTR.'); end if;
 if exists(select 1 from public.subscriptions s where s.user_id=v_user and s.status='active' and (s.expires_at is null or s.expires_at>now())) then return jsonb_build_object('success',false,'message','You already have an active subscription.'); end if;
 if exists(select 1 from public.subscription_payment_requests r where lower(r.transaction_id)=lower(trim(p_transaction_id))) then return jsonb_build_object('success',false,'message','This transaction ID has already been submitted.'); end if;
 insert into public.subscription_payment_requests(user_id,plan,amount,transaction_id) values(v_user,p_plan,v_amount,trim(p_transaction_id)) returning id into v_id;
 return jsonb_build_object('success',true,'request_id',v_id,'message','Payment request submitted.');
end;$$;
revoke execute on function public.submit_subscription_payment(text,text) from public,anon;
grant execute on function public.submit_subscription_payment(text,text) to authenticated;

drop function if exists public.admin_review_subscription_payment(uuid,text,text);
create or replace function public.admin_review_subscription_payment(p_request_id uuid,p_action text,p_rejection_reason text default null)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare v_request public.subscription_payment_requests%rowtype; v_started timestamptz:=now(); v_expires timestamptz; v_subscription_id uuid;
begin
 if auth.uid()<>'2b6e3748-1702-4cdc-b38d-b826577af65a'::uuid then return jsonb_build_object('success',false,'message','Access denied.'); end if;
 select * into v_request from public.subscription_payment_requests where id=p_request_id for update;
 if not found then return jsonb_build_object('success',false,'message','Payment request not found.'); end if;
 if v_request.status<>'pending' then return jsonb_build_object('success',false,'message','This request has already been reviewed.'); end if;
 if p_action='reject' then update public.subscription_payment_requests set status='rejected',reviewed_at=now(),reviewed_by=auth.uid(),rejection_reason=nullif(trim(coalesce(p_rejection_reason,'')),'') where id=p_request_id; return jsonb_build_object('success',true,'status','rejected'); end if;
 if p_action<>'approve' then return jsonb_build_object('success',false,'message','Invalid review action.'); end if;
 if exists(select 1 from public.subscriptions s where s.user_id=v_request.user_id and s.status='active' and (s.expires_at is null or s.expires_at>now())) then return jsonb_build_object('success',false,'message','This user already has an active subscription.'); end if;
 if v_request.plan='monthly' then v_expires:=v_started+interval '1 month'; else v_expires:=v_started+interval '1 year'; end if;
 insert into public.subscriptions(user_id,plan,amount,status,started_at,expires_at,payment_id,payment_provider) values(v_request.user_id,v_request.plan,v_request.amount,'active',v_started,v_expires,v_request.transaction_id,'manual_upi') returning id into v_subscription_id;
 update public.subscription_payment_requests set status='approved',reviewed_at=now(),reviewed_by=auth.uid() where id=p_request_id;
 return jsonb_build_object('success',true,'status','approved','subscription_id',v_subscription_id);
end;$$;
revoke execute on function public.admin_review_subscription_payment(uuid,text,text) from public,anon;
grant execute on function public.admin_review_subscription_payment(uuid,text,text) to authenticated;

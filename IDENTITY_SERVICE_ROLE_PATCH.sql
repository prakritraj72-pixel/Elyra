-- Allow only Supabase service_role (used by trusted Edge Functions) to call the
-- internal verification completion function. Normal users remain blocked.
grant execute on function public.complete_identity_verification(uuid,text,text,text,boolean,boolean,boolean,text,text) to service_role;

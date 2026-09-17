// ELYRA — server-side identity verification starter
// Deploy as a Supabase Edge Function.
// Required secrets: CASHFREE_CLIENT_ID, CASHFREE_CLIENT_SECRET, CASHFREE_KYC_TEMPLATE
// The Cashfree secret must NEVER be placed in GitHub Pages/frontend code.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Content-Type': 'application/json',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  try {
    const auth = req.headers.get('Authorization')
    if (!auth) return new Response(JSON.stringify({ success:false, message:'Sign in required.' }), { status:401, headers:cors })

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!
    const adminKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const cfId = Deno.env.get('CASHFREE_CLIENT_ID')
    const cfSecret = Deno.env.get('CASHFREE_CLIENT_SECRET')
    const template = Deno.env.get('CASHFREE_KYC_TEMPLATE') || 'Aadhaar_verification'
    if (!cfId || !cfSecret) throw new Error('Identity verification provider is not configured.')

    const userClient = createClient(supabaseUrl, anonKey, { global:{ headers:{ Authorization:auth } } })
    const { data:{ user }, error:userError } = await userClient.auth.getUser()
    if (userError || !user) return new Response(JSON.stringify({ success:false, message:'Invalid session.' }), { status:401, headers:cors })

    const body = await req.json().catch(() => ({}))
    const role = body?.role === 'creator' ? 'creator' : 'customer'
    const verificationId = `elyra_${role}_${user.id}_${Date.now()}`
    const phone = String(user.phone || user.user_metadata?.phone || '').replace(/\D/g,'').slice(-10)
    if (phone.length !== 10) throw new Error('A verified 10-digit mobile number is required before identity verification.')

    const admin = createClient(supabaseUrl, adminKey)
    const { error:pendingError } = await admin.from('identity_verifications').upsert({
      user_id:user.id, role, status:'pending', provider:'cashfree_secure_id',
      provider_reference:verificationId, updated_at:new Date().toISOString(), rejection_reason:null
    }, { onConflict:'user_id' })
    if (pendingError) throw pendingError

    const response = await fetch('https://api.cashfree.com/verification/form', {
      method:'POST',
      headers:{ 'Content-Type':'application/json', 'x-client-id':cfId, 'x-client-secret':cfSecret },
      body:JSON.stringify({
        phone,
        template_name:template,
        verification_id:verificationId,
        name:user.user_metadata?.full_name || user.user_metadata?.name || undefined,
        email:user.email || undefined,
        link_expiry:new Date(Date.now()+24*60*60*1000).toISOString().slice(0,10),
        notification_types:[]
      })
    })
    const result = await response.json().catch(()=>null)
    if (!response.ok || !result?.form_link) throw new Error(result?.message || 'Cashfree could not create the verification link.')

    return new Response(JSON.stringify({ success:true, form_link:result.form_link, verification_id:verificationId }), { status:200, headers:cors })
  } catch (e) {
    return new Response(JSON.stringify({ success:false, message:e instanceof Error ? e.message : 'Unable to start verification.' }), { status:500, headers:cors })
  }
})

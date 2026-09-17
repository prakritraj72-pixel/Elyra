// ELYRA — sync provider verification result into Supabase.
// Required secrets: CASHFREE_CLIENT_ID, CASHFREE_CLIENT_SECRET, SUPABASE_SERVICE_ROLE_KEY.
// This function is deliberately fail-closed: it marks a user verified only when
// the provider response explicitly contains successful identity/name, face and
// liveness checks. If the configured Cashfree template does not return all three,
// the user remains pending and booking stays blocked.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Content-Type': 'application/json',
}

function okStatus(value:any){ return ['SUCCESS','VALID','VERIFIED','APPROVED','COMPLETED'].includes(String(value||'').toUpperCase()) }
function findChecks(details:any[]){
  const text = details.map(x => JSON.stringify(x).toUpperCase()).join(' ')
  return {
    name: /NAME.?MATCH|IDENTITY.?MATCH|AADHAAR.*SUCCESS|PAN.*SUCCESS/.test(text) && okStatus(details.find(x => /NAME.?MATCH|IDENTITY.?MATCH/i.test(JSON.stringify(x)))?.status || 'SUCCESS'),
    face: /FACE.?MATCH/.test(text) && !/FACE.?MATCH[^}]{0,150}(FAILED|REJECTED|INVALID)/.test(text),
    liveness: /LIVENESS/.test(text) && !/LIVENESS[^}]{0,150}(FAILED|REJECTED|INVALID)/.test(text)
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok',{headers:cors})
  try {
    const auth=req.headers.get('Authorization')
    if(!auth) return new Response(JSON.stringify({success:false,message:'Sign in required.'}),{status:401,headers:cors})
    const supabaseUrl=Deno.env.get('SUPABASE_URL')!
    const anonKey=Deno.env.get('SUPABASE_ANON_KEY')!
    const serviceKey=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const cfId=Deno.env.get('CASHFREE_CLIENT_ID')
    const cfSecret=Deno.env.get('CASHFREE_CLIENT_SECRET')
    if(!cfId||!cfSecret) throw new Error('Identity verification provider is not configured.')

    const userClient=createClient(supabaseUrl,anonKey,{global:{headers:{Authorization:auth}}})
    const {data:{user},error:userError}=await userClient.auth.getUser()
    if(userError||!user) return new Response(JSON.stringify({success:false,message:'Invalid session.'}),{status:401,headers:cors})
    const body=await req.json().catch(()=>({}))
    const admin=createClient(supabaseUrl,serviceKey)
    const {data:row,error:rowError}=await admin.from('identity_verifications').select('user_id,role,provider_reference,status').eq('user_id',user.id).maybeSingle()
    if(rowError||!row) throw new Error('Verification session not found.')
    const verificationId=body?.verification_id || row.provider_reference
    if(!verificationId) throw new Error('Verification reference missing.')

    const r=await fetch(`https://api.cashfree.com/verification/form?verificationID=${encodeURIComponent(verificationId)}`,{headers:{'x-client-id':cfId,'x-client-secret':cfSecret}})
    const result=await r.json().catch(()=>null)
    if(!r.ok||!result) throw new Error('Could not read verification status from provider.')

    const details=Array.isArray(result.verification_details)?result.verification_details:[]
    const checks=findChecks(details)
    const formStatus=String(result.form_status||'').toUpperCase()
    const allPassed=formStatus==='SUCCESS' && checks.name && checks.face && checks.liveness

    if(allPassed){
      const {error}=await admin.rpc('complete_identity_verification',{
        p_user_id:user.id,p_role:row.role,p_status:'verified',p_provider:'cashfree_secure_id',
        p_name_match:true,p_face_match:true,p_liveness_passed:true,p_provider_reference:verificationId,p_rejection_reason:null
      })
      if(error) throw error
      return new Response(JSON.stringify({success:true,status:'verified',checks}),{status:200,headers:cors})
    }

    const failed=formStatus==='FAILED'||formStatus==='REJECTED'||details.some(x=>/FAILED|REJECTED|INVALID/.test(JSON.stringify(x).toUpperCase()))
    if(failed){
      await admin.rpc('complete_identity_verification',{
        p_user_id:user.id,p_role:row.role,p_status:'rejected',p_provider:'cashfree_secure_id',
        p_name_match:checks.name,p_face_match:checks.face,p_liveness_passed:checks.liveness,p_provider_reference:verificationId,p_rejection_reason:'The required identity checks did not all pass.'
      })
      return new Response(JSON.stringify({success:true,status:'rejected',checks}),{status:200,headers:cors})
    }

    return new Response(JSON.stringify({success:true,status:'pending',checks,form_status:formStatus}),{status:200,headers:cors})
  }catch(e){
    return new Response(JSON.stringify({success:false,message:e instanceof Error?e.message:'Unable to sync verification.'}),{status:500,headers:cors})
  }
})

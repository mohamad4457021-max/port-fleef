// Staging-only transport. Do not expose portfleet_v2_api in production.
// Pass a Supabase publishable/anon key ONLY, never a service_role or secret key.
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const err=code=>Object.assign(Error(code),{code});
export function createStagingTransport({url,publicKey,getSession,fetchImpl=globalThis.fetch,timeoutMs=15000}){
 const base=new URL(url);
 if(base.protocol!=='https:'||base.username||base.password||base.pathname!=='/'||base.search||base.hash)throw err('INVALID_ENDPOINT');
 if(typeof publicKey!=='string'||!publicKey||publicKey.length>4096||publicKey.startsWith('sb_secret_'))throw err('INVALID_PUBLIC_KEY');
 // Legacy JWT keys must explicitly identify the anon role.
 if(!publicKey.startsWith('sb_publishable_')){
  try{
   const parts=publicKey.split('.');
   if(parts.length!==3)throw Error();
   const payload=JSON.parse(atob(parts[1].replace(/-/g,'+').replace(/_/g,'/')));
   if(payload.role!=='anon')throw Error();
  }catch{throw err('INVALID_PUBLIC_KEY');}
 }
 if(typeof getSession!=='function'||typeof fetchImpl!=='function'||!Number.isFinite(timeoutMs)||timeoutMs<1000||timeoutMs>60000)throw err('INVALID_TRANSPORT');
 const validScope=s=>s&&typeof s.actor==='string'&&uuid.test(s.actor)&&typeof s.owner==='string'&&uuid.test(s.owner);
 const validStream=s=>s==='fuel'||s==='inventory';
 async function session(scope){
  if(!validScope(scope))throw err('INVALID_SCOPE');
  const s=await getSession();
  if(!s||typeof s.access_token!=='string'||!s.access_token||s.user?.id!==scope.actor)throw err('SESSION_MISMATCH');
  return {token:s.access_token};
 }
 async function rpc(scope,name,params){
  const current=await session(scope);
  const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),timeoutMs);
  try{
   const response=await fetchImpl(new URL('/rest/v1/rpc/'+name,base),{
    method:'POST',headers:{apikey:publicKey,Authorization:'Bearer '+current.token,
     'Content-Type':'application/json','Content-Profile':'portfleet_v2_api','Accept-Profile':'portfleet_v2_api'},
    body:JSON.stringify(params),signal:controller.signal,cache:'no-store',credentials:'omit',redirect:'error'
   });
   // Prevent a response from being applied after the user switched accounts.
   const after=await session(scope);
   if(after.token!==current.token)throw err('SESSION_CHANGED');
   const data=await response.json();
   if(!response.ok){
    if(['40001','42501','22023'].includes(data?.code))throw err(data.code);
    if(response.status===401||response.status===403)throw err('42501');
    throw err('RPC_UNAVAILABLE');
   }
   return data;
  }finally{clearTimeout(timer);}
 }
 function check(scope,stream){if(!validScope(scope)||!validStream(stream))throw err('INVALID_SCOPE_OR_STREAM');}
 return Object.freeze({
  state(scope,stream){check(scope,stream);return rpc(scope,'sync_state',{p_owner:scope.owner,p_stream:stream});},
  post(scope,stream,params){check(scope,stream);if(!params||params.p_owner!==scope.owner||!uuid.test(params.p_operation||''))throw err('INVALID_OPERATION');
   // Send only the allowed fields; never accept a caller-supplied actor id.
   const keys=['p_owner','p_operation','p_expected','p_kind','p_qty','p_reference',...(stream==='fuel'?['p_asset','p_date']:['p_part','p_work'])];
   const body=Object.fromEntries(keys.map(k=>[k,params[k]]));
   return rpc(scope,stream==='fuel'?'post_fuel':'post_inventory',body);
  },
  receipt(scope,stream,operation){check(scope,stream);if(!uuid.test(operation||''))throw err('INVALID_OPERATION');return rpc(scope,'sync_receipt',{p_owner:scope.owner,p_stream:stream,p_operation:operation});}
 });
}

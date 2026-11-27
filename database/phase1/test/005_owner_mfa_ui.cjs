// Mocked browser/Auth API tests. No actual TOTP or Supabase requests.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const html=fs.readFileSync('owner.html','utf8');
const start=html.indexOf('function ownerAal2(s)'),mid=html.indexOf('function mfaCode(',start),v=html.indexOf('async function verifyOwnerMfa(',mid),end=html.indexOf('function validAuth(',v);
assert.ok(start>=0&&mid>start&&v>mid&&end>v);
const jwt=aal=>'header.'+Buffer.from(JSON.stringify({aal})).toString('base64url')+'.signature';
const session={access_token:jwt('aal1'),refresh_token:'test-refresh',user:{id:'test-owner'}};
const factor={id:'test-factor',factor_type:'totp',status:'verified'};
const signal=new AbortController().signal;
const ok=data=>({ok:true,status:200,data});
function build({factors=[factor],verify=ok({access_token:jwt('aal2'),refresh_token:'new-refresh'}),agree=true,code='123456',cancel=false}={}){
 const calls=[];
 const request=async(path,opts)=>{calls.push({path,body:opts.body});if(path.endsWith('/user'))return ok({id:'test-owner',factors});if(path.endsWith('/factors'))return ok({id:'new-factor',totp:{secret:'FAKE-TEST-SECRET'}});if(path.endsWith('/challenge'))return ok({id:'challenge'});if(path.endsWith('/verify'))return verify;throw Error('unexpected route')};
 const api=new Function('request','mfaCode','confirm','t','validAuth','setExpiry',html.slice(start,mid)+html.slice(v,end)+';return {ownerAal2,verifyOwnerMfa}')(request,async(secret)=>{if(cancel)throw Error('mfa_cancel');return code},()=>agree,(a,b)=>a,s=>!!(s.access_token&&s.refresh_token&&s.user.id),s=>s);
 return {...api,calls};
}
(async()=>{
 let b=build();assert.equal(b.ownerAal2(session),false);assert.equal(b.ownerAal2({access_token:'malformed'}),false);assert.equal(b.ownerAal2({access_token:jwt('aal2')}),true);
 let s=await b.verifyOwnerMfa(session,signal);assert.equal(b.ownerAal2(s),true);assert.deepEqual(b.calls.map(x=>x.path),['/auth/v1/user','/auth/v1/factors/test-factor/challenge','/auth/v1/factors/test-factor/verify']);assert.deepEqual(b.calls[2].body,{challenge_id:'challenge',code:'123456'});
 b=build({verify:{ok:false,status:400}});await assert.rejects(b.verifyOwnerMfa(session,signal),/mfa_failed/);
 b=build({verify:ok({access_token:jwt('aal1'),refresh_token:'bad'})});await assert.rejects(b.verifyOwnerMfa(session,signal),/mfa_failed/);
 b=build({factors:[],agree:false});await assert.rejects(b.verifyOwnerMfa(session,signal),/mfa_cancel/);assert.equal(b.calls.length,1);
 b=build({factors:[]});s=await b.verifyOwnerMfa(session,signal);assert.equal(b.ownerAal2(s),true);assert.equal(b.calls[1].body.factor_type,'totp');
 b=build({cancel:true});await assert.rejects(b.verifyOwnerMfa(session,signal),/mfa_cancel/);assert.equal(b.calls.length,1);
 b=build();await b.verifyOwnerMfa({...session,access_token:jwt('aal2')},signal);assert.equal(b.calls.length,0);
 assert.ok(html.includes("if(isOwner&&!ownerAal2(s))throw Error('mfa_cancel')"));
 assert.ok(html.includes("if(owner&&!ownerAal2(next))"));
 assert.ok(html.includes("if(sessionIsOwner&&!ownerAal2(next))"));
 console.log('PASS: mocked owner MFA verification, enrollment, rejection, cancellation and AAL guards');
})().catch(e=>{console.error(e);process.exitCode=1});

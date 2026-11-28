// Staging-only offline outbox. Not wired into V1 or production APIs.
// Stores operation data, never access tokens. Browser storage is NOT encryption.
// The transport must be bound to the current authenticated session.
const DB_NAME='portfleet-v2-staging-outbox', STORE='operations';
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const COUNTER=/^(0|[1-9][0-9]{0,18})$/;
const id=x=>typeof x==='string'&&UUID.test(x);
const counter=x=>typeof x==='string'&&COUNTER.test(x)&&BigInt(x)<=9223372036854775807n;
const streamOk=x=>x==='fuel'||x==='inventory';
const clone=x=>structuredClone(x);
function scopeKey(scope){
 if(!scope||!id(scope.owner)||!id(scope.actor))throw Error('INVALID_SCOPE');
 return [scope.owner.toLowerCase(),scope.actor.toLowerCase()];
}
function validateOperation(scope,stream,state,input,operation,now){
 const [owner,actor]=scopeKey(scope);
 if(!streamOk(stream)||!id(operation)||!state||state.owner!==owner||state.actor!==actor||state.stream!==stream||
    !counter(state.sequence)||!counter(state.source_revision)||state.source_revision==='0')throw Error('INVALID_SYNC_STATE');
 if(!input||!['استلام','صرف'].includes(input.kind)||typeof input.reference!=='string'||!input.reference.trim()||input.reference.length>200)
  throw Error('INVALID_OPERATION');
 // Decimal text preserves the submitted quantity exactly; reject excess precision.
 if(typeof input.qty!=='string'||!/^(0|[1-9][0-9]{0,13})(\.[0-9]{1,6})?$/.test(input.qty)||Number(input.qty)<=0)
  throw Error('INVALID_QUANTITY');
 const ref=x=>typeof x==='string'&&x.trim().length>0&&x.length<=200;
 const p={p_owner:owner,p_operation:operation.toLowerCase(),p_expected:state.sequence,p_kind:input.kind,p_qty:input.qty,p_reference:input.reference};
 if(stream==='fuel'){
  if(typeof input.date!=='string'||!/^\d{4}-\d{2}-\d{2}$/.test(input.date)||!Number.isFinite(Date.parse(input.date))||
    new Date(input.date).toISOString().slice(0,10)!==input.date||
    (input.kind==='صرف'?!ref(input.asset):input.asset!=null))throw Error('INVALID_FUEL');
  p.p_asset=input.asset??null;p.p_date=input.date;
 }else{
  if(!ref(input.part)||(input.kind==='صرف'?!ref(input.work):input.work!=null))throw Error('INVALID_INVENTORY');
  p.p_part=input.part;p.p_work=input.work??null;
 }
 return {owner,actor,operation:p.p_operation,stream,sourceRevision:state.source_revision,params:p,createdAt:now,status:'pending',attempts:0};
}
function txDone(tx){return new Promise((resolve,reject)=>{tx.oncomplete=()=>resolve();tx.onabort=()=>reject(tx.error||Error('IDB_ABORT'));tx.onerror=()=>reject(tx.error||Error('IDB_ERROR'))})}
export async function openOutbox(indexedDB=globalThis.indexedDB){
 if(!indexedDB)throw Error('INDEXEDDB_UNAVAILABLE');
 const db=await new Promise((resolve,reject)=>{
  const req=indexedDB.open(DB_NAME,1);
  req.onupgradeneeded=()=>{const s=req.result.createObjectStore(STORE,{keyPath:['owner','actor','operation']});s.createIndex('scope',['owner','actor']);};
  req.onsuccess=()=>resolve(req.result);req.onerror=()=>reject(req.error);req.onblocked=()=>reject(Error('IDB_BLOCKED'));
 });
 db.onversionchange=()=>db.close();
 const write=()=>db.transaction(STORE,'readwrite',{durability:'strict'});
 const read=()=>db.transaction(STORE,'readonly');
 return {
  close:()=>db.close(),
  async add(row){const tx=write(),done=txDone(tx);tx.objectStore(STORE).add(clone(row));await done;return clone(row);},
  async list(scope){const tx=read(),done=txDone(tx);const r=tx.objectStore(STORE).index('scope').getAll(scopeKey(scope));await done;return r.result.map(clone);},
  async claim(scope,stream,now,lease,attempt){
   const tx=write(),done=txDone(tx),s=tx.objectStore(STORE),req=s.index('scope').getAll(scopeKey(scope));let picked=null;
   req.onsuccess=()=>{
    // Preserve ordering within a stream. A blocked head needs explicit review.
    const rows=req.result.filter(r=>r.stream===stream&&r.status!=='confirmed').sort((a,b)=>a.createdAt-b.createdAt||a.operation.localeCompare(b.operation));
    const row=rows[0];if(!row||row.status==='blocked'||(row.status==='sending'&&row.leaseUntil>now))return;
    if(row.status!=='pending'&&row.status!=='sending')return;
    picked={...row,status:'sending',attempt,leaseUntil:now+lease,attempts:row.attempts+1};
    s.put(picked);
   };
   await done;return picked?clone(picked):null;
  },
  async finish(row,attempt,patch){
   const tx=write(),done=txDone(tx),s=tx.objectStore(STORE),req=s.get([row.owner,row.actor,row.operation]);let changed=false;
   req.onsuccess=()=>{const r=req.result;if(!r||r.status!=='sending'||r.attempt!==attempt)return;
    const next={...r,...clone(patch)};delete next.attempt;delete next.leaseUntil;s.put(next);changed=true;};
   await done;return changed;
  }
 };
}
export function createSyncEngine({scope,store,transport,clock=()=>Date.now(),uuid=()=>crypto.randomUUID(),leaseMs=60000}){
 const [owner,actor]=scopeKey(scope),bound=Object.freeze({owner,actor});
 if(!store||!transport||!Number.isFinite(leaseMs)||leaseMs<1000)throw Error('INVALID_ENGINE');
 let running=false;
 function assertIdentity(state,stream){
  if(!state||state.owner!==owner||state.actor!==actor||state.stream!==stream||!counter(state.sequence)||!counter(state.source_revision)||state.source_revision==='0')
   throw Object.assign(Error('SESSION_MISMATCH'),{code:'SESSION_MISMATCH'});
 }
 async function enqueue(stream,state,input){
  // Persist before any network transmission; supplied state is the last trusted server state.
  const row=validateOperation(bound,stream,state,input,uuid(),clock());
  return store.add(row);
 }
 async function flushOne(stream){
  if(!streamOk(stream))throw Error('INVALID_STREAM');
  if(running)return {status:'busy'};
  running=true;
  let row=null,attempt;
  try{
   attempt=uuid();row=await store.claim(bound,stream,clock(),leaseMs,attempt);
   if(!row)return {status:'idle'};
   const state=await transport.state(bound,stream);assertIdentity(state,stream);
   if(state.source_revision!==row.sourceRevision)throw Object.assign(Error('SOURCE_REVISION_CHANGED'),{code:'40001'});
   // Never silently rebase. A previous successful request may be retried with its
   // original expected revision and UUID; server verifies the exact payload.
   await transport.post(bound,stream,clone(row.params));
   const receipt=await transport.receipt(bound,stream,row.operation);
   if(!receipt||receipt.owner!==owner||receipt.actor!==actor||receipt.stream!==stream||
      receipt.operation!==row.operation||!counter(receipt.sequence)||receipt.sequence==='0')
    throw Object.assign(Error('RECEIPT_NOT_VERIFIED'),{code:'RECEIPT_NOT_VERIFIED'});
   const changed=await store.finish(row,attempt,{status:'confirmed',receipt:clone(receipt),confirmedAt:clock(),lastError:null});
   return {status:changed?'confirmed':'lease_lost',operation:row.operation};
  }catch(e){
   if(!row)throw e;
   const code=typeof e?.code==='string'?e.code:'NETWORK_OR_UNKNOWN';
   // Definitive server rejection requires review; transient or unknown outcome is
   // kept pending, never treated as successful and never assigned a new UUID.
   const blocked=['40001','42501','22023','SESSION_MISMATCH'].includes(code);
   const changed=await store.finish(row,attempt,{status:blocked?'blocked':'pending',lastError:code,lastAttemptAt:clock()});
   return {status:changed?(blocked?'blocked':'pending'):'lease_lost',operation:row.operation,code};
  }finally{running=false;}
 }
 return Object.freeze({enqueue,flushOne,list:()=>store.list(bound)});
}

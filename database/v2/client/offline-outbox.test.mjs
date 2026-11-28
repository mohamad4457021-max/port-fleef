import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {createSyncEngine,openOutbox} from './offline-outbox.mjs';
import {indexedDB} from 'fake-indexeddb';
const scope={owner:'00000000-0000-4000-8000-000000000001',actor:'00000000-0000-4000-8000-000000000002'};
const other={...scope,actor:'00000000-0000-4000-8000-000000000003'};
const sample={kind:'صرف',asset:'a',date:'2026-01-02',qty:'10.125',reference:'CI'};
test('durable outbox, exact retry, tab lease, conflict, session isolation',async()=>{
 let now=1000, revision='1', seq='0', network=true, loseResponse=false, wrongSession=false, paused=false, release;
 let receipts=new Map(),posts=0;
 const transport={
  async state(s,stream){if(!network)throw Error('offline');return {...s,actor:wrongSession?other.actor:s.actor,stream,source_revision:revision,sequence:seq}},
  async post(s,stream,p){
   posts++;
   if(paused)await new Promise(r=>release=r);
   const old=receipts.get(p.p_operation);
   if(old){assert.deepEqual(p,old.params);return old.receipt.sequence}
   if(p.p_expected!==seq)throw Object.assign(Error('conflict'),{code:'40001'});
   seq=String(BigInt(seq)+1n);
   const receipt={...s,stream,operation:p.p_operation,sequence:seq};
   receipts.set(p.p_operation,{params:p,receipt});
   if(loseResponse){loseResponse=false;throw Error('connection lost after commit')}
   return seq;
  },
  async receipt(s,stream,op){return receipts.get(op)?.receipt??null}
 };
 let store=await openOutbox(indexedDB);
 let engine=createSyncEngine({scope,store,transport,clock:()=>now,uuid:randomUUID,leaseMs:1000});
 const state=await transport.state(scope,'fuel');
 await assert.rejects(engine.enqueue('fuel',state,{...sample,qty:'0'}),/INVALID_QUANTITY/);
 await assert.rejects(engine.enqueue('fuel',state,{...sample,date:'2026-02-30'}),/INVALID_FUEL/);
 await assert.rejects(engine.enqueue('fuel',{...state,actor:other.actor},sample),/INVALID_SYNC_STATE/);
 const row=await engine.enqueue('fuel',state,sample);
 network=false;assert.equal((await engine.flushOne('fuel')).status,'pending');assert.equal(posts,0);
 store.close();store=await openOutbox(indexedDB);
 engine=createSyncEngine({scope,store,transport,clock:()=>now,uuid:randomUUID,leaseMs:1000});
 assert.equal((await engine.list())[0].operation,row.operation);
 assert.deepEqual(await store.list(other),[]);
 network=true;loseResponse=true;
 assert.equal((await engine.flushOne('fuel')).status,'pending');assert.equal(seq,'1');
 assert.equal((await engine.flushOne('fuel')).status,'confirmed');assert.equal(seq,'1');assert.equal(receipts.size,1);
 assert.equal((await engine.list())[0].receipt.operation,row.operation);
 now++;
 const row2=await engine.enqueue('fuel',await transport.state(scope,'fuel'),sample);
 const store2=await openOutbox(indexedDB);
 const second=createSyncEngine({scope,store:store2,transport,clock:()=>now,uuid:randomUUID,leaseMs:1000});
 paused=true;const first=engine.flushOne('fuel');
 while(!release)await new Promise(r=>setTimeout(r,1));
 assert.equal((await second.flushOne('fuel')).status,'idle');paused=false;release();
 assert.equal((await first).status,'confirmed');assert.equal(seq,'2');
 now++;
 const row3=await engine.enqueue('fuel',await transport.state(scope,'fuel'),sample);
 const abandoned=await store.claim(scope,'fuel',now,1000,randomUUID());assert.equal(abandoned.operation,row3.operation);
 assert.equal((await second.flushOne('fuel')).status,'idle');now+=1001;
 assert.equal((await second.flushOne('fuel')).status,'confirmed');assert.equal(seq,'3');
 assert.equal(await store.finish(abandoned,abandoned.attempt,{status:'pending'}),false);
 now++;
 await engine.enqueue('inventory',await transport.state(scope,'inventory'),{kind:'استلام',part:'pt',qty:'1',reference:'CI'});
 wrongSession=true;const before=posts;
 assert.equal((await engine.flushOne('inventory')).code,'SESSION_MISMATCH');assert.equal(posts,before);
 wrongSession=false;
 now++;
 await engine.enqueue('fuel',await transport.state(scope,'fuel'),sample);
 seq='4';assert.equal((await engine.flushOne('fuel')).code,'40001');assert.equal((await engine.flushOne('fuel')).status,'idle');
 assert.equal((await engine.list()).filter(r=>r.status==='blocked').length,2);
 store2.close();store.close();
});

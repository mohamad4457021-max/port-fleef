// Experimental local vault. Do not replace production storage until integration tests pass.
// Web Crypto + IndexedDB. No passphrase or CryptoKey persisted.
const FORMAT='portfleet-local-vault',VERSION=1,ITERATIONS=600000,MAX_BYTES=7000000;
const enc=new TextEncoder(),dec=new TextDecoder('utf-8',{fatal:true});
const b64=b=>{let s='';for(let i=0;i<b.length;i+=16384)s+=String.fromCharCode(...b.subarray(i,i+16384));return btoa(s)};
const unb64=(s,max)=>{if(typeof s!=='string'||s.length>4*Math.ceil(max/3)||!/^[A-Za-z0-9+/]*={0,2}$/.test(s))throw Error('VAULT_FORMAT');const b=Uint8Array.from(atob(s),c=>c.charCodeAt(0));if(b.length>max||b64(b)!==s)throw Error('VAULT_FORMAT');return b};
const scopeCheck=s=>{if(typeof s!=='string'||!(/^(owner|personal):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s)||s==='guest:local'))throw Error('VAULT_SCOPE')};
const revCheck=r=>{if(!Number.isSafeInteger(r)||r<1)throw Error('VAULT_REVISION')};
const aad=(scope,rev,salt)=>enc.encode(JSON.stringify([FORMAT,VERSION,scope,rev,salt,ITERATIONS]));
async function derive(passphrase,salt){
 if(typeof passphrase!=='string'||passphrase.length<12||passphrase.length>256)throw Error('VAULT_PASSWORD');
 const material=await crypto.subtle.importKey('raw',enc.encode(passphrase),'PBKDF2',false,['deriveKey']);
 return crypto.subtle.deriveKey({name:'PBKDF2',hash:'SHA-256',salt,iterations:ITERATIONS},material,{name:'AES-GCM',length:256},false,['encrypt','decrypt']);
}
function payloadCheck(p){
 if(!p||typeof p!=='object'||Array.isArray(p)||Object.keys(p).sort().join(',')!=='backup,meta,snapshot')throw Error('VAULT_PAYLOAD');
 if(typeof p.snapshot!=='string'||(p.backup!==null&&typeof p.backup!=='string')||(p.meta!==null&&typeof p.meta!=='string'))throw Error('VAULT_PAYLOAD');
 const validateSnapshot=raw=>{const x=JSON.parse(raw);if(x?.version!==1||!['assets','staff','requests','assignments','cranes','fuel','work','plans','parts','moves','oils','audit'].every(k=>Array.isArray(x[k])))throw Error('VAULT_SNAPSHOT')};
 validateSnapshot(p.snapshot);if(p.backup!==null)validateSnapshot(p.backup);
 if(p.meta!==null){const m=JSON.parse(p.meta);if(!Number.isSafeInteger(m?.revision)||m.revision<1||typeof m.hash!=='string')throw Error('VAULT_META')}
 const raw=enc.encode(JSON.stringify(p));if(raw.length>MAX_BYTES)throw Error('VAULT_SIZE');return raw;
}
function envelopeCheck(e,scope){
 if(!e||e.format!==FORMAT||e.version!==VERSION||e.scope!==scope||e.kdf!=='PBKDF2-SHA256'||e.iterations!==ITERATIONS||e.cipher!=='AES-256-GCM')throw Error('VAULT_FORMAT');
 revCheck(e.revision);const salt=unb64(e.salt,16),iv=unb64(e.iv,12),bytes=unb64(e.ciphertext,MAX_BYTES+16);
 if(salt.length!==16||iv.length!==12||bytes.length<16)throw Error('VAULT_FORMAT');
 return {salt,iv,bytes};
}
async function seal(key,salt,scope,revision,payload){
 scopeCheck(scope);revCheck(revision);const plain=payloadCheck(payload),iv=crypto.getRandomValues(new Uint8Array(12)),s=b64(salt);
 const cipher=await crypto.subtle.encrypt({name:'AES-GCM',iv,additionalData:aad(scope,revision,s),tagLength:128},key,plain);
 return {format:FORMAT,version:VERSION,scope,revision,kdf:'PBKDF2-SHA256',iterations:ITERATIONS,cipher:'AES-256-GCM',salt:s,iv:b64(iv),ciphertext:b64(new Uint8Array(cipher))};
}
async function unseal(key,e,scope){
 const {iv,bytes}=envelopeCheck(e,scope);
 try{const plain=await crypto.subtle.decrypt({name:'AES-GCM',iv,additionalData:aad(scope,e.revision,e.salt),tagLength:128},key,bytes);
 const p=JSON.parse(dec.decode(plain));payloadCheck(p);return p}catch{throw Error('VAULT_UNLOCK_FAILED')}
}
const same=(a,b)=>a===null?b===null:b!==null&&JSON.stringify(a)===JSON.stringify(b);
// Adapter contract: read(scope) returns envelope or null; compareAndSwap(scope, expected, next)
// commits atomically or rejects VAULT_CONFLICT. No automatic deletion of legacy plaintext.
export async function createVault(store,scope,passphrase,payload){
 scopeCheck(scope);if(await store.read(scope)!==null)throw Error('VAULT_EXISTS');
 const salt=crypto.getRandomValues(new Uint8Array(16)),key=await derive(passphrase,salt),e=await seal(key,salt,scope,1,payload);
 await store.compareAndSwap(scope,null,e);
 return session(store,scope,key,salt,e,payload);
}
export async function unlockVault(store,scope,passphrase){
 scopeCheck(scope);const e=await store.read(scope);if(!e)throw Error('VAULT_MISSING');
 const {salt}=envelopeCheck(e,scope),key=await derive(passphrase,salt),p=await unseal(key,e,scope);
 return session(store,scope,key,salt,e,p);
}
function session(store,scope,key,salt,expected,payload){
 let locked=false,busy=false;
 const check=()=>{if(locked)throw Error('VAULT_LOCKED')};
 return Object.freeze({
  read(){check();return structuredClone(payload)},
  get revision(){check();return expected.revision},
  async save(next){check();if(busy)throw Error('VAULT_BUSY');busy=true;
   try{const copy=structuredClone(next),e=await seal(key,salt,scope,expected.revision+1,copy);check();
   // In-flight IDB commit cannot be undone on lock; caller must await save before reporting success.
   await store.compareAndSwap(scope,expected,e);if(locked)throw Error('VAULT_LOCKED');
   expected=e;payload=copy;return e.revision}finally{busy=false}},
  lock(){locked=true;key=null;salt=null;expected=null;payload=null}
 });
}
// Durable storage, one atomic envelope per workspace. No secrets in storage other than ciphertext.
export async function openVaultStore(factory=globalThis.indexedDB){
 if(!factory)throw Error('VAULT_STORAGE_UNAVAILABLE');
 const db=await new Promise((resolve,reject)=>{const req=factory.open('portfleet-local-vault-v1',1);req.onupgradeneeded=()=>req.result.createObjectStore('vaults');req.onsuccess=()=>resolve(req.result);req.onerror=()=>reject(req.error);req.onblocked=()=>reject(Error('VAULT_STORAGE_BLOCKED'))});
 db.onversionchange=()=>db.close();
 return Object.freeze({
  read(scope){scopeCheck(scope);return new Promise((resolve,reject)=>{const tx=db.transaction('vaults','readonly'),r=tx.objectStore('vaults').get(scope);let value=null;r.onsuccess=()=>{value=r.result??null};tx.oncomplete=()=>resolve(value);tx.onabort=()=>reject(tx.error||Error('VAULT_READ_FAILED'))})},
  compareAndSwap(scope,expected,next){scopeCheck(scope);envelopeCheck(next,scope);
   return new Promise((resolve,reject)=>{const tx=db.transaction('vaults','readwrite'),o=tx.objectStore('vaults'),r=o.get(scope);let conflict=false;
   r.onsuccess=()=>{if(!same(r.result??null,expected)){conflict=true;tx.abort();return}o.put(next,scope)};
   tx.oncomplete=()=>resolve();tx.onabort=()=>reject(conflict?Error('VAULT_CONFLICT'):tx.error||Error('VAULT_WRITE_FAILED'))})},
  close(){db.close()}
 });
}

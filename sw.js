const CACHE='portfleet-v7-install-38';
const ROOT=self.registration.scope;
const HOME=new URL('index.html',ROOT).href;
const OWNER=new URL('owner.html',ROOT).href;
const APP=['index.html','owner.html','launcher.js','manifest.json','owner-icon-192.png','owner-icon-512.png','user/user-icon-192.png'].map(p=>new URL(p,ROOT).href);
self.addEventListener('install',event=>event.waitUntil((async()=>{const c=await caches.open(CACHE);await c.addAll(APP.map(url=>new Request(url,{cache:'reload'})));await self.skipWaiting()})()));
self.addEventListener('activate',event=>event.waitUntil((async()=>{for(const k of await caches.keys())if(k.startsWith('portfleet-v7-install-')&&k!==CACHE)await caches.delete(k);await self.clients.claim()})()));
function navigationKey(url){if(url.pathname===new URL(ROOT).pathname||url.pathname===new URL(HOME).pathname)return HOME;if(url.pathname===new URL(OWNER).pathname)return OWNER;return null}
self.addEventListener('fetch',event=>{const r=event.request,url=new URL(r.url);if(r.method!=='GET'||!url.href.startsWith(ROOT))return;
if(r.mode==='navigate'){const key=navigationKey(url);if(!key)return;event.respondWith((async()=>{try{const res=await fetch(r,{cache:'no-store'});if(res.ok){const c=await caches.open(CACHE);await c.put(key,res.clone());return res}throw Error('unavailable')}catch{return (await caches.open(CACHE)).match(key).then(x=>x||Response.error())}})());return}
const clean=url.origin+url.pathname;if(APP.includes(clean)){event.respondWith((async()=>{try{const res=await fetch(r);if(res.ok)return res}catch{}return (await caches.open(CACHE)).match(clean).then(x=>x||Response.error())})())}});

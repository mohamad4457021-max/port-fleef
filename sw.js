const CACHE='portfleet-v7-install-14';
const ROOT=self.registration.scope;
const HOME=new URL('index.html',ROOT).href;
const APP=['index.html','manifest.json','app-icon-192.png','app-icon-512.png'].map(p=>new URL(p,ROOT).href);
self.addEventListener('install',event=>event.waitUntil((async()=>{const c=await caches.open(CACHE);await c.addAll(APP.map(url=>new Request(url,{cache:'reload'})));await self.skipWaiting();})()));
self.addEventListener('activate',event=>event.waitUntil((async()=>{for(const k of await caches.keys())if(k.startsWith('portfleet-v7-install-')&&k!==CACHE)await caches.delete(k);await self.clients.claim();})()));
self.addEventListener('fetch',event=>{const r=event.request;const url=new URL(r.url);if(r.method!=='GET'||!url.href.startsWith(ROOT))return;
if(r.mode==='navigate'&&(url.pathname===new URL(ROOT).pathname||url.pathname===new URL(HOME).pathname)){event.respondWith((async()=>{try{const res=await fetch(r);if(res.ok){const c=await caches.open(CACHE);await c.put(HOME,res.clone());return res;}throw new Error('unavailable');}catch{return (await caches.open(CACHE)).match(HOME).then(x=>x||Response.error());}})());return;}
const clean=url.origin+url.pathname;if(APP.includes(clean)){event.respondWith((async()=>{try{const res=await fetch(r);if(res.ok)return res;}catch{}return (await caches.open(CACHE)).match(clean).then(x=>x||Response.error());})());}});

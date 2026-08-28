'use strict';
const CACHE_VERSION='wellone-employee-v88-stable-live';
const STATIC_CACHE=`${CACHE_VERSION}-static`;
const IMAGE_CACHE=`${CACHE_VERSION}-images`;
const STATIC_FILES=['./css/admin.css?v=88', './js/employee.bundle.js?v=88', './js/pwa-install.js?v=88', './manifest.webmanifest', './assets/logo.png?v=88'];
self.addEventListener('install',event=>event.waitUntil((async()=>{const c=await caches.open(STATIC_CACHE);await Promise.allSettled(STATIC_FILES.map(f=>c.add(f)));await self.skipWaiting();})()));
self.addEventListener('activate',event=>event.waitUntil((async()=>{const keys=await caches.keys();await Promise.all(keys.filter(k=>k.startsWith('wellone-employee-')&&!k.startsWith(CACHE_VERSION)).map(k=>caches.delete(k)));await self.clients.claim();})()));
function urlOf(r){try{return new URL(r.url);}catch(_e){return null;}}
function isSupabase(u){return Boolean(u&&u.hostname.endsWith('.supabase.co'));}
function publicStorage(u){return isSupabase(u)&&u.pathname.includes('/storage/v1/object/public/');}
async function networkFirst(r){const c=await caches.open(STATIC_CACHE);try{const res=await fetch(r,{cache:'no-cache'});if(res&&(res.ok||res.type==='opaque'))c.put(r,res.clone()).catch(()=>{});return res;}catch(error){const hit=await c.match(r);if(hit)return hit;throw error;}}
async function imageCache(r){const c=await caches.open(IMAGE_CACHE);const hit=await c.match(r);if(hit)return hit;const res=await fetch(r);if(res&&(res.ok||res.type==='opaque')){c.put(r,res.clone()).catch(()=>{});c.keys().then(keys=>{if(keys.length>180)Promise.all(keys.slice(0,keys.length-180).map(k=>c.delete(k))).catch(()=>{});}).catch(()=>{});}return res;}
self.addEventListener('fetch',event=>{const r=event.request;if(r.method!=='GET')return;if(r.mode==='navigate'||r.destination==='document')return;const u=urlOf(r);if(!u)return;if(isSupabase(u)&&!publicStorage(u))return;const same=u.origin===self.location.origin;const code=same&&['script','style','font','manifest'].includes(r.destination);const cdn=u.hostname==='cdn.jsdelivr.net'&&r.destination==='script';const image=r.destination==='image'||publicStorage(u);if(code||cdn){event.respondWith(networkFirst(r));return;}if(image)event.respondWith(imageCache(r));});

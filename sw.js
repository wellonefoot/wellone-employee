'use strict';
const CACHE_VERSION='wellone-employee-v85-safe-assets';
const STATIC_CACHE=`${CACHE_VERSION}-static`;
const IMAGE_CACHE=`${CACHE_VERSION}-images`;
const STATIC_FILES=['./css/admin.css?v=85','./js/employee.bundle.js?v=85','./js/pwa-install.js?v=85','./manifest.webmanifest','./assets/logo.png?v=85','./assets/favicon/favicon.ico'];
self.addEventListener('install',event=>event.waitUntil((async()=>{const cache=await caches.open(STATIC_CACHE);await Promise.allSettled(STATIC_FILES.map(f=>cache.add(f)));await self.skipWaiting();})()));
self.addEventListener('activate',event=>event.waitUntil((async()=>{const keys=await caches.keys();await Promise.all(keys.filter(k=>k.startsWith('wellone-employee-')&&!k.startsWith(CACHE_VERSION)).map(k=>caches.delete(k)));await self.clients.claim();})()));
function u(r){try{return new URL(r.url);}catch(_e){return null;}}
function supabase(url){return Boolean(url&&url.hostname.endsWith('.supabase.co'));}
function publicStorage(url){return supabase(url)&&url.pathname.includes('/storage/v1/object/public/');}
async function cacheFirst(r){const c=await caches.open(STATIC_CACHE);const hit=await c.match(r);if(hit)return hit;const res=await fetch(r);if(res&&(res.ok||res.type==='opaque'))c.put(r,res.clone()).catch(()=>{});return res;}
async function imageCache(r){const c=await caches.open(IMAGE_CACHE);const hit=await c.match(r);if(hit)return hit;const res=await fetch(r);if(res&&(res.ok||res.type==='opaque'))c.put(r,res.clone()).catch(()=>{});return res;}
self.addEventListener('fetch',event=>{const r=event.request;if(r.method!=='GET')return;if(r.mode==='navigate'||r.destination==='document')return;const url=u(r);if(!url)return;if(supabase(url)&&!publicStorage(url))return;const same=url.origin===self.location.origin;const versioned=same&&/(?:\?|&)v=85(?:&|$)/.test(url.search);const staticAsset=same&&['script','style','font','manifest'].includes(r.destination);const image=r.destination==='image'||publicStorage(url);if(versioned||staticAsset||(url.hostname==='cdn.jsdelivr.net'&&r.destination==='script')){event.respondWith(cacheFirst(r));return;}if(image)event.respondWith(imageCache(r));});

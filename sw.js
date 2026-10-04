'use strict';
const CACHE_VERSION='shopizo-sales-shopizo-green-20261004-1';
const CORE=[
  './',
  './index.html',
  './css/admin.css?v=107',
  './js/employee.bundle.js?v=107',
  './js/pwa-install.js?v=shopizo-green-20261004-1',
  './manifest.webmanifest?v=shopizo-green-20261004-1',
  './assets/logo.png?v=shopizo-green-20261004-1',
  './assets/favicon/favicon.ico?v=shopizo-green-20261004-1',
  './assets/favicon/shopizo-icon-192.png?v=shopizo-green-20261004-1',
  './assets/favicon/shopizo-icon-512.png?v=shopizo-green-20261004-1'
];
self.addEventListener('install',event=>event.waitUntil(
  caches.open(CACHE_VERSION).then(cache=>cache.addAll(CORE)).then(()=>self.skipWaiting())
));
self.addEventListener('activate',event=>event.waitUntil(
  caches.keys().then(keys=>Promise.all(keys.filter(key=>key!==CACHE_VERSION).map(key=>caches.delete(key))))
    .then(()=>self.clients.claim())
));
self.addEventListener('message',event=>{
  if(event.data&&event.data.type==='SKIP_WAITING') self.skipWaiting();
});
self.addEventListener('fetch',event=>{
  if(event.request.method!=='GET') return;
  const url=new URL(event.request.url);
  const isBrand=url.pathname.endsWith('/manifest.webmanifest') ||
    url.pathname.endsWith('/assets/logo.png') || url.pathname.includes('/assets/favicon/');
  const isNavigation=event.request.mode==='navigate';
  if(isBrand || isNavigation){
    event.respondWith(fetch(event.request,{cache:'no-store'}).then(response=>{
      const copy=response.clone();
      caches.open(CACHE_VERSION).then(cache=>cache.put(event.request,copy)).catch(()=>{});
      return response;
    }).catch(()=>caches.match(event.request).then(hit=>hit||caches.match('./index.html'))));
    return;
  }
  event.respondWith(fetch(event.request).then(response=>{
    const copy=response.clone();
    caches.open(CACHE_VERSION).then(cache=>cache.put(event.request,copy)).catch(()=>{});
    return response;
  }).catch(()=>caches.match(event.request).then(hit=>hit||caches.match('./index.html'))));
});

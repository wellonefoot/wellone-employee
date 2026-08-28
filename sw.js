const CACHE='wellone-employee-v80';
const SHELL=['./','./index.html','./css/admin.css?v=80','./js/admin-config.js?v=80','./js/employee.js?v=80','./js/pwa-install.js?v=80','./manifest.webmanifest','./assets/logo.png?v=80','./assets/favicon/favicon.ico'];
self.addEventListener('install',e=>e.waitUntil(caches.open(CACHE).then(c=>c.addAll(SHELL)).then(()=>self.skipWaiting())));
self.addEventListener('activate',e=>e.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k.startsWith('wellone-employee-')&&k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim())));
self.addEventListener('fetch',e=>{
  const r=e.request;if(r.method!=='GET')return;const u=new URL(r.url);
  if(u.hostname.endsWith('.supabase.co')){e.respondWith(fetch(r,{cache:'no-store'}));return;}
  if(r.mode==='navigate'){e.respondWith(fetch(r,{cache:'no-store'}).catch(()=>caches.match('./index.html')));return;}
  if(u.origin===self.location.origin){e.respondWith(caches.match(r).then(c=>c||fetch(r).then(res=>{if(res.ok)caches.open(CACHE).then(cache=>cache.put(r,res.clone()));return res;})));}
});

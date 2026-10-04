(function(){
  'use strict';
  if(!('serviceWorker' in navigator) || !(location.protocol==='https:' || location.hostname==='localhost')) return;
  const SW_URL='./sw.js?v=shopizo-green-20261004-1';
  let registration=null;
  async function checkForUpdate(){
    try{
      if(!registration) registration=await navigator.serviceWorker.register(SW_URL,{updateViaCache:'none'});
      await registration.update();
      if(registration.waiting) registration.waiting.postMessage({type:'SKIP_WAITING'});
    }catch(_e){}
  }
  window.addEventListener('load',checkForUpdate,{once:true});
  document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='visible') checkForUpdate();});
  window.addEventListener('focus',checkForUpdate);
  setInterval(checkForUpdate,30*60*1000);
  navigator.serviceWorker.addEventListener('controllerchange',()=>{
    if(sessionStorage.getItem('shopizo-sw-reloaded')==='1') return;
    sessionStorage.setItem('shopizo-sw-reloaded','1');
    location.reload();
  });
})();

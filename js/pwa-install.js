(function(){
  'use strict';
  if('serviceWorker' in navigator && (location.protocol==='https:' || location.hostname==='localhost')){
    window.addEventListener('load',()=>navigator.serviceWorker.register('./sw.js?v=85',{updateViaCache:'none'}).then(r=>r.update().catch(()=>{})).catch(()=>{}),{once:true});
  }
})();

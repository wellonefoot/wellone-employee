(() => {
  'use strict';
  const $=id=>document.getElementById(id);
  const clean=v=>String(v??'').trim();
  const esc=v=>clean(v).replace(/[&<>"']/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
  const SESSION_KEY='wellone_employee_session_v79';
  const STORE_CHANNEL_NAME='wellone-store-events-v1';
  const STORE_EVENT_NAME='store-change';
  let client=null;
  let session=null;
  let currentProduct=null;
  let channel=null;
  let channelReady=false;

  function db(){
    if(!client) client=window.supabase.createClient(ADMIN_CONFIG.supabaseUrl,ADMIN_CONFIG.supabaseAnonKey,{realtime:{params:{eventsPerSecond:10}}});
    return client;
  }
  function loadSession(){ try{return JSON.parse(localStorage.getItem(SESSION_KEY)||'null');}catch(_e){return null;} }
  function saveSession(value){ session=value; if(value)localStorage.setItem(SESSION_KEY,JSON.stringify(value)); else localStorage.removeItem(SESSION_KEY); }
  function setStatus(message,type=''){ const box=$('employeeStatus'); box.textContent=message; box.className=`employee-status ${type}`.trim(); }
  function showDesk(){ $('employeeLoginScreen').hidden=true; $('employeeDesk').hidden=false; $('employeeSessionName').textContent=session?.username||'Employee'; setTimeout(()=>$('employeeBarcodeInput')?.focus(),50); }
  function showLogin(message=''){
    saveSession(null); currentProduct=null; $('employeeDesk').hidden=true; $('employeeLoginScreen').hidden=false; $('employeeProductResult').innerHTML=''; $('employeeLoginError').textContent=message; setTimeout(()=>$('employeeLoginUsername')?.focus(),50);
  }
  function stockText(value){ const n=Math.max(0,Number(value||0)); return `${n} available`; }
  function money(value){ return `₹${Number(value||0).toLocaleString('en-IN')}`; }
  function variantName(v){ return [clean(v.color)&&`Colour: ${clean(v.color)}`,clean(v.size)&&`Size: ${clean(v.size)}`].filter(Boolean).join(' · ')||'Standard option'; }
  function variantsOf(product){ return Array.isArray(product?.variants)?product.variants:[]; }
  function totalAvailable(product){
    const vs=variantsOf(product); if(vs.length) return vs.reduce((sum,v)=>sum+Math.max(0,Number(v.stock||0)),0);
    return Math.max(0,Number(product?.stock_quantity||0));
  }
  function renderProduct(product){
    currentProduct=product;
    const box=$('employeeProductResult');
    if(!product){ box.innerHTML='<div class="employee-empty-result"><b>No product found</b><p>Check the barcode and try again.</p></div>'; return; }
    const variants=variantsOf(product);
    const track=Boolean(product.track_inventory);
    const options=variants.map((v,index)=>{
      const available=Math.max(0,Number(v.stock||0));
      return `<label class="employee-variant-option ${available<=0?'sold-out':''}"><input type="radio" name="employeeVariant" value="${esc(v.id)}" ${index===variants.findIndex(x=>Number(x.stock||0)>0)?'checked':''} ${available<=0?'disabled':''}><span><b>${esc(variantName(v))}</b><small>${esc(stockText(available))}${Number(v.price||0)>0?` · ${esc(money(v.price))}`:''}</small></span></label>`;
    }).join('');
    const noAvailable=variants.length?variants.every(v=>Number(v.stock||0)<=0):Number(product.stock_quantity||0)<=0;
    box.innerHTML=`<article class="employee-product-card">
      <div class="employee-product-main"><div class="employee-product-photo">${product.image_url?`<img src="${esc(product.image_url)}" alt="">`:'<span>No image</span>'}</div><div><small>Barcode ${esc(product.barcode)}</small><h2>${esc(product.name)}</h2><b class="employee-total-stock">${esc(stockText(totalAvailable(product)))}</b></div></div>
      ${!track?'<div class="employee-warning">Stock tracking is off for this product. Turn it on in Admin before recording sales.</div>':''}
      ${variants.length?`<div class="employee-variant-list"><h3>Select colour & size</h3>${options}</div>`:'<div class="employee-standard-stock"><b>Standard item</b><span>'+esc(stockText(product.stock_quantity))+'</span></div>'}
      <form id="employeeSaleForm" class="employee-sale-form"><label>Sold quantity<input id="employeeSaleQty" type="number" min="1" step="1" inputmode="numeric" value="1" required></label><button type="submit" ${!track||noAvailable?'disabled':''}>Mark Sold</button></form>
    </article>`;
    $('employeeSaleForm')?.addEventListener('submit',recordSale);
  }
  async function ensureBroadcast(){
    if(channelReady&&channel)return channel;
    if(channel){try{db().removeChannel(channel);}catch(_e){}}
    channel=db().channel(STORE_CHANNEL_NAME,{config:{broadcast:{self:false,ack:true}}});
    await new Promise(resolve=>{
      let done=false; const finish=()=>{if(done)return;done=true;resolve();};
      channel.subscribe(status=>{if(status==='SUBSCRIBED'){channelReady=true;finish();} if(['CHANNEL_ERROR','TIMED_OUT','CLOSED'].includes(status)){channelReady=false;finish();}});
      setTimeout(finish,2500);
    });
    return channel;
  }
  async function broadcastStock(productId,variantId){
    try{
      const ch=await ensureBroadcast(); if(!ch||!channelReady)return;
      await ch.send({type:'broadcast',event:STORE_EVENT_NAME,payload:{tables:['products','product_variants'],action:'employee-sale',details:{productId,variantId:variantId||null},eventId:`employee-${Date.now()}-${Math.random().toString(36).slice(2)}`,at:Date.now()}});
    }catch(_e){}
  }
  async function login(event){
    event.preventDefault(); $('employeeLoginError').textContent='Checking...';
    const username=clean($('employeeLoginUsername').value),password=$('employeeLoginPassword').value||'';
    try{
      const {data,error}=await db().rpc('employee_login',{p_username:username,p_password:password});
      if(error)throw error;
      saveSession(data); $('employeeLoginPassword').value=''; $('employeeLoginError').textContent=''; showDesk();
    }catch(error){ $('employeeLoginError').textContent=error.message||'Login failed.'; }
  }
  async function findBarcode(event){
    event?.preventDefault(); const barcode=clean($('employeeBarcodeInput').value); if(!barcode)return;
    setStatus('Finding item...','loading'); $('employeeProductResult').innerHTML='';
    try{
      const {data,error}=await db().rpc('employee_get_product_by_barcode',{p_token:session?.token||'',p_barcode:barcode});
      if(error)throw error;
      if(!data){renderProduct(null);setStatus('Barcode not found.','error');return;}
      renderProduct(data); setStatus(`${data.name} loaded.`,'ok');
    }catch(error){
      if(/expired|login/i.test(error.message||'')){showLogin('Session expired. Login again.');return;}
      setStatus(error.message||'Could not load item.','error');
    }
  }
  async function recordSale(event){
    event.preventDefault(); if(!currentProduct)return;
    const variants=variantsOf(currentProduct); const selected=document.querySelector('input[name="employeeVariant"]:checked');
    if(variants.length&&!selected){setStatus('Select an available colour and size.','error');return;}
    const qty=Math.max(1,Number($('employeeSaleQty')?.value||1));
    const variantId=selected?.value||null;
    const button=event.currentTarget.querySelector('button'); button.disabled=true; setStatus('Saving sale...','loading');
    try{
      const {data,error}=await db().rpc('employee_record_sale',{p_token:session?.token||'',p_product_id:currentProduct.id,p_variant_id:variantId,p_quantity:qty});
      if(error)throw error;
      await broadcastStock(currentProduct.id,variantId);
      renderProduct(data); setStatus(`Sold ${qty} unit${qty===1?'':'s'}. Stock updated live.`,'ok');
    }catch(error){
      if(/expired|login/i.test(error.message||'')){showLogin('Session expired. Login again.');return;}
      setStatus(error.message||'Could not record sale.','error'); button.disabled=false;
    }
  }
  function logout(){ if(channel){try{db().removeChannel(channel);}catch(_e){}} channel=null;channelReady=false;showLogin(''); }

  $('employeeLoginForm').addEventListener('submit',login);
  $('employeeBarcodeForm').addEventListener('submit',findBarcode);
  $('employeeLogoutBtn').addEventListener('click',logout);
  session=loadSession(); if(session?.token&&session?.username)showDesk(); else showLogin('');
})();

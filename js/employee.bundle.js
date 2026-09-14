/* bundled from admin-config.js */
const ADMIN_CONFIG = {
  supabaseUrl: 'https://wnavzhrkwgnegjdetdno.supabase.co',
  supabaseAnonKey: 'sb_publishable_RbnMrDlHfEijBiejcRNPUg_mop2bqgM',
  storageBucket: 'product-images'
};

/* bundled from employee.js */
(() => {
  'use strict';
  const $=id=>document.getElementById(id);
  const clean=v=>String(v??'').trim();
  const esc=v=>clean(v).replace(/[&<>"']/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
  const SESSION_KEY='wellone_sales_session_v107';
  const STORE_CHANNEL_NAME='wellone-store-events-v1';
  const STORE_EVENT_NAME='store-change';
  let client=null;
  let session=null;
  let currentProduct=null;
  let searchResults=[];
  let channel=null;
  let channelReady=false;
  let inventoryChannel=null;
  let inventoryRefreshTimer=null;

  function db(){
    if(!client) client=window.supabase.createClient(ADMIN_CONFIG.supabaseUrl,ADMIN_CONFIG.supabaseAnonKey,{realtime:{params:{eventsPerSecond:10}}});
    return client;
  }
  function loadSession(){ try{return JSON.parse(localStorage.getItem(SESSION_KEY)||'null');}catch(_e){return null;} }
  function saveSession(value){ session=value; if(value)localStorage.setItem(SESSION_KEY,JSON.stringify(value)); else localStorage.removeItem(SESSION_KEY); }
  function setStatus(message,type=''){ const box=$('employeeStatus'); box.textContent=message; box.className=`employee-status ${type}`.trim(); }
  function resetDeskToSale(){
    document.body.classList.remove('employee-manage-open');
    $('employeeSaleView')?.classList.add('active');
  }
  function showDesk(){
    $('employeeLoginScreen').hidden=true; $('employeeDesk').hidden=false; $('employeeSessionName').textContent=session?.username||'Employee';
    resetDeskToSale(); startInventoryRealtime();
    requestAnimationFrame(()=>{window.scrollTo({top:0,behavior:'auto'});setTimeout(()=>$('employeeBarcodeInput')?.focus({preventScroll:true}),30);});
  }
  function showLogin(message=''){
    stopInventoryRealtime();
    saveSession(null); currentProduct=null; document.body.classList.remove('employee-manage-open'); $('employeeDesk').hidden=true; $('employeeLoginScreen').hidden=false; $('employeeProductResult').innerHTML=''; $('employeeLoginError').textContent=message; setTimeout(()=>$('employeeLoginUsername')?.focus(),50);
  }
  function stockText(value){ const n=Math.max(0,Number(value||0)); return `${n} available`; }
  function manualAvailable(status){ return clean(status || 'in_stock') !== 'out_of_stock'; }
  function variantAvailable(product,v){ if(!manualAvailable(product?.stock_status)) return false; return Boolean(product?.track_inventory) ? (manualAvailable(v?.stock_status) && Number(v?.stock||0)>0) : manualAvailable(v?.stock_status); }
  function money(value){ return `₹${Number(value||0).toLocaleString('en-IN')}`; }
  function imageUrl(value){const u=clean(value);if(!u)return '';return u.includes('/storage/v1/object/public/')&&!u.includes('?')?`${u}?width=360&quality=72`:u;}
  function productOptionName(product){
    const explicit=clean(product?.option_title); if(explicit)return explicit;
    const values=variantsOf(product).map(v=>clean(v.size)).join(' ').toLowerCase();
    if(/\b(ml|mg|g|kg|litre|liter|ltr|l)\b/.test(values))return 'Quantity';
    if(/\b(metre|meter|mtr|cm|inch|ft)\b/.test(values))return 'Measurement';
    return 'Size / option';
  }
  function variantsOf(product){ return Array.isArray(product?.variants)?product.variants:[]; }
  function totalAvailable(product){
    if(!product?.track_inventory) return null;
    const vs=variantsOf(product); if(vs.length) return vs.reduce((sum,v)=>sum+Math.max(0,Number(v.stock||0)),0);
    return Math.max(0,Number(product?.stock_quantity||0));
  }
  function stockSummary(product){ const total=totalAvailable(product); return total===null ? (manualAvailable(product?.stock_status)?'Available · manual stock':'Out of stock') : stockText(total); }
  function renderProduct(product){
    currentProduct=product;
    const box=$('employeeProductResult');
    if(!product){ box.innerHTML='<div class="employee-empty-result"><b>No product found</b><p>Check the barcode and try again.</p></div>'; return; }
    const variants=variantsOf(product);
    const optionName=productOptionName(product);
    const track=Boolean(product.track_inventory);
    const firstAvailableIndex=variants.findIndex(x=>variantAvailable(product,x));
    const grouped=new Map();
    variants.forEach((v,index)=>{const colour=clean(v.color)||'Default';if(!grouped.has(colour))grouped.set(colour,[]);grouped.get(colour).push({v,index});});
    const options=Array.from(grouped.entries()).map(([colour,items])=>`<section class="employee-colour-group ${colour==='Default'?'option-only':''}">${colour==='Default'?'':`<div class="employee-colour-head"><b>${esc(colour)}</b><small>${esc(track?stockText(items.reduce((sum,item)=>sum+Math.max(0,Number(item.v.stock||0)),0)):(items.some(item=>variantAvailable(product,item.v))?'Available':'Out of stock'))}</small></div>`}<div class="employee-size-grid">${items.map(({v,index})=>{
      const availableQty=Math.max(0,Number(v.stock||0));
      const available=variantAvailable(product,v);
      const size=clean(v.size)||'Standard';
      const availabilityText=track?stockText(availableQty):(available?'Available':'Out of stock');
      return `<label class="employee-variant-option ${available?'':'sold-out'}"><input type="radio" name="employeeVariant" value="${esc(v.id)}" ${index===firstAvailableIndex?'checked':''} ${available?'':'disabled'}><span><b>${esc(optionName)} ${esc(size)}</b><small>${esc(availabilityText)}${Number(v.price||0)>0?` · ${esc(money(v.price))}`:''}</small></span></label>`;
    }).join('')}</div></section>`).join('');
    const noAvailable=variants.length?variants.every(v=>!variantAvailable(product,v)):(track?Number(product.stock_quantity||0)<=0:!manualAvailable(product.stock_status));
    box.innerHTML=`<article class="employee-product-card">
      <div class="employee-product-main"><div class="employee-product-photo">${product.image_url?`<img decoding="async" src="${esc(imageUrl(product.image_url))}" alt="">`:'<span>No image</span>'}</div><div>${product.barcode?`<small>Barcode ${esc(product.barcode)}</small>`:''}<h2>${esc(product.name)}</h2><b class="employee-total-stock">${esc(stockSummary(product))}</b></div></div>
      ${!track?'<div class="employee-warning">Quantity tracking is off. Availability is controlled manually in Admin; sales can still be recorded.</div>':''}
      ${variants.length?`<div class="employee-variant-list"><h3>${grouped.size===1&&grouped.has('Default')?`Select ${esc(optionName)}`:`Select exact colour + ${esc(optionName)}`}</h3>${options}</div>`:'<div class="employee-standard-stock"><b>Standard item</b><span>'+esc(track?stockText(product.stock_quantity):(manualAvailable(product.stock_status)?'Available':'Out of stock'))+'</span></div>'}
      <form id="employeeSaleForm" class="employee-sale-form"><label>Sold quantity<input id="employeeSaleQty" type="number" min="1" step="1" inputmode="numeric" value="1" required></label><button type="submit" ${noAvailable?'disabled':''}>Mark Sold</button></form>
    </article>`;
    $('employeeSaleForm')?.addEventListener('submit',recordSale);
  }
  function renderSearchResults(rows){
    searchResults=Array.isArray(rows)?rows:[];
    currentProduct=null;
    const box=$('employeeProductResult');
    if(!searchResults.length){renderProduct(null);return;}
    if(searchResults.length===1){renderProduct(searchResults[0]);return;}
    box.innerHTML=`<div class="employee-search-results"><div class="employee-search-results-head"><b>${searchResults.length} products found</b><small>Choose the correct item to record a sale.</small></div>${searchResults.map((product,index)=>`<button type="button" data-employee-result="${index}"><span class="employee-search-photo">${product.image_url?`<img src="${esc(imageUrl(product.image_url))}" alt="">`:'No image'}</span><span><b>${esc(product.name)}</b><small>${product.barcode?`Barcode ${esc(product.barcode)} · `:''}${esc(stockSummary(product))}</small></span><strong>Select</strong></button>`).join('')}</div>`;
  }
  async function ensureBroadcast(){
    if(channelReady&&channel)return channel;
    if(channel){try{db().removeChannel(channel);}catch(_e){}}
    channel=db().channel(STORE_CHANNEL_NAME,{config:{broadcast:{self:false,ack:true}}});
    await new Promise(resolve=>{
      let done=false; const finish=()=>{if(done)return;done=true;resolve();};
      channel.subscribe(status=>{if(status==='SUBSCRIBED'){channelReady=true;finish();} if(['CHANNEL_ERROR','TIMED_OUT','CLOSED'].includes(status)){channelReady=false;finish();}});
      setTimeout(finish,700);
    });
    return channel;
  }
  async function broadcastStock(productId,variantId){
    try{
      const ch=await ensureBroadcast(); if(!ch||!channelReady)return;
      await ch.send({type:'broadcast',event:STORE_EVENT_NAME,payload:{tables:['products','product_variants'],action:'employee-sale',details:{productId,variantId:variantId||null},eventId:`employee-${Date.now()}-${Math.random().toString(36).slice(2)}`,at:Date.now()}});
    }catch(_e){}
  }
  function stopInventoryRealtime(){if(inventoryRefreshTimer){clearTimeout(inventoryRefreshTimer);inventoryRefreshTimer=null;}if(inventoryChannel){try{db().removeChannel(inventoryChannel);}catch(_e){}inventoryChannel=null;}}
  function startInventoryRealtime(){
    if(inventoryChannel)return;
    try{
      inventoryChannel=db().channel('wellone-employee-inventory-v88');
      ['products','product_variants'].forEach(table=>inventoryChannel.on('postgres_changes',{event:'*',schema:'public',table},payload=>{
        if(!currentProduct)return;
        const row=payload?.new||payload?.old||{};
        if(table==='products'&&clean(row.id)!==clean(currentProduct.id))return;
        if(table==='product_variants'&&row.product_id&&clean(row.product_id)!==clean(currentProduct.id))return;
        clearTimeout(inventoryRefreshTimer);
        inventoryRefreshTimer=setTimeout(async()=>{
          try{const {data,error}=await db().rpc('employee_get_product',{p_token:session?.token||'',p_product_id:currentProduct?.id});if(!error&&data)renderProduct(data);}catch(_e){}
        },90);
      }));
      inventoryChannel.subscribe();
    }catch(_e){inventoryChannel=null;}
  }
  async function login(event){
    event.preventDefault(); $('employeeLoginError').textContent='Checking...';
    const username=clean($('employeeLoginUsername').value),password=$('employeeLoginPassword').value||'';
    try{
      const {data,error}=await db().rpc('employee_sales_login',{p_username:username,p_password:password});
      if(error)throw error;
      saveSession(data); $('employeeLoginPassword').value=''; $('employeeLoginError').textContent=''; showDesk();
    }catch(error){ $('employeeLoginError').textContent=error.message||'Login failed.'; }
  }
  async function findBarcode(event){
    event?.preventDefault(); const query=clean($('employeeBarcodeInput').value); if(!query)return;
    setStatus('Searching products...','loading'); $('employeeProductResult').innerHTML='';
    try{
      let {data,error}=await db().rpc('employee_search_products',{p_token:session?.token||'',p_query:query});
      if(error&&/employee_search_products|function|schema cache/i.test(error.message||'')){
        const fallback=await db().rpc('employee_get_product_by_barcode',{p_token:session?.token||'',p_barcode:query});
        data=fallback.data?[fallback.data]:[]; error=fallback.error;
      }
      if(error)throw error;
      const rows=Array.isArray(data)?data:[];
      renderSearchResults(rows); setStatus(rows.length?`${rows.length} product${rows.length===1?'':'s'} found.`:'No matching product found.',rows.length?'ok':'error');
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
      renderProduct(data); setStatus(currentProduct.track_inventory?`Sold ${qty} unit${qty===1?'':'s'}. Stock updated live.`:`Sale recorded (${qty}). Availability remains manual.`,'ok');
      broadcastStock(currentProduct.id,variantId).catch(()=>{});
    }catch(error){
      if(/expired|login/i.test(error.message||'')){showLogin('Session expired. Login again.');return;}
      setStatus(error.message||'Could not record sale.','error'); button.disabled=false;
    }
  }
  function logout(){ stopInventoryRealtime(); if(channel){try{db().removeChannel(channel);}catch(_e){}} channel=null;channelReady=false;showLogin(''); }

  $('employeeLoginForm').addEventListener('submit',login);
  $('employeeBarcodeForm').addEventListener('submit',findBarcode);
  $('employeeLogoutBtn').addEventListener('click',logout);
  $('employeeProductResult').addEventListener('click',event=>{const button=event.target.closest('[data-employee-result]');if(!button)return;const product=searchResults[Number(button.dataset.employeeResult)];if(product){renderProduct(product);setStatus(`${product.name} loaded.`,'ok');}});
  session=loadSession(); if(session?.token&&session?.username)showDesk(); else showLogin('');
})();

-- WellOne v100/v104: hidden customer-search keywords + employee product management.
-- Run once AFTER the existing WellOne migrations. Safe to run repeatedly.

alter table public.products
  add column if not exists search_keywords text not null default '';



-- Short-lived capability paths let a logged-in employee upload product images
-- without giving the anonymous public role unrestricted Storage write access.
create table if not exists public.employee_upload_tokens (
  token_hash text primary key,
  employee_id uuid not null references public.employees(id) on delete cascade,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
alter table public.employee_upload_tokens enable row level security;
revoke all on table public.employee_upload_tokens from anon,authenticated;

create or replace function public.employee_create_upload_path(p_token text,p_extension text default 'webp')
returns text
language plpgsql security definer set search_path=public,extensions as $$
declare v_emp uuid; v_capability text; v_ext text;
begin
  v_emp := public.employee_from_token(p_token);
  if v_emp is null then raise exception 'Employee login expired.'; end if;
  delete from public.employee_upload_tokens where expires_at < now();
  v_capability := replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
  v_ext := lower(regexp_replace(coalesce(p_extension,'webp'),'[^a-z0-9]','','g'));
  if v_ext not in ('jpg','jpeg','png','webp','gif','avif') then v_ext:='webp'; end if;
  insert into public.employee_upload_tokens(token_hash,employee_id,expires_at)
  values(encode(digest(v_capability,'sha256'),'hex'),v_emp,now()+interval '10 minutes');
  return 'employee/'||v_capability||'/'||replace(gen_random_uuid()::text,'-','')||'.'||v_ext;
end; $$;
revoke all on function public.employee_create_upload_path(text,text) from public;
grant execute on function public.employee_create_upload_path(text,text) to anon,authenticated;

create or replace function public.employee_storage_path_allowed(p_name text)
returns boolean
language sql security definer set search_path=public,extensions as $$
  select exists(
    select 1
    from public.employee_upload_tokens t
    join public.employees e on e.id=t.employee_id and e.is_active=true
    where t.token_hash=encode(digest(split_part(coalesce(p_name,''),'/',2),'sha256'),'hex')
      and t.expires_at>now()
      and split_part(coalesce(p_name,''),'/',1)='employee'
  );
$$;
revoke all on function public.employee_storage_path_allowed(text) from public;
grant execute on function public.employee_storage_path_allowed(text) to anon,authenticated;

drop policy if exists "Employees may upload managed product images" on storage.objects;
create policy "Employees may upload managed product images"
  on storage.objects for insert to anon,authenticated
  with check (bucket_id='product-images' and public.employee_storage_path_allowed(name));

create or replace function public.employee_manage_meta(p_token text)
returns jsonb
language plpgsql security definer set search_path=public,extensions as $$
declare v_emp uuid;
begin
  v_emp := public.employee_from_token(p_token);
  if v_emp is null then raise exception 'Employee login expired.'; end if;
  return jsonb_build_object(
    'categories',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',c.name) order by c.name) from public.categories c where coalesce(c.is_active,true)=true),'[]'::jsonb),
    'subcategories',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'category_id',s.category_id,'name',s.name) order by s.name) from public.subcategories s where coalesce(s.is_active,true)=true),'[]'::jsonb)
  );
end; $$;
revoke all on function public.employee_manage_meta(text) from public;
grant execute on function public.employee_manage_meta(text) to anon,authenticated;

create or replace function public.employee_manage_list_products(p_token text,p_query text default '')
returns jsonb
language plpgsql security definer set search_path=public,extensions as $$
declare v_emp uuid; q text:=lower(btrim(coalesce(p_query,'')));
begin
  v_emp := public.employee_from_token(p_token);
  if v_emp is null then raise exception 'Employee login expired.'; end if;
  return coalesce((
    select jsonb_agg(x.obj order by x.updated_at desc nulls last,x.name)
    from (
      select p.updated_at,p.name,jsonb_build_object(
        'id',p.id,'name',p.name,'barcode',p.barcode,'barcode_enabled',p.barcode_enabled,
        'image_url',p.main_image_url,'price',p.price,'mrp',p.mrp,'status',p.status,'stock_status',p.stock_status,
        'stock_quantity',p.stock_quantity,'track_inventory',p.track_inventory,'search_keywords',p.search_keywords,
        'category_id',p.category_id,'subcategory_id',p.subcategory_id,
        'category_name',c.name,'subcategory_name',s.name,
        'variant_count',(select count(*) from public.product_variants v where v.product_id=p.id)
      ) obj
      from public.products p
      left join public.categories c on c.id=p.category_id
      left join public.subcategories s on s.id=p.subcategory_id
      where q='' or lower(coalesce(p.name,'')) like '%'||q||'%'
        or lower(coalesce(p.barcode,'')) like '%'||q||'%'
        or lower(coalesce(p.search_keywords,'')) like '%'||q||'%'
      order by p.updated_at desc nulls last,p.name
      limit 120
    ) x
  ),'[]'::jsonb);
end; $$;
revoke all on function public.employee_manage_list_products(text,text) from public;
grant execute on function public.employee_manage_list_products(text,text) to anon,authenticated;

create or replace function public.employee_manage_get_product(p_token text,p_product_id uuid)
returns jsonb
language plpgsql security definer set search_path=public,extensions as $$
declare v_emp uuid; result jsonb;
begin
  v_emp := public.employee_from_token(p_token);
  if v_emp is null then raise exception 'Employee login expired.'; end if;
  select jsonb_build_object(
    'id',p.id,'name',p.name,'description',p.description,'search_keywords',p.search_keywords,
    'category_id',p.category_id,'subcategory_id',p.subcategory_id,
    'mrp',p.mrp,'price',p.price,'image_url',p.main_image_url,
    'status',p.status,'stock_status',p.stock_status,'stock_quantity',p.stock_quantity,'track_inventory',p.track_inventory,
    'barcode',p.barcode,'barcode_enabled',p.barcode_enabled,'option_title',p.option_title,'sizes',p.sizes,'colors',p.colors,
    'variants',coalesce((select jsonb_agg(jsonb_build_object(
      'id',v.id,'color',coalesce(v.color,v.unit,''),'size',coalesce(v.size,v.label,''),
      'mrp',v.mrp,'price',v.price,'image_url',v.image_url,'stock',v.stock,'stock_status',v.stock_status
    ) order by v.sort_order,v.id) from public.product_variants v where v.product_id=p.id),'[]'::jsonb)
  ) into result from public.products p where p.id=p_product_id;
  if result is null then raise exception 'Product not found.'; end if;
  return result;
end; $$;
revoke all on function public.employee_manage_get_product(text,uuid) from public;
grant execute on function public.employee_manage_get_product(text,uuid) to anon,authenticated;

create or replace function public.employee_manage_save_product(p_token text,p_product jsonb,p_variants jsonb default '[]'::jsonb)
returns jsonb
language plpgsql security definer set search_path=public,extensions as $$
declare
  v_emp uuid; v_id uuid; v_existing boolean:=false; item jsonb; v_vid uuid; v_keep uuid[]:='{}'::uuid[];
  v_name text:=btrim(coalesce(p_product->>'name',''));
  v_track boolean:=coalesce((p_product->>'track_inventory')::boolean,false);
  v_stock integer:=greatest(0,coalesce(nullif(p_product->>'stock_quantity','')::integer,0));
  v_status text:=case when coalesce(p_product->>'status','active')='hidden' then 'hidden' else 'active' end;
  v_stock_status text:=case when coalesce(p_product->>'stock_status','in_stock')='out_of_stock' then 'out_of_stock' else 'in_stock' end;
  v_category uuid:=nullif(p_product->>'category_id','')::uuid;
  v_subcategory uuid:=nullif(p_product->>'subcategory_id','')::uuid;
  v_slug text;
begin
  v_emp := public.employee_from_token(p_token);
  if v_emp is null then raise exception 'Employee login expired.'; end if;
  if v_name='' then raise exception 'Enter product name.'; end if;
  if v_category is null then raise exception 'Select category.'; end if;
  if not exists(select 1 from public.categories where id=v_category) then raise exception 'Category not found.'; end if;
  if v_subcategory is not null and not exists(select 1 from public.subcategories where id=v_subcategory and category_id=v_category) then raise exception 'Subcategory does not belong to the selected category.'; end if;

  if nullif(p_product->>'id','') is not null then
    v_id := (p_product->>'id')::uuid;
    select exists(select 1 from public.products where id=v_id) into v_existing;
    if not v_existing then raise exception 'Product not found.'; end if;
  else
    v_id := gen_random_uuid();
  end if;
  v_slug := regexp_replace(lower(v_name),'[^a-z0-9]+','-','g')||'-'||substr(replace(v_id::text,'-',''),1,8);

  if v_existing then
    update public.products set
      category_id=v_category,subcategory_id=v_subcategory,name=v_name,slug=v_slug,
      description=coalesce(p_product->>'description',''),search_keywords=coalesce(p_product->>'search_keywords',''),
      mrp=nullif(p_product->>'mrp','')::numeric,price=nullif(p_product->>'price','')::numeric,
      main_image_url=coalesce(p_product->>'image_url',''),
      option_title=coalesce(p_product->>'option_title',''),
      status=v_status,stock_status=case when v_track and v_stock<=0 and jsonb_array_length(coalesce(p_variants,'[]'::jsonb))=0 then 'out_of_stock' else v_stock_status end,
      stock_quantity=case when v_track then v_stock else 0 end,track_inventory=v_track,
      barcode=nullif(btrim(coalesce(p_product->>'barcode','')),''),barcode_enabled=coalesce((p_product->>'barcode_enabled')::boolean,false),updated_at=now()
    where id=v_id;
  else
    insert into public.products(
      id,category_id,subcategory_id,name,slug,description,search_keywords,mrp,price,main_image_url,option_title,sizes,colors,
      status,stock_status,stock_quantity,track_inventory,barcode,barcode_enabled,created_at,updated_at
    ) values(
      v_id,v_category,v_subcategory,v_name,v_slug,coalesce(p_product->>'description',''),coalesce(p_product->>'search_keywords',''),
      nullif(p_product->>'mrp','')::numeric,nullif(p_product->>'price','')::numeric,coalesce(p_product->>'image_url',''),coalesce(p_product->>'option_title',''),
      'Standard','Default',v_status,case when v_track and v_stock<=0 and jsonb_array_length(coalesce(p_variants,'[]'::jsonb))=0 then 'out_of_stock' else v_stock_status end,
      case when v_track then v_stock else 0 end,v_track,nullif(btrim(coalesce(p_product->>'barcode','')),''),coalesce((p_product->>'barcode_enabled')::boolean,false),now(),now()
    );
  end if;

  for item in select value from jsonb_array_elements(coalesce(p_variants,'[]'::jsonb)) loop
    v_vid := nullif(item->>'id','')::uuid;
    if v_vid is not null and exists(select 1 from public.product_variants where id=v_vid and product_id=v_id) then
      update public.product_variants set
        label=coalesce(nullif(btrim(item->>'size'),''),'Standard'),unit=coalesce(item->>'color',''),color=nullif(btrim(coalesce(item->>'color','')),''),size=coalesce(nullif(btrim(item->>'size'),''),'Standard'),
        mrp=nullif(item->>'mrp','')::numeric,price=nullif(item->>'price','')::numeric,image_url=coalesce(item->>'image_url',''),
        stock=case when v_track then greatest(0,coalesce(nullif(item->>'stock','')::integer,0)) else 0 end,
        stock_status=case when coalesce(item->>'stock_status','in_stock')='hidden' then 'hidden' when v_track and greatest(0,coalesce(nullif(item->>'stock','')::integer,0))<=0 then 'out_of_stock' when coalesce(item->>'stock_status','in_stock')='out_of_stock' then 'out_of_stock' else 'in_stock' end,
        sort_order=coalesce(nullif(item->>'sort_order','')::integer,0)
      where id=v_vid and product_id=v_id;
    else
      insert into public.product_variants(product_id,label,unit,color,size,mrp,price,image_url,stock,stock_status,sort_order)
      values(v_id,coalesce(nullif(btrim(item->>'size'),''),'Standard'),coalesce(item->>'color',''),nullif(btrim(coalesce(item->>'color','')),''),coalesce(nullif(btrim(item->>'size'),''),'Standard'),
        nullif(item->>'mrp','')::numeric,nullif(item->>'price','')::numeric,coalesce(item->>'image_url',''),
        case when v_track then greatest(0,coalesce(nullif(item->>'stock','')::integer,0)) else 0 end,
        case when coalesce(item->>'stock_status','in_stock')='hidden' then 'hidden' when v_track and greatest(0,coalesce(nullif(item->>'stock','')::integer,0))<=0 then 'out_of_stock' when coalesce(item->>'stock_status','in_stock')='out_of_stock' then 'out_of_stock' else 'in_stock' end,
        coalesce(nullif(item->>'sort_order','')::integer,0)) returning id into v_vid;
    end if;
    v_keep := array_append(v_keep,v_vid);
  end loop;

  if coalesce(array_length(v_keep,1),0)=0 then
    delete from public.product_variants where product_id=v_id;
  else
    delete from public.product_variants where product_id=v_id and not(id=any(v_keep));
  end if;

  if exists(select 1 from public.product_variants where product_id=v_id) then
    update public.products p set
      sizes=coalesce((select string_agg(distinct coalesce(nullif(v.size,''),nullif(v.label,'')),', ' order by coalesce(nullif(v.size,''),nullif(v.label,''))) from public.product_variants v where v.product_id=v_id and coalesce(v.stock_status,'in_stock')<>'hidden'),'Standard'),
      colors=coalesce((select string_agg(distinct coalesce(nullif(v.color,''),nullif(v.unit,'')),', ' order by coalesce(nullif(v.color,''),nullif(v.unit,''))) from public.product_variants v where v.product_id=v_id and coalesce(v.stock_status,'in_stock')<>'hidden' and coalesce(nullif(v.color,''),nullif(v.unit,'')) is not null),'Default'),
      main_image_url=case when coalesce(p.main_image_url,'')='' then coalesce((select nullif(v.image_url,'') from public.product_variants v where v.product_id=v_id and nullif(v.image_url,'') is not null order by v.sort_order,v.id limit 1),'') else p.main_image_url end,
      updated_at=now() where p.id=v_id;
    if v_track then perform public.wellone_recalc_product_stock(v_id); end if;
  else
    update public.products set sizes='Standard',colors='Default',updated_at=now() where id=v_id;
  end if;
  return public.employee_manage_get_product(p_token,v_id);
exception when unique_violation then
  raise exception 'That barcode is already used by another product.';
end; $$;
revoke all on function public.employee_manage_save_product(text,jsonb,jsonb) from public;
grant execute on function public.employee_manage_save_product(text,jsonb,jsonb) to anon,authenticated;

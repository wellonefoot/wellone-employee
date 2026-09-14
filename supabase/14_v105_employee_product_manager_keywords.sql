-- WellOne v105
-- 1) Hidden product search keywords
-- 2) Secure employee product add/edit/delete RPCs
-- 3) Short-lived employee Storage upload capability
-- Run once in Supabase SQL Editor before deploying v105 Admin/Customer/Employee.

create extension if not exists pgcrypto;

alter table public.products
  add column if not exists search_keywords text not null default '';

-- Short-lived upload capabilities. The raw capability is returned only once;
-- only its SHA-256 hash is stored in the database.
create table if not exists public.employee_upload_tokens (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id) on delete cascade,
  token_hash text not null unique,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
create index if not exists employee_upload_tokens_expiry_idx on public.employee_upload_tokens(expires_at);
alter table public.employee_upload_tokens enable row level security;
revoke all on table public.employee_upload_tokens from anon, authenticated;

create or replace function public.employee_issue_upload_token(p_token text)
returns jsonb
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
  v_employee uuid;
  v_raw text := replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-','');
  v_expires timestamptz := now() + interval '10 minutes';
begin
  v_employee := public.employee_from_token(p_token);
  if v_employee is null then raise exception 'Employee login expired.'; end if;
  delete from public.employee_upload_tokens where expires_at <= now();
  insert into public.employee_upload_tokens(employee_id,token_hash,expires_at)
  values(v_employee,encode(digest(v_raw,'sha256'),'hex'),v_expires);
  return jsonb_build_object('token',v_raw,'expires_at',v_expires);
end;
$$;
revoke all on function public.employee_issue_upload_token(text) from public;
grant execute on function public.employee_issue_upload_token(text) to anon, authenticated;

create or replace function public.employee_upload_token_valid(p_raw_token text)
returns boolean
language sql
security definer
stable
set search_path=public,extensions
as $$
  select exists(
    select 1
      from public.employee_upload_tokens u
      join public.employees e on e.id=u.employee_id
     where u.token_hash=encode(digest(coalesce(p_raw_token,''),'sha256'),'hex')
       and u.expires_at>now()
       and e.is_active=true
  );
$$;
revoke all on function public.employee_upload_token_valid(text) from public;
grant execute on function public.employee_upload_token_valid(text) to anon, authenticated;

-- Employee files are uploaded under employee-uploads/<10-minute-capability>/...
-- The capability expires quickly; exposing the final public image URL later does
-- not grant a lasting upload permission.
drop policy if exists "WellOne employee temporary product upload" on storage.objects;
create policy "WellOne employee temporary product upload"
on storage.objects
for insert
to anon, authenticated
with check (
  bucket_id='product-images'
  and (storage.foldername(name))[1]='employee-uploads'
  and public.employee_upload_token_valid((storage.foldername(name))[2])
);

create or replace function public.employee_manage_meta(p_token text)
returns jsonb
language plpgsql
security definer
set search_path=public,extensions
as $$
declare v_employee uuid;
begin
  v_employee := public.employee_from_token(p_token);
  if v_employee is null then raise exception 'Employee login expired.'; end if;
  return jsonb_build_object(
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',c.id,'name',c.name,'image_url',c.image_url,'storage_path',c.storage_path,
        'description',c.description,'sort_order',c.sort_order,'is_active',c.is_active
      ) order by c.sort_order nulls last,c.name)
      from public.categories c
      where coalesce(c.is_active,true)=true
    ),'[]'::jsonb),
    'subcategories', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',s.id,'category_id',s.category_id,'name',s.name,'sort_order',s.sort_order,'is_active',s.is_active
      ) order by s.sort_order nulls last,s.name)
      from public.subcategories s
      where coalesce(s.is_active,true)=true
    ),'[]'::jsonb)
  );
end;
$$;
revoke all on function public.employee_manage_meta(text) from public;
grant execute on function public.employee_manage_meta(text) to anon, authenticated;

create or replace function public.employee_manage_list_products(
  p_token text,
  p_query text default '',
  p_category_id uuid default null,
  p_offset integer default 0,
  p_limit integer default 20
)
returns jsonb
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
  v_employee uuid;
  v_query text := lower(btrim(coalesce(p_query,'')));
  v_limit integer := least(greatest(coalesce(p_limit,20),1),50);
  v_items jsonb;
begin
  v_employee := public.employee_from_token(p_token);
  if v_employee is null then raise exception 'Employee login expired.'; end if;

  select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb)
    into v_items
  from (
    select p.id,p.name,p.slug,p.description,p.search_keywords,p.mrp,p.price,p.main_image_url,
           p.status,p.stock_status,p.stock_quantity,p.track_inventory,p.barcode,p.barcode_enabled,
           p.sizes,p.colors,p.option_title,p.terms,p.created_at,p.updated_at,p.sort_order,
           p.category_id,p.subcategory_id,c.name as category_name,s.name as subcategory_name
      from public.products p
      left join public.categories c on c.id=p.category_id
      left join public.subcategories s on s.id=p.subcategory_id
     where (p_category_id is null or p.category_id=p_category_id)
       and (
         v_query=''
         or lower(coalesce(p.name,'')) like '%'||v_query||'%'
         or lower(coalesce(p.description,'')) like '%'||v_query||'%'
         or lower(coalesce(p.search_keywords,'')) like '%'||v_query||'%'
         or lower(coalesce(p.barcode,'')) like '%'||v_query||'%'
         or lower(coalesce(c.name,'')) like '%'||v_query||'%'
         or lower(coalesce(s.name,'')) like '%'||v_query||'%'
         or exists(
           select 1 from public.product_variants v
           where v.product_id=p.id and (
             lower(coalesce(v.label,'')) like '%'||v_query||'%'
             or lower(coalesce(v.size,'')) like '%'||v_query||'%'
             or lower(coalesce(v.color,'')) like '%'||v_query||'%'
             or lower(coalesce(v.unit,'')) like '%'||v_query||'%'
           )
         )
       )
     order by p.updated_at desc nulls last,p.created_at desc nulls last
     offset greatest(coalesce(p_offset,0),0)
     limit v_limit+1
  ) x;

  return jsonb_build_object(
    'items',coalesce(v_items,'[]'::jsonb),
    'has_more',jsonb_array_length(coalesce(v_items,'[]'::jsonb))>v_limit,
    'limit',v_limit
  );
end;
$$;
revoke all on function public.employee_manage_list_products(text,text,uuid,integer,integer) from public;
grant execute on function public.employee_manage_list_products(text,text,uuid,integer,integer) to anon, authenticated;

create or replace function public.employee_manage_get_product(p_token text,p_product_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public,extensions
as $$
declare v_employee uuid; v_result jsonb;
begin
  v_employee := public.employee_from_token(p_token);
  if v_employee is null then raise exception 'Employee login expired.'; end if;

  select jsonb_build_object(
    'id',p.id,'name',p.name,'slug',p.slug,'description',p.description,'search_keywords',p.search_keywords,
    'mrp',p.mrp,'price',p.price,'main_image_url',p.main_image_url,'status',p.status,'stock_status',p.stock_status,
    'stock_quantity',p.stock_quantity,'track_inventory',p.track_inventory,'barcode',p.barcode,'barcode_enabled',p.barcode_enabled,
    'sizes',p.sizes,'colors',p.colors,'option_title',p.option_title,'terms',p.terms,'created_at',p.created_at,'updated_at',p.updated_at,'sort_order',p.sort_order,
    'category_id',p.category_id,'category_name',c.name,'subcategory_id',p.subcategory_id,'subcategory_name',s.name,
    'images',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'image_url',i.image_url,'storage_path',i.storage_path,'sort_order',i.sort_order) order by i.sort_order,i.id) from public.product_images i where i.product_id=p.id),'[]'::jsonb),
    'variants',coalesce((select jsonb_agg(jsonb_build_object(
      'id',v.id,'label',v.label,'unit',v.unit,'color',v.color,'size',v.size,'mrp',v.mrp,'price',v.price,
      'image_url',v.image_url,'image_urls',v.image_urls,'storage_paths',v.storage_paths,'terms',v.terms,
      'stock',v.stock,'stock_status',v.stock_status,'sort_order',v.sort_order
    ) order by v.sort_order,v.id) from public.product_variants v where v.product_id=p.id),'[]'::jsonb)
  ) into v_result
  from public.products p
  left join public.categories c on c.id=p.category_id
  left join public.subcategories s on s.id=p.subcategory_id
  where p.id=p_product_id;

  return v_result;
end;
$$;
revoke all on function public.employee_manage_get_product(text,uuid) from public;
grant execute on function public.employee_manage_get_product(text,uuid) to anon, authenticated;

create or replace function public.employee_manage_save_product(p_token text,p_payload jsonb)
returns uuid
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
  v_employee uuid;
  v_product_id uuid := nullif(p_payload->>'id','')::uuid;
  v_category_id uuid := nullif(p_payload->>'category_id','')::uuid;
  v_subcategory_id uuid := nullif(p_payload->>'subcategory_id','')::uuid;
  v_subcategory_name text := btrim(coalesce(p_payload->>'subcategory_name',''));
  v_name text := btrim(coalesce(p_payload->>'name',''));
  v_barcode text := nullif(btrim(coalesce(p_payload->>'barcode','')),'');
  v_barcode_enabled boolean := coalesce((p_payload->>'barcode_enabled')::boolean,false);
  v_image jsonb;
  v_variant jsonb;
  v_variant_id uuid;
  v_keep_ids uuid[] := '{}'::uuid[];
  v_terms text[];
  v_urls text[];
  v_paths text[];
  v_now timestamptz := now();
begin
  v_employee := public.employee_from_token(p_token);
  if v_employee is null then raise exception 'Employee login expired.'; end if;
  if v_category_id is null then raise exception 'Select a category.'; end if;
  if v_name='' then raise exception 'Enter the product name.'; end if;
  if not exists(select 1 from public.categories c where c.id=v_category_id and coalesce(c.is_active,true)=true) then raise exception 'Selected category is not available.'; end if;

  if v_subcategory_id is null and v_subcategory_name<>'' then
    select s.id into v_subcategory_id
      from public.subcategories s
     where s.category_id=v_category_id and lower(btrim(s.name))=lower(v_subcategory_name)
     limit 1;
    if v_subcategory_id is null then
      insert into public.subcategories(category_id,name,slug,is_active)
      values(v_category_id,v_subcategory_name,trim(both '-' from regexp_replace(lower(v_subcategory_name),'[^a-z0-9]+','-','g')),true)
      returning id into v_subcategory_id;
    end if;
  end if;

  if v_barcode_enabled and v_barcode is null then raise exception 'Enter a barcode, or turn Barcode identification off.'; end if;
  if v_barcode_enabled and exists(select 1 from public.products p where p.barcode=v_barcode and (v_product_id is null or p.id<>v_product_id)) then
    raise exception 'That barcode is already linked to another product.';
  end if;

  v_terms := array(select jsonb_array_elements_text(coalesce(p_payload->'terms','[]'::jsonb)));

  if v_product_id is null then
    insert into public.products(
      category_id,subcategory_id,name,slug,description,search_keywords,mrp,price,main_image_url,option_title,sizes,colors,terms,
      status,stock_status,stock_quantity,track_inventory,barcode,barcode_enabled,created_at,updated_at
    ) values(
      v_category_id,v_subcategory_id,v_name,coalesce(nullif(p_payload->>'slug',''),trim(both '-' from regexp_replace(lower(v_name),'[^a-z0-9]+','-','g'))||'-'||extract(epoch from v_now)::bigint),
      coalesce(p_payload->>'description',''),coalesce(p_payload->>'search_keywords',''),nullif(p_payload->>'mrp','')::numeric,nullif(p_payload->>'price','')::numeric,
      coalesce(p_payload->>'main_image_url',''),coalesce(p_payload->>'option_title',''),coalesce(p_payload->>'sizes','Standard'),coalesce(p_payload->>'colors','Default'),v_terms,
      coalesce(nullif(p_payload->>'status',''),'active'),coalesce(nullif(p_payload->>'stock_status',''),'in_stock'),greatest(coalesce((p_payload->>'stock_quantity')::integer,0),0),
      coalesce((p_payload->>'track_inventory')::boolean,false),v_barcode,v_barcode_enabled,v_now,v_now
    ) returning id into v_product_id;
  else
    update public.products set
      category_id=v_category_id,subcategory_id=v_subcategory_id,name=v_name,
      slug=coalesce(nullif(p_payload->>'slug',''),slug),description=coalesce(p_payload->>'description',''),search_keywords=coalesce(p_payload->>'search_keywords',''),
      mrp=nullif(p_payload->>'mrp','')::numeric,price=nullif(p_payload->>'price','')::numeric,main_image_url=coalesce(p_payload->>'main_image_url',''),
      option_title=coalesce(p_payload->>'option_title',''),sizes=coalesce(p_payload->>'sizes','Standard'),colors=coalesce(p_payload->>'colors','Default'),terms=v_terms,
      status=coalesce(nullif(p_payload->>'status',''),'active'),stock_status=coalesce(nullif(p_payload->>'stock_status',''),'in_stock'),stock_quantity=greatest(coalesce((p_payload->>'stock_quantity')::integer,0),0),
      track_inventory=coalesce((p_payload->>'track_inventory')::boolean,false),barcode=v_barcode,barcode_enabled=v_barcode_enabled,updated_at=v_now
    where id=v_product_id;
    if not found then raise exception 'Product not found.'; end if;
  end if;

  delete from public.product_images where product_id=v_product_id;
  for v_image in select value from jsonb_array_elements(coalesce(p_payload->'images','[]'::jsonb)) loop
    if nullif(v_image->>'url','') is not null then
      insert into public.product_images(product_id,image_url,storage_path,sort_order)
      values(v_product_id,v_image->>'url',nullif(v_image->>'path',''),coalesce((v_image->>'sort_order')::integer,0));
    end if;
  end loop;

  select coalesce(array_agg((value->>'id')::uuid),'{}'::uuid[]) into v_keep_ids
    from jsonb_array_elements(coalesce(p_payload->'variants','[]'::jsonb))
   where nullif(value->>'id','') is not null;
  delete from public.product_variants where product_id=v_product_id and not (id=any(v_keep_ids));

  for v_variant in select value from jsonb_array_elements(coalesce(p_payload->'variants','[]'::jsonb)) loop
    v_variant_id := nullif(v_variant->>'id','')::uuid;
    v_terms := array(select jsonb_array_elements_text(coalesce(v_variant->'terms','[]'::jsonb)));
    v_urls := array(select jsonb_array_elements_text(coalesce(v_variant->'image_urls','[]'::jsonb)));
    v_paths := array(select jsonb_array_elements_text(coalesce(v_variant->'storage_paths','[]'::jsonb)));
    if v_variant_id is null then
      insert into public.product_variants(
        product_id,label,unit,color,size,mrp,price,image_url,image_urls,storage_paths,terms,stock,stock_status,sort_order
      ) values(
        v_product_id,coalesce(nullif(v_variant->>'size',''),'Standard'),coalesce(v_variant->>'color',''),nullif(v_variant->>'color',''),coalesce(nullif(v_variant->>'size',''),'Standard'),
        nullif(v_variant->>'mrp','')::numeric,nullif(v_variant->>'price','')::numeric,coalesce(v_urls[1],''),v_urls,v_paths,v_terms,
        greatest(coalesce((v_variant->>'stock')::integer,0),0),coalesce(nullif(v_variant->>'stock_status',''),'in_stock'),coalesce((v_variant->>'sort_order')::integer,0)
      );
    else
      update public.product_variants set
        label=coalesce(nullif(v_variant->>'size',''),'Standard'),unit=coalesce(v_variant->>'color',''),color=nullif(v_variant->>'color',''),size=coalesce(nullif(v_variant->>'size',''),'Standard'),
        mrp=nullif(v_variant->>'mrp','')::numeric,price=nullif(v_variant->>'price','')::numeric,image_url=coalesce(v_urls[1],''),image_urls=v_urls,storage_paths=v_paths,terms=v_terms,
        stock=greatest(coalesce((v_variant->>'stock')::integer,0),0),stock_status=coalesce(nullif(v_variant->>'stock_status',''),'in_stock'),sort_order=coalesce((v_variant->>'sort_order')::integer,0)
      where id=v_variant_id and product_id=v_product_id;
      if not found then raise exception 'One edited option no longer exists. Reopen the product and try again.'; end if;
    end if;
  end loop;

  return v_product_id;
end;
$$;
revoke all on function public.employee_manage_save_product(text,jsonb) from public;
grant execute on function public.employee_manage_save_product(text,jsonb) to anon, authenticated;

create or replace function public.employee_manage_delete_product(p_token text,p_product_id uuid)
returns void
language plpgsql
security definer
set search_path=public,extensions
as $$
declare v_employee uuid;
begin
  v_employee := public.employee_from_token(p_token);
  if v_employee is null then raise exception 'Employee login expired.'; end if;
  delete from public.product_images where product_id=p_product_id;
  delete from public.product_variants where product_id=p_product_id;
  delete from public.products where id=p_product_id;
end;
$$;
revoke all on function public.employee_manage_delete_product(text,uuid) from public;
grant execute on function public.employee_manage_delete_product(text,uuid) to anon, authenticated;

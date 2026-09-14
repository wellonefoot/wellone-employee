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
-- WellOne v106 — staff account visibility, secure admin credential retrieval, multi-device employee sessions
-- Run after v105. Safe to run more than once.

create extension if not exists pgcrypto with schema extensions;

-- A server-side secret used only by SECURITY DEFINER functions below.
-- It is never granted to browser roles.
create table if not exists public.employee_credential_secret (
  singleton boolean primary key default true check (singleton = true),
  secret text not null,
  created_at timestamptz not null default now()
);

insert into public.employee_credential_secret(singleton, secret)
values (true, replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-',''))
on conflict (singleton) do nothing;

create table if not exists public.employee_admin_credentials (
  employee_id uuid primary key references public.employees(id) on delete cascade,
  password_cipher bytea not null,
  updated_at timestamptz not null default now()
);

alter table public.employee_credential_secret enable row level security;
alter table public.employee_admin_credentials enable row level security;
revoke all on table public.employee_credential_secret, public.employee_admin_credentials from anon, authenticated;

-- List every staff account for admins. Passwords are decrypted only inside this
-- admin-only SECURITY DEFINER function. Existing legacy passwords that were
-- never stored reversibly remain unavailable until reset/imported once.
drop function if exists public.admin_list_employees();
create function public.admin_list_employees()
returns table(
  id uuid,
  username text,
  is_active boolean,
  password text,
  active_sessions bigint,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path=public,extensions
as $$
declare v_secret text;
begin
  if auth.uid() is null or not exists(select 1 from public.admin_users where id=auth.uid()) then
    raise exception 'Admin login required.';
  end if;

  select s.secret into v_secret from public.employee_credential_secret s where s.singleton=true;

  return query
  select
    e.id,
    e.username,
    e.is_active,
    case when c.password_cipher is null then null else pgp_sym_decrypt(c.password_cipher, v_secret) end as password,
    (select count(*) from public.employee_sessions es where es.employee_id=e.id and es.expires_at>now())::bigint as active_sessions,
    e.created_at,
    e.updated_at
  from public.employees e
  left join public.employee_admin_credentials c on c.employee_id=e.id
  order by e.is_active desc, e.created_at desc;
end;
$$;
revoke all on function public.admin_list_employees() from public;
grant execute on function public.admin_list_employees() to authenticated;

-- Create/update a staff account. Employee authentication still uses the salted
-- password hash. A reversible encrypted copy is retained only so an authorized
-- admin can retrieve the staff credential from any admin device.
drop function if exists public.admin_save_employee(text,text,uuid);
create function public.admin_save_employee(p_username text, p_password text, p_employee_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
  v_id uuid;
  v_secret text;
  v_password_changed boolean := nullif(p_password,'') is not null;
begin
  if auth.uid() is null or not exists(select 1 from public.admin_users where id=auth.uid()) then
    raise exception 'Admin login required.';
  end if;
  if nullif(btrim(p_username),'') is null then raise exception 'Enter employee username.'; end if;
  if p_employee_id is null and length(coalesce(p_password,'')) < 4 then raise exception 'Password must be at least 4 characters.'; end if;
  if v_password_changed and length(p_password) < 4 then raise exception 'Password must be at least 4 characters.'; end if;

  select s.secret into v_secret from public.employee_credential_secret s where s.singleton=true;
  if v_secret is null then raise exception 'Employee credential security is not initialized.'; end if;

  if p_employee_id is null then
    insert into public.employees(username,password_hash,created_by)
    values(btrim(p_username),crypt(p_password,gen_salt('bf')),auth.uid())
    returning id into v_id;
    insert into public.employee_admin_credentials(employee_id,password_cipher,updated_at)
    values(v_id,pgp_sym_encrypt(p_password,v_secret,'cipher-algo=aes256'),now())
    on conflict (employee_id) do update set password_cipher=excluded.password_cipher,updated_at=now();
  else
    update public.employees
       set username=btrim(p_username),
           password_hash=case when v_password_changed then crypt(p_password,gen_salt('bf')) else password_hash end,
           updated_at=now()
     where id=p_employee_id
     returning id into v_id;
    if v_id is null then raise exception 'Employee not found.'; end if;

    if v_password_changed then
      insert into public.employee_admin_credentials(employee_id,password_cipher,updated_at)
      values(v_id,pgp_sym_encrypt(p_password,v_secret,'cipher-algo=aes256'),now())
      on conflict (employee_id) do update set password_cipher=excluded.password_cipher,updated_at=now();
      -- A password reset signs out existing sessions. Ordinary username edits do not.
      delete from public.employee_sessions where employee_id=v_id;
    end if;
  end if;

  return v_id;
exception when unique_violation then
  raise exception 'That employee username already exists.';
end;
$$;
revoke all on function public.admin_save_employee(text,text,uuid) from public;
grant execute on function public.admin_save_employee(text,text,uuid) to authenticated;

-- Migrate a legacy browser-cached password into the encrypted admin credential
-- store only when it still matches the employee's current login password.
create or replace function public.admin_store_employee_password(p_employee_id uuid, p_password text)
returns boolean
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
  v_hash text;
  v_secret text;
begin
  if auth.uid() is null or not exists(select 1 from public.admin_users where id=auth.uid()) then
    raise exception 'Admin login required.';
  end if;
  select e.password_hash into v_hash from public.employees e where e.id=p_employee_id;
  if v_hash is null then return false; end if;
  if v_hash <> crypt(coalesce(p_password,''),v_hash) then return false; end if;
  select s.secret into v_secret from public.employee_credential_secret s where s.singleton=true;
  insert into public.employee_admin_credentials(employee_id,password_cipher,updated_at)
  values(p_employee_id,pgp_sym_encrypt(p_password,v_secret,'cipher-algo=aes256'),now())
  on conflict (employee_id) do update set password_cipher=excluded.password_cipher,updated_at=now();
  return true;
end;
$$;
revoke all on function public.admin_store_employee_password(uuid,text) from public;
grant execute on function public.admin_store_employee_password(uuid,text) to authenticated;

-- Suspend/restore staff. Suspending invalidates all current devices immediately.
create or replace function public.admin_set_employee_active(p_employee_id uuid, p_active boolean)
returns void
language plpgsql
security definer
set search_path=public,extensions
as $$
begin
  if auth.uid() is null or not exists(select 1 from public.admin_users where id=auth.uid()) then
    raise exception 'Admin login required.';
  end if;
  update public.employees set is_active=p_active,updated_at=now() where id=p_employee_id;
  if not found then raise exception 'Employee not found.'; end if;
  if not p_active then delete from public.employee_sessions where employee_id=p_employee_id; end if;
end;
$$;
revoke all on function public.admin_set_employee_active(uuid,boolean) from public;
grant execute on function public.admin_set_employee_active(uuid,boolean) to authenticated;

-- Explicit multi-device login: every successful login creates an independent
-- 30-day session. Existing sessions are not removed when another device logs in.
create or replace function public.employee_login(p_username text, p_password text)
returns jsonb
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
  e public.employees%rowtype;
  v_token text := replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-','');
  v_expires timestamptz := now()+interval '30 days';
begin
  delete from public.employee_sessions where expires_at < now();
  select * into e from public.employees where lower(username)=lower(btrim(p_username)) and is_active=true limit 1;
  if not found or e.password_hash <> crypt(coalesce(p_password,''),e.password_hash) then
    raise exception 'Invalid username or password.';
  end if;

  insert into public.employee_sessions(employee_id,token_hash,expires_at)
  values(e.id,encode(digest(v_token,'sha256'),'hex'),v_expires);

  return jsonb_build_object('token',v_token,'employee_id',e.id,'username',e.username,'expires_at',v_expires);
end;
$$;
revoke all on function public.employee_login(text,text) from public;
grant execute on function public.employee_login(text,text) to anon, authenticated;

-- Keep admin creation outside the web UI: admin credentials remain Supabase Auth
-- users plus public.admin_users membership only. No browser RPC for creating admins
-- is introduced by this migration.

-- WellOne v107
-- Strict storefront search, separate Sales/Management staff roles, and storage cleanup queue.

alter table public.employees add column if not exists portal_role text not null default 'sales';
update public.employees set portal_role='sales' where portal_role is null or portal_role not in ('sales','management');
alter table public.employees drop constraint if exists employees_portal_role_check;
alter table public.employees add constraint employees_portal_role_check check (portal_role in ('sales','management'));

create or replace function public.employee_from_token_role(p_token text, p_role text)
returns uuid
language sql
security definer
stable
set search_path=public,extensions
as $$
  select e.id
  from public.employee_sessions s
  join public.employees e on e.id=s.employee_id
  where s.token_hash=encode(digest(coalesce(p_token,''),'sha256'),'hex')
    and s.expires_at>now()
    and e.is_active=true
    and e.portal_role=p_role
  limit 1;
$$;
revoke all on function public.employee_from_token_role(text,text) from public;
grant execute on function public.employee_from_token_role(text,text) to anon, authenticated;

create or replace function public.employee_portal_login(p_username text, p_password text, p_role text)
returns jsonb
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
  e public.employees%rowtype;
  v_token text := replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-','');
  v_expires timestamptz := now()+interval '30 days';
begin
  if p_role not in ('sales','management') then raise exception 'Invalid staff portal.'; end if;
  delete from public.employee_sessions where expires_at < now();
  select * into e from public.employees
   where lower(username)=lower(btrim(p_username)) and is_active=true and portal_role=p_role
   limit 1;
  if not found or e.password_hash <> crypt(coalesce(p_password,''),e.password_hash) then
    if p_role='management' then raise exception 'Invalid management ID or password.'; else raise exception 'Invalid sales staff ID or password.'; end if;
  end if;
  insert into public.employee_sessions(employee_id,token_hash,expires_at)
  values(e.id,encode(digest(v_token,'sha256'),'hex'),v_expires);
  return jsonb_build_object('token',v_token,'employee_id',e.id,'username',e.username,'role',e.portal_role,'expires_at',v_expires);
end;
$$;
revoke all on function public.employee_portal_login(text,text,text) from public;
grant execute on function public.employee_portal_login(text,text,text) to anon, authenticated;

create or replace function public.employee_sales_login(p_username text, p_password text)
returns jsonb language sql security definer set search_path=public,extensions as $$
  select public.employee_portal_login(p_username,p_password,'sales');
$$;
revoke all on function public.employee_sales_login(text,text) from public;
grant execute on function public.employee_sales_login(text,text) to anon, authenticated;

create or replace function public.employee_management_login(p_username text, p_password text)
returns jsonb language sql security definer set search_path=public,extensions as $$
  select public.employee_portal_login(p_username,p_password,'management');
$$;
revoke all on function public.employee_management_login(text,text) from public;
grant execute on function public.employee_management_login(text,text) to anon, authenticated;

-- Admin staff management now stores and edits the portal role too.
drop function if exists public.admin_list_employees();
create function public.admin_list_employees()
returns table(
  id uuid,
  username text,
  portal_role text,
  is_active boolean,
  password text,
  active_sessions bigint,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql security definer set search_path=public,extensions as $$
declare v_secret text;
begin
  if auth.uid() is null or not exists(select 1 from public.admin_users where id=auth.uid()) then raise exception 'Admin login required.'; end if;
  select s.secret into v_secret from public.employee_credential_secret s where s.singleton=true;
  return query
  select e.id,e.username,e.portal_role,e.is_active,
         case when c.password_cipher is null then null else pgp_sym_decrypt(c.password_cipher,v_secret) end,
         (select count(*) from public.employee_sessions es where es.employee_id=e.id and es.expires_at>now())::bigint,
         e.created_at,e.updated_at
    from public.employees e
    left join public.employee_admin_credentials c on c.employee_id=e.id
   order by e.is_active desc,e.portal_role,e.created_at desc;
end;
$$;
revoke all on function public.admin_list_employees() from public;
grant execute on function public.admin_list_employees() to authenticated;

drop function if exists public.admin_save_employee(text,text,uuid);
drop function if exists public.admin_save_employee(text,text,text,uuid);
create function public.admin_save_employee(p_username text, p_password text, p_portal_role text default 'sales', p_employee_id uuid default null)
returns uuid
language plpgsql security definer set search_path=public,extensions as $$
declare v_id uuid; v_secret text; v_old_role text; v_password_changed boolean:=nullif(p_password,'') is not null; v_role text:=lower(btrim(coalesce(p_portal_role,'sales')));
begin
  if auth.uid() is null or not exists(select 1 from public.admin_users where id=auth.uid()) then raise exception 'Admin login required.'; end if;
  if v_role not in ('sales','management') then raise exception 'Select Sales Staff or Management.'; end if;
  if nullif(btrim(p_username),'') is null then raise exception 'Enter staff username.'; end if;
  if p_employee_id is null and length(coalesce(p_password,''))<4 then raise exception 'Password must be at least 4 characters.'; end if;
  if v_password_changed and length(p_password)<4 then raise exception 'Password must be at least 4 characters.'; end if;
  select s.secret into v_secret from public.employee_credential_secret s where s.singleton=true;
  if p_employee_id is null then
    insert into public.employees(username,password_hash,portal_role,created_by)
    values(btrim(p_username),crypt(p_password,gen_salt('bf')),v_role,auth.uid()) returning id into v_id;
    insert into public.employee_admin_credentials(employee_id,password_cipher,updated_at)
    values(v_id,pgp_sym_encrypt(p_password,v_secret,'cipher-algo=aes256'),now())
    on conflict(employee_id) do update set password_cipher=excluded.password_cipher,updated_at=now();
  else
    select portal_role into v_old_role from public.employees where id=p_employee_id;
    update public.employees set username=btrim(p_username),portal_role=v_role,
      password_hash=case when v_password_changed then crypt(p_password,gen_salt('bf')) else password_hash end,
      updated_at=now()
    where id=p_employee_id returning id into v_id;
    if v_id is null then raise exception 'Staff account not found.'; end if;
    if v_password_changed then
      insert into public.employee_admin_credentials(employee_id,password_cipher,updated_at)
      values(v_id,pgp_sym_encrypt(p_password,v_secret,'cipher-algo=aes256'),now())
      on conflict(employee_id) do update set password_cipher=excluded.password_cipher,updated_at=now();
    end if;
    -- Role/password changes invalidate old portal sessions so permissions update immediately.
    if v_password_changed or coalesce(v_old_role,'')<>v_role then
      delete from public.employee_sessions where employee_id=v_id;
    end if;
  end if;
  return v_id;
exception when unique_violation then raise exception 'That staff username already exists.';
end;
$$;
revoke all on function public.admin_save_employee(text,text,text,uuid) from public;
grant execute on function public.admin_save_employee(text,text,text,uuid) to authenticated;

-- Strict storefront text search: only name, description, or hidden keywords.
-- Whitespace is ignored and matching is case-insensitive.
create or replace function public.strict_product_search_ids(p_query text, p_category_id uuid default null)
returns table(id uuid)
language sql
security definer
stable
set search_path=public,extensions
as $$
  with q as (
    select regexp_replace(lower(coalesce(p_query,'')),'[[:space:]]+','','g') as needle
  )
  select p.id
  from public.products p,q
  where coalesce(p.status,'active')='active'
    and (p_category_id is null or p.category_id=p_category_id)
    and q.needle<>''
    and (
      position(q.needle in regexp_replace(lower(coalesce(p.name,'')),'[[:space:]]+','','g'))>0
      or position(q.needle in regexp_replace(lower(coalesce(p.description,'')),'[[:space:]]+','','g'))>0
      or position(q.needle in regexp_replace(lower(coalesce(p.search_keywords,'')),'[[:space:]]+','','g'))>0
    )
  limit 5000;
$$;
revoke all on function public.strict_product_search_ids(text,uuid) from public;
grant execute on function public.strict_product_search_ids(text,uuid) to anon, authenticated;

-- Role-gated sales payloads/functions.
create or replace function public.employee_get_product(p_token text, p_product_id uuid)
returns jsonb
language plpgsql security definer set search_path=public,extensions as $$
declare v_emp uuid; p record;
begin
  v_emp:=public.employee_from_token_role(p_token,'sales'); if v_emp is null then raise exception 'Sales staff login expired or not permitted.'; end if;
  select pr.* into p from public.products pr where pr.id=p_product_id and coalesce(pr.status,'active')='active' limit 1;
  if not found then return null; end if;
  return jsonb_build_object(
    'id',p.id,'name',p.name,'barcode',case when p.barcode_enabled then p.barcode else null end,'image_url',p.main_image_url,'option_title',p.option_title,
    'track_inventory',p.track_inventory,'stock_quantity',p.stock_quantity,'stock_status',p.stock_status,
    'variants',coalesce((select jsonb_agg(jsonb_build_object('id',v.id,'color',coalesce(nullif(v.color,''),nullif(v.unit,'')),'size',coalesce(nullif(v.size,''),nullif(v.label,'')),'stock',v.stock,'stock_status',v.stock_status,'price',coalesce(v.price,p.price),'image_url',coalesce(nullif(v.image_url,''),p.main_image_url)) order by v.sort_order,v.id) from public.product_variants v where v.product_id=p.id and coalesce(v.stock_status,'in_stock')<>'hidden'),'[]'::jsonb)
  );
end; $$;
revoke all on function public.employee_get_product(text,uuid) from public;
grant execute on function public.employee_get_product(text,uuid) to anon, authenticated;

create or replace function public.employee_get_product_by_barcode(p_token text,p_barcode text)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_emp uuid; v_product_id uuid;
begin
  v_emp:=public.employee_from_token_role(p_token,'sales'); if v_emp is null then raise exception 'Sales staff login expired or not permitted.'; end if;
  select id into v_product_id from public.products where barcode_enabled=true and lower(barcode)=lower(btrim(p_barcode)) and coalesce(status,'active')='active' limit 1;
  if v_product_id is null then return null; end if;
  return public.employee_get_product(p_token,v_product_id);
end; $$;
revoke all on function public.employee_get_product_by_barcode(text,text) from public;
grant execute on function public.employee_get_product_by_barcode(text,text) to anon, authenticated;

create or replace function public.employee_search_products(p_token text,p_query text)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_emp uuid; v_query text:=btrim(coalesce(p_query,'')); v_result jsonb;
begin
  v_emp:=public.employee_from_token_role(p_token,'sales'); if v_emp is null then raise exception 'Sales staff login expired or not permitted.'; end if;
  if v_query='' then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(public.employee_get_product(p_token,x.id) order by x.exact_barcode desc,x.name),'[]'::jsonb) into v_result
  from (
    select p.id,p.name,(p.barcode_enabled=true and lower(coalesce(p.barcode,''))=lower(v_query)) exact_barcode
    from public.products p
    where coalesce(p.status,'active')='active'
      and (p.name ilike '%'||v_query||'%' or (p.barcode_enabled=true and p.barcode ilike '%'||v_query||'%'))
    order by exact_barcode desc,p.name limit 20
  )x;
  return v_result;
end; $$;
revoke all on function public.employee_search_products(text,text) from public;
grant execute on function public.employee_search_products(text,text) to anon, authenticated;

create or replace function public.employee_record_sale(p_token text,p_product_id uuid,p_variant_id uuid,p_quantity integer default 1)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_emp uuid; v_username text; p public.products%rowtype; v public.product_variants%rowtype; q integer:=greatest(1,coalesce(p_quantity,1));
begin
  v_emp:=public.employee_from_token_role(p_token,'sales'); if v_emp is null then raise exception 'Sales staff login expired or not permitted.'; end if;
  select username into v_username from public.employees where id=v_emp;
  select * into p from public.products where id=p_product_id and coalesce(status,'active')='active' for update;
  if not found then raise exception 'Product not found.'; end if;
  if coalesce(p.stock_status,'in_stock')='out_of_stock' then raise exception 'This item is out of stock.'; end if;
  if p_variant_id is not null then
    select * into v from public.product_variants where id=p_variant_id and product_id=p.id and coalesce(stock_status,'in_stock')<>'hidden' for update;
    if not found then raise exception 'This option is unavailable.'; end if;
    if coalesce(v.stock_status,'in_stock')='out_of_stock' then raise exception 'This exact option is out of stock.'; end if;
    if p.track_inventory then
      if coalesce(v.stock,0)<q then raise exception 'Only % unit(s) are available.',greatest(coalesce(v.stock,0),0); end if;
      update public.product_variants set stock=stock-q,stock_status=case when stock-q>0 then 'in_stock' else 'out_of_stock' end where id=v.id;
      perform public.wellone_recalc_product_stock(p.id);
    end if;
  else
    if exists(select 1 from public.product_variants where product_id=p.id and coalesce(stock_status,'in_stock')<>'hidden') then raise exception 'Select the exact product option.'; end if;
    if p.track_inventory then
      if coalesce(p.stock_quantity,0)<q then raise exception 'Only % unit(s) are available.',greatest(coalesce(p.stock_quantity,0),0); end if;
      update public.products set stock_quantity=stock_quantity-q,stock_status=case when stock_quantity-q>0 then 'in_stock' else 'out_of_stock' end,updated_at=now() where id=p.id;
    end if;
  end if;
  insert into public.stock_movements(product_id,variant_id,quantity_delta,reason,actor_type,actor_label)
  values(p.id,p_variant_id,-q,case when p.track_inventory then 'employee_sale' else 'employee_sale_manual_stock' end,'employee',v_username);
  return public.employee_get_product(p_token,p.id);
end; $$;
revoke all on function public.employee_record_sale(text,uuid,uuid,integer) from public;
grant execute on function public.employee_record_sale(text,uuid,uuid,integer) to anon, authenticated;

-- Replace manager authorization with Management-role authorization.
create or replace function public.employee_manage_meta(p_token text)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_employee uuid;
begin
  v_employee:=public.employee_from_token_role(p_token,'management'); if v_employee is null then raise exception 'Management login expired or not permitted.'; end if;
  return jsonb_build_object(
    'categories',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',c.name,'image_url',c.image_url,'storage_path',c.storage_path,'description',c.description,'sort_order',c.sort_order,'is_active',c.is_active) order by c.sort_order nulls last,c.name) from public.categories c where coalesce(c.is_active,true)=true),'[]'::jsonb),
    'subcategories',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'category_id',s.category_id,'name',s.name,'sort_order',s.sort_order,'is_active',s.is_active) order by s.sort_order nulls last,s.name) from public.subcategories s where coalesce(s.is_active,true)=true),'[]'::jsonb)
  );
end; $$;
revoke all on function public.employee_manage_meta(text) from public;
grant execute on function public.employee_manage_meta(text) to anon,authenticated;

-- Storage cleanup queue: DB/image records disappear immediately; actual Storage files
-- are securely removed by the Admin app on its next load/refresh.
create table if not exists public.storage_cleanup_queue(
  id bigserial primary key,
  storage_path text not null unique,
  created_at timestamptz not null default now()
);
alter table public.storage_cleanup_queue enable row level security;
revoke all on table public.storage_cleanup_queue from anon,authenticated;

create or replace function public.queue_storage_cleanup_path(p_path text)
returns void language plpgsql security definer set search_path=public,extensions as $$
begin
  if nullif(btrim(coalesce(p_path,'')),'') is null then return; end if;
  insert into public.storage_cleanup_queue(storage_path) values(btrim(p_path)) on conflict(storage_path) do nothing;
end; $$;
revoke all on function public.queue_storage_cleanup_path(text) from public;

create or replace function public.trg_queue_product_image_cleanup()
returns trigger language plpgsql security definer set search_path=public,extensions as $$
begin
  if tg_op='DELETE' then perform public.queue_storage_cleanup_path(old.storage_path);
  elsif old.storage_path is distinct from new.storage_path then perform public.queue_storage_cleanup_path(old.storage_path); end if;
  if tg_op='DELETE' then return old; else return new; end if;
end; $$;

drop trigger if exists trg_product_images_storage_cleanup on public.product_images;
create trigger trg_product_images_storage_cleanup after delete or update of storage_path on public.product_images for each row execute function public.trg_queue_product_image_cleanup();

create or replace function public.trg_queue_variant_storage_cleanup()
returns trigger language plpgsql security definer set search_path=public,extensions as $$
declare p text;
begin
  if tg_op='DELETE' then
    foreach p in array coalesce(old.storage_paths,'{}'::text[]) loop perform public.queue_storage_cleanup_path(p); end loop;
  else
    foreach p in array coalesce(old.storage_paths,'{}'::text[]) loop
      if not (p=any(coalesce(new.storage_paths,'{}'::text[]))) then perform public.queue_storage_cleanup_path(p); end if;
    end loop;
  end if;
  if tg_op='DELETE' then return old; else return new; end if;
end; $$;

drop trigger if exists trg_product_variants_storage_cleanup on public.product_variants;
create trigger trg_product_variants_storage_cleanup after delete or update of storage_paths on public.product_variants for each row execute function public.trg_queue_variant_storage_cleanup();

create or replace function public.admin_storage_cleanup_pending(p_limit integer default 100)
returns table(id bigint,storage_path text)
language plpgsql security definer set search_path=public,extensions as $$
begin
  if auth.uid() is null or not exists(select 1 from public.admin_users where id=auth.uid()) then raise exception 'Admin login required.'; end if;
  -- A save can temporarily delete/reinsert rows. Drop queue entries that are still referenced now.
  delete from public.storage_cleanup_queue q
   where exists(select 1 from public.product_images i where i.storage_path=q.storage_path)
      or exists(select 1 from public.product_variants v where q.storage_path=any(coalesce(v.storage_paths,'{}'::text[])));
  return query select q.id,q.storage_path from public.storage_cleanup_queue q order by q.id limit least(greatest(coalesce(p_limit,100),1),250);
end; $$;
revoke all on function public.admin_storage_cleanup_pending(integer) from public;
grant execute on function public.admin_storage_cleanup_pending(integer) to authenticated;

create or replace function public.admin_storage_cleanup_done(p_ids bigint[])
returns void language plpgsql security definer set search_path=public,extensions as $$
begin
  if auth.uid() is null or not exists(select 1 from public.admin_users where id=auth.uid()) then raise exception 'Admin login required.'; end if;
  delete from public.storage_cleanup_queue where id=any(coalesce(p_ids,'{}'::bigint[]));
end; $$;
revoke all on function public.admin_storage_cleanup_done(bigint[]) from public;
grant execute on function public.admin_storage_cleanup_done(bigint[]) to authenticated;


-- v107 management-role overrides for all management RPCs and upload capabilities.
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
  v_employee := public.employee_from_token_role(p_token,'management');
  if v_employee is null then raise exception 'Management login expired or not permitted.'; end if;
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
       and e.portal_role='management'
  );
$$;
revoke all on function public.employee_upload_token_valid(text) from public;
grant execute on function public.employee_upload_token_valid(text) to anon, authenticated;

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
  v_employee := public.employee_from_token_role(p_token,'management');
  if v_employee is null then raise exception 'Management login expired or not permitted.'; end if;

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
  v_employee := public.employee_from_token_role(p_token,'management');
  if v_employee is null then raise exception 'Management login expired or not permitted.'; end if;

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
  v_employee := public.employee_from_token_role(p_token,'management');
  if v_employee is null then raise exception 'Management login expired or not permitted.'; end if;
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
  v_employee := public.employee_from_token_role(p_token,'management');
  if v_employee is null then raise exception 'Management login expired or not permitted.'; end if;
  delete from public.product_images where product_id=p_product_id;
  delete from public.product_variants where product_id=p_product_id;
  delete from public.products where id=p_product_id;
end;
$$;
revoke all on function public.employee_manage_delete_product(text,uuid) from public;
grant execute on function public.employee_manage_delete_product(text,uuid) to anon, authenticated;

-- Queue newly-uploaded files for cleanup if a Management save fails before the
-- database can reference them. Referenced paths are filtered out by the Admin cleanup reader.
create or replace function public.employee_manage_queue_cleanup(p_token text, p_paths text[])
returns void
language plpgsql
security definer
set search_path=public,extensions
as $$
declare v_employee uuid; p text;
begin
  v_employee:=public.employee_from_token_role(p_token,'management');
  if v_employee is null then raise exception 'Management login expired or not permitted.'; end if;
  foreach p in array coalesce(p_paths,'{}'::text[]) loop
    perform public.queue_storage_cleanup_path(p);
  end loop;
end;
$$;
revoke all on function public.employee_manage_queue_cleanup(text,text[]) from public;
grant execute on function public.employee_manage_queue_cleanup(text,text[]) to anon,authenticated;

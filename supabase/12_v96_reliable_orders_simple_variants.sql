-- WellOne v96: reliable exact customer orders + simplified variant compatibility
-- Run AFTER the earlier WellOne SQL migrations. Safe to run repeatedly.

-- Hidden variants must not keep a product artificially in stock.
create or replace function public.wellone_recalc_product_stock(p_product_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_has_variants boolean;
  v_total integer;
begin
  select exists(select 1 from public.product_variants where product_id=p_product_id),
         coalesce(sum(greatest(stock,0)) filter (where coalesce(stock_status,'in_stock')<>'hidden'),0)
    into v_has_variants,v_total
  from public.product_variants
  where product_id=p_product_id;

  if v_has_variants then
    update public.products
       set stock_quantity=v_total,
           stock_status=case when v_total>0 then 'in_stock' else 'out_of_stock' end,
           updated_at=now()
     where id=p_product_id and track_inventory=true;
  end if;
end;
$$;
revoke all on function public.wellone_recalc_product_stock(uuid) from public;

create or replace function public.create_customer_order(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_payment_method text,
  p_items jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order_id uuid := gen_random_uuid();
  v_order_number text := 'WEL-' || to_char(clock_timestamp(),'YYYYMMDD-HH24MISS') || '-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,5));
  v_token text := replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-','');
  v_item jsonb;
  v_product public.products%rowtype;
  v_variant public.product_variants%rowtype;
  v_variant_id uuid;
  v_qty integer;
  v_total numeric(12,2) := 0;
  v_price numeric(12,2);
  v_color text;
  v_size text;
  v_option_name text;
  v_image text;
  v_offer_price numeric(12,2);
  v_has_variants boolean;
  v_product_id uuid;
  v_offer_id uuid;
begin
  if nullif(btrim(p_customer_name),'') is null or nullif(btrim(p_customer_phone),'') is null or nullif(btrim(p_customer_address),'') is null then
    raise exception 'Name, phone and address are required.';
  end if;
  if p_payment_method not in ('cod','online') then p_payment_method := 'cod'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items)=0 then raise exception 'Your cart is empty.'; end if;

  insert into public.orders(id,order_number,customer_name,customer_phone,customer_address,payment_method,payment_status,status,tracking_hash)
  values(v_order_id,v_order_number,btrim(p_customer_name),btrim(p_customer_phone),btrim(p_customer_address),p_payment_method,'pending','placed',encode(digest(v_token,'sha256'),'hex'));

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    begin v_product_id := (v_item->>'product_id')::uuid; exception when others then raise exception 'A selected product reference is invalid. Please remove it from cart and add it again.'; end;
    begin v_variant_id := nullif(v_item->>'variant_id','')::uuid; exception when others then v_variant_id := null; end;
    begin v_offer_id := nullif(v_item->>'offer_id','')::uuid; exception when others then v_offer_id := null; end;
    begin v_qty := greatest(1,coalesce((v_item->>'quantity')::integer,1)); exception when others then v_qty := 1; end;
    v_color := nullif(btrim(coalesce(v_item->>'color','')),'');
    v_size := nullif(btrim(coalesce(v_item->>'size','')),'');
    if lower(coalesce(v_color,''))='default' then v_color:=null; end if;
    if lower(coalesce(v_size,''))='standard' then v_size:=null; end if;

    select * into v_product from public.products where id=v_product_id for update;
    if not found or coalesce(v_product.status,'active')<>'active' then raise exception 'One selected product is no longer available.'; end if;
    if coalesce(v_product.stock_status,'in_stock')='out_of_stock' then raise exception '% is out of stock.',v_product.name; end if;
    v_option_name:=coalesce(nullif(btrim(v_product.option_title),''),'Option');
    select exists(select 1 from public.product_variants where product_id=v_product.id and coalesce(stock_status,'in_stock')<>'hidden') into v_has_variants;
    v_variant:=null;

    -- 1) Trust a supplied exact variant id only when it belongs to this product and still matches requested dimensions.
    if v_variant_id is not null then
      select * into v_variant from public.product_variants where id=v_variant_id and product_id=v_product.id and coalesce(stock_status,'in_stock')<>'hidden' for update;
      if not found
         or (v_color is not null and lower(coalesce(nullif(v_variant.color,''),nullif(v_variant.unit,''),''))<>lower(v_color))
         or (v_size is not null and not (
              lower(coalesce(nullif(v_variant.size,''),nullif(v_variant.label,''),''))=lower(v_size)
              or exists(select 1 from unnest(regexp_split_to_array(coalesce(nullif(v_variant.size,''),nullif(v_variant.label,''),''),'\s*[,|\n]+\s*')) x where lower(btrim(x))=lower(v_size))
            )) then
        v_variant_id:=null; v_variant:=null;
      end if;
    end if;

    -- 2) Resolve by exact colour + option. Legacy comma-separated size rows are supported as a compatibility fallback.
    if v_variant_id is null and v_has_variants and (v_color is not null or v_size is not null) then
      select * into v_variant
      from public.product_variants v
      where v.product_id=v_product.id
        and coalesce(v.stock_status,'in_stock')<>'hidden'
        and (v_color is null or lower(coalesce(nullif(v.color,''),nullif(v.unit,''),''))=lower(v_color))
        and (v_size is null or lower(coalesce(nullif(v.size,''),nullif(v.label,''),''))=lower(v_size)
             or exists(select 1 from unnest(regexp_split_to_array(coalesce(nullif(v.size,''),nullif(v.label,''),''),'\s*[,|\n]+\s*')) x where lower(btrim(x))=lower(v_size)))
      order by case when lower(coalesce(nullif(v.size,''),nullif(v.label,''),''))=lower(coalesce(v_size,'')) then 0 else 1 end,
               v.sort_order nulls last,v.id
      limit 1 for update;
      if not found then raise exception '% selected option is no longer available. Please select it again.',v_product.name; end if;
      v_variant_id:=v_variant.id;
    elsif v_variant_id is null and v_has_variants then
      if (select count(*) from public.product_variants where product_id=v_product.id and coalesce(stock_status,'in_stock')<>'hidden')=1 then
        select * into v_variant from public.product_variants where product_id=v_product.id and coalesce(stock_status,'in_stock')<>'hidden' limit 1 for update;
        v_variant_id:=v_variant.id;
      else
        raise exception 'Select the exact option for %.',v_product.name;
      end if;
    end if;

    if v_variant_id is not null and coalesce(v_variant.stock_status,'in_stock') in ('out_of_stock','hidden') then raise exception '% selected option is out of stock.',v_product.name; end if;

    if v_product.track_inventory then
      if v_variant_id is not null then
        if coalesce(v_variant.stock,0)<v_qty then raise exception 'Only % unit(s) of % are available.',greatest(coalesce(v_variant.stock,0),0),v_product.name; end if;
        update public.product_variants set stock=stock-v_qty,stock_status=case when stock-v_qty>0 then 'in_stock' else 'out_of_stock' end where id=v_variant_id;
      else
        if coalesce(v_product.stock_quantity,0)<v_qty then raise exception 'Only % unit(s) of % are available.',greatest(coalesce(v_product.stock_quantity,0),0),v_product.name; end if;
        update public.products set stock_quantity=stock_quantity-v_qty,stock_status=case when stock_quantity-v_qty>0 then 'in_stock' else 'out_of_stock' end,updated_at=now() where id=v_product.id;
      end if;
    end if;

    v_offer_price:=null;
    if v_offer_id is not null then
      select oi.offer_price into v_offer_price from public.offer_items oi
      where oi.id=v_offer_id and oi.is_active=true and (oi.valid_until is null or oi.valid_until>now())
        and coalesce(oi.item_link,'') ~ ('(^|[?&])id=' || v_product.id::text || '(&|$)') limit 1;
    end if;
    v_price:=coalesce(v_offer_price,nullif(v_variant.price,0),nullif(v_product.price,0),nullif(v_variant.mrp,0),nullif(v_product.mrp,0),0);
    v_image:=coalesce(nullif(v_variant.image_url,''),nullif(v_product.main_image_url,''));
    if v_variant_id is not null then
      v_color:=coalesce(v_color,nullif(v_variant.color,''),nullif(v_variant.unit,''));
      v_size:=coalesce(v_size,nullif(v_variant.size,''),nullif(v_variant.label,''));
    end if;

    insert into public.order_items(order_id,product_id,variant_id,product_name,color,size,option_name,quantity,unit_price,line_total,image_url,stock_reserved)
    values(v_order_id,v_product.id,v_variant_id,v_product.name,v_color,v_size,v_option_name,v_qty,v_price,v_price*v_qty,v_image,v_product.track_inventory);
    v_total:=v_total+(v_price*v_qty);
    insert into public.stock_movements(product_id,variant_id,quantity_delta,reason,reference_id,actor_type,actor_label)
    values(v_product.id,v_variant_id,-v_qty,case when v_product.track_inventory then 'customer_order' else 'customer_order_manual_stock' end,v_order_id,'customer',btrim(p_customer_name));
    if v_product.track_inventory and v_variant_id is not null then perform public.wellone_recalc_product_stock(v_product.id); end if;
  end loop;

  update public.orders set subtotal=v_total,total=v_total,updated_at=now() where id=v_order_id;
  insert into public.order_status_history(order_id,status,note,actor_type,actor_label) values(v_order_id,'placed','Order placed','customer',btrim(p_customer_name));
  return jsonb_build_object('order_id',v_order_id,'order_number',v_order_number,'tracking_token',v_token,'status','placed','total',v_total,'payment_method',p_payment_method);
end;
$$;
revoke all on function public.create_customer_order(text,text,text,text,jsonb) from public;
grant execute on function public.create_customer_order(text,text,text,text,jsonb) to anon, authenticated;


-- Hidden options also stay hidden from the Employee sale app and cannot be sold there.
create or replace function public.employee_get_product(p_token text, p_product_id uuid)
returns jsonb
language plpgsql security definer set search_path=public,extensions as $$
declare v_emp uuid; p record;
begin
  v_emp:=public.employee_from_token(p_token); if v_emp is null then raise exception 'Employee login expired.'; end if;
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

create or replace function public.employee_record_sale(p_token text, p_product_id uuid, p_variant_id uuid, p_quantity integer default 1)
returns jsonb
language plpgsql security definer set search_path=public,extensions as $$
declare v_emp uuid; v_username text; p public.products%rowtype; v public.product_variants%rowtype; q integer:=greatest(1,coalesce(p_quantity,1));
begin
  v_emp:=public.employee_from_token(p_token); if v_emp is null then raise exception 'Employee login expired.'; end if;
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

-- Realtime publication entries are added only if missing. This keeps product/variant changes live.
do $$
begin
  if exists(select 1 from pg_publication where pubname='supabase_realtime') then
    if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='products') then alter publication supabase_realtime add table public.products; end if;
    if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='product_variants') then alter publication supabase_realtime add table public.product_variants; end if;
    if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='product_images') then alter publication supabase_realtime add table public.product_images; end if;
  end if;
exception when insufficient_privilege then
  raise notice 'Realtime publication update skipped: insufficient privilege. Broadcast updates still work.';
end $$;

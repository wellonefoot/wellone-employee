-- WellOne v86: exact option migration + manual availability sales + live reliability
-- Run AFTER 10_v85_heavy_commerce_flow.sql. Safe to run more than once.

-- Split legacy variant rows such as size='41,42,43' into exact rows.
-- Existing quantity is treated as "quantity each", matching the Admin Quick Add behavior.
do $$
declare
  r record;
  vals text[];
  val text;
  first_val boolean;
  next_sort integer;
begin
  for r in
    select * from public.product_variants
    where coalesce(size,label,'') ~ '[,|\n]'
  loop
    vals := regexp_split_to_array(coalesce(nullif(btrim(r.size),''),nullif(btrim(r.label),'')), '\s*[,|\n]+\s*');
    vals := array(select btrim(x) from unnest(vals) with ordinality u(x,ord) where nullif(btrim(x),'') is not null order by ord);
    if coalesce(array_length(vals,1),0) <= 1 then continue; end if;
    first_val := true;
    next_sort := coalesce(r.sort_order,0);
    foreach val in array vals loop
      if first_val then
        update public.product_variants set size=val,label=val where id=r.id;
        first_val := false;
      else
        next_sort := next_sort + 1;
        insert into public.product_variants(product_id,label,unit,color,size,mrp,price,image_url,image_urls,storage_paths,terms,stock,stock_status,sort_order)
        values(r.product_id,val,r.unit,r.color,val,r.mrp,r.price,r.image_url,r.image_urls,r.storage_paths,r.terms,r.stock,r.stock_status,next_sort);
      end if;
    end loop;
  end loop;
end $$;


-- Customer order RPC v86: manual availability is enforced at the database boundary too.
-- This prevents a stale customer tab from ordering a product/option after Admin marked it out of stock.
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
  v_variant_id uuid;
  v_variant_stock integer;
  v_variant_stock_status text;
  v_variant_price numeric(12,2);
  v_variant_mrp numeric(12,2);
  v_variant_image text;
  v_variant_color text;
  v_variant_size text;
  v_qty integer;
  v_price numeric(12,2);
  v_total numeric(12,2) := 0;
  v_color text;
  v_size text;
  v_option_name text;
  v_image text;
  v_offer_price numeric(12,2);
  v_has_variants boolean;
begin
  if nullif(btrim(p_customer_name),'') is null or nullif(btrim(p_customer_phone),'') is null or nullif(btrim(p_customer_address),'') is null then
    raise exception 'Name, phone and address are required.';
  end if;
  if p_payment_method not in ('cod','online') then p_payment_method := 'cod'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Your cart is empty.';
  end if;

  insert into public.orders(id,order_number,customer_name,customer_phone,customer_address,payment_method,payment_status,status,tracking_hash)
  values(v_order_id,v_order_number,btrim(p_customer_name),btrim(p_customer_phone),btrim(p_customer_address),p_payment_method,'pending','placed',encode(digest(v_token,'sha256'),'hex'));

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_qty := greatest(1, coalesce((v_item->>'quantity')::integer, 1));
    v_variant_id := nullif(v_item->>'variant_id','')::uuid;
    v_color := nullif(btrim(coalesce(v_item->>'color','')), '');
    v_size := nullif(btrim(coalesce(v_item->>'size','')), '');

    select * into v_product from public.products where id = (v_item->>'product_id')::uuid for update;
    if not found or coalesce(v_product.status,'active') <> 'active' then raise exception 'One selected product is no longer available.'; end if;
    if coalesce(v_product.stock_status,'in_stock') = 'out_of_stock' then raise exception '% is out of stock.', v_product.name; end if;
    v_option_name := coalesce(nullif(btrim(v_product.option_title),''),'Size / option');

    select exists(select 1 from public.product_variants where product_id = v_product.id) into v_has_variants;
    v_variant_stock := null; v_variant_stock_status := null; v_variant_price := null; v_variant_mrp := null;
    v_variant_image := null; v_variant_color := null; v_variant_size := null;

    if v_variant_id is not null then
      select v.stock,v.stock_status,v.price,v.mrp,v.image_url,
             coalesce(nullif(v.color,''),nullif(v.unit,'')),coalesce(nullif(v.size,''),nullif(v.label,''))
        into v_variant_stock,v_variant_stock_status,v_variant_price,v_variant_mrp,v_variant_image,v_variant_color,v_variant_size
        from public.product_variants v where v.id = v_variant_id and v.product_id = v_product.id for update;
      if not found then v_variant_id := null; end if;
    end if;
    if v_variant_id is null and v_has_variants and (v_color is not null or v_size is not null) then
      select v.id,v.stock,v.stock_status,v.price,v.mrp,v.image_url,
             coalesce(nullif(v.color,''),nullif(v.unit,'')),coalesce(nullif(v.size,''),nullif(v.label,''))
        into v_variant_id,v_variant_stock,v_variant_stock_status,v_variant_price,v_variant_mrp,v_variant_image,v_variant_color,v_variant_size
        from public.product_variants v
       where v.product_id = v_product.id
         and (v_color is null or lower(coalesce(v.color,v.unit,'')) = lower(v_color))
         and (v_size is null or lower(coalesce(v.size,v.label,'')) = lower(v_size))
       order by v.sort_order nulls last, v.id
       limit 1
       for update;
      if not found then raise exception '% selected option is no longer available.', v_product.name; end if;
    elsif v_has_variants then
      if (select count(*) from public.product_variants where product_id=v_product.id) = 1 then
        select v.id,v.stock,v.stock_status,v.price,v.mrp,v.image_url,
               coalesce(nullif(v.color,''),nullif(v.unit,'')),coalesce(nullif(v.size,''),nullif(v.label,''))
          into v_variant_id,v_variant_stock,v_variant_stock_status,v_variant_price,v_variant_mrp,v_variant_image,v_variant_color,v_variant_size
          from public.product_variants v where v.product_id=v_product.id limit 1 for update;
      else
        raise exception 'Select the exact option for %.', v_product.name;
      end if;
    end if;

    if v_variant_id is not null and coalesce(v_variant_stock_status,'in_stock') = 'out_of_stock' then
      raise exception '% selected option is out of stock.', v_product.name;
    end if;

    if v_product.track_inventory then
      if v_variant_id is not null then
        if coalesce(v_variant_stock_status,'in_stock') = 'out_of_stock' or coalesce(v_variant_stock,0) < v_qty then
          raise exception 'Only % unit(s) of % % % are available.', greatest(coalesce(v_variant_stock,0),0), v_product.name, coalesce(v_color,v_variant_color,''), coalesce(v_size,v_variant_size,'');
        end if;
        update public.product_variants
           set stock = stock - v_qty,
               stock_status = case when stock - v_qty > 0 then 'in_stock' else 'out_of_stock' end
         where id = v_variant_id;
      else
        if coalesce(v_product.stock_status,'in_stock') = 'out_of_stock' or coalesce(v_product.stock_quantity,0) < v_qty then
          raise exception 'Only % unit(s) of % are available.', greatest(coalesce(v_product.stock_quantity,0),0), v_product.name;
        end if;
        update public.products
           set stock_quantity = stock_quantity - v_qty,
               stock_status = case when stock_quantity - v_qty > 0 then 'in_stock' else 'out_of_stock' end,
               updated_at = now()
         where id = v_product.id;
      end if;
    end if;

    v_offer_price := null;
    if nullif(v_item->>'offer_id','') is not null then
      select oi.offer_price into v_offer_price
      from public.offer_items oi
      where oi.id=(v_item->>'offer_id')::uuid
        and oi.is_active=true
        and (oi.valid_until is null or oi.valid_until>now())
        and coalesce(oi.item_link,'') ~ ('(^|[?&])id=' || v_product.id::text || '(&|$)')
      limit 1;
    end if;
    v_price := coalesce(v_offer_price, nullif(v_variant_price,0), nullif(v_product.price,0), nullif(v_variant_mrp,0), nullif(v_product.mrp,0), 0);
    v_image := coalesce(nullif(v_variant_image,''), nullif(v_product.main_image_url,''));
    if v_variant_id is not null then
      v_color := coalesce(v_color, v_variant_color);
      v_size := coalesce(v_size, v_variant_size);
    end if;

    insert into public.order_items(order_id,product_id,variant_id,product_name,color,size,option_name,quantity,unit_price,line_total,image_url,stock_reserved)
    values(v_order_id,v_product.id,v_variant_id,v_product.name,v_color,v_size,v_option_name,v_qty,v_price,v_price*v_qty,v_image,v_product.track_inventory);

    v_total := v_total + (v_price * v_qty);
    insert into public.stock_movements(product_id,variant_id,quantity_delta,reason,reference_id,actor_type,actor_label)
    values(v_product.id,v_variant_id,-v_qty,case when v_product.track_inventory then 'customer_order' else 'customer_order_manual_stock' end,v_order_id,'customer',btrim(p_customer_name));

    if v_product.track_inventory and v_variant_id is not null then perform public.wellone_recalc_product_stock(v_product.id); end if;
  end loop;

  update public.orders set subtotal=v_total,total=v_total,updated_at=now() where id=v_order_id;
  insert into public.order_status_history(order_id,status,note,actor_type,actor_label)
  values(v_order_id,'placed','Order placed','customer',btrim(p_customer_name));

  return jsonb_build_object('order_id',v_order_id,'order_number',v_order_number,'tracking_token',v_token,'status','placed','total',v_total,'payment_method',p_payment_method);
end;
$$;
revoke all on function public.create_customer_order(text,text,text,text,jsonb) from public;
grant execute on function public.create_customer_order(text,text,text,text,jsonb) to anon, authenticated;

-- Employee sales support both inventory modes:
-- tracked = decrement exact quantity; manual = log sale but leave availability controlled by Admin.
create or replace function public.employee_record_sale(p_token text, p_product_id uuid, p_variant_id uuid, p_quantity integer default 1)
returns jsonb
language plpgsql security definer set search_path=public,extensions as $$
declare v_emp uuid; v_username text; p public.products%rowtype; v public.product_variants%rowtype; q integer := greatest(1,coalesce(p_quantity,1));
begin
  v_emp := public.employee_from_token(p_token); if v_emp is null then raise exception 'Employee login expired.'; end if;
  select username into v_username from public.employees where id=v_emp;
  select * into p from public.products where id=p_product_id and coalesce(status,'active')='active' for update;
  if not found then raise exception 'Product not found.'; end if;
  if coalesce(p.stock_status,'in_stock')='out_of_stock' then raise exception 'This item is out of stock.'; end if;

  if p_variant_id is not null then
    select * into v from public.product_variants where id=p_variant_id and product_id=p.id for update;
    if not found then raise exception 'Option not found.'; end if;
    if coalesce(v.stock_status,'in_stock')='out_of_stock' then raise exception 'This exact option is out of stock.'; end if;
    if p.track_inventory then
      if coalesce(v.stock,0)<q then raise exception 'Only % unit(s) are available.',greatest(coalesce(v.stock,0),0); end if;
      update public.product_variants set stock=stock-q,stock_status=case when stock-q>0 then 'in_stock' else 'out_of_stock' end where id=v.id;
      perform public.wellone_recalc_product_stock(p.id);
    end if;
  else
    if exists(select 1 from public.product_variants where product_id=p.id) then raise exception 'Select the exact product option.'; end if;
    if coalesce(p.stock_status,'in_stock')='out_of_stock' then raise exception 'This item is out of stock.'; end if;
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

-- Keep realtime publication complete.
do $$
declare t text;
begin
  foreach t in array array['products','product_variants','orders','offer_items'] loop
    if to_regclass('public.' || t) is not null and not exists(
      select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename=t
    ) then execute format('alter publication supabase_realtime add table public.%I',t); end if;
  end loop;
exception when others then raise notice 'Realtime publication update notice: %',sqlerrm;
end $$;

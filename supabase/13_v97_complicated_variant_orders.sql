-- WellOne v97: complicated colour + option order reliability
-- Run AFTER 12_v96_reliable_orders_simple_variants.sql.
-- Safe to run repeatedly.

alter table if exists public.order_items
  add column if not exists product_barcode text;

create or replace function public.wellone_option_matches(p_stored text, p_requested text)
returns boolean
language sql
immutable
as $$
  select case
    when nullif(btrim(coalesce(p_requested,'')),'') is null then true
    when lower(regexp_replace(btrim(coalesce(p_stored,'')),'\s+','','g')) = lower(regexp_replace(btrim(coalesce(p_requested,'')),'\s+','','g')) then true
    else exists(
      select 1
      from unnest(regexp_split_to_array(coalesce(p_stored,''),'\s*[,|\n]+\s*')) token
      where lower(regexp_replace(btrim(token),'\s+','','g')) = lower(regexp_replace(btrim(coalesce(p_requested,'')),'\s+','','g'))
    )
  end;
$$;

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
  v_actual_color text;
  v_actual_size text;
  v_option_name text;
  v_image text;
  v_offer_price numeric(12,2);
  v_has_variants boolean;
  v_product_id uuid;
  v_offer_id uuid;
  v_candidate_count integer;
begin
  if nullif(btrim(p_customer_name),'') is null or nullif(btrim(p_customer_phone),'') is null or nullif(btrim(p_customer_address),'') is null then
    raise exception 'Name, phone and address are required.';
  end if;
  if p_payment_method not in ('cod','online') then p_payment_method := 'cod'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items)=0 then
    raise exception 'Your cart is empty.';
  end if;

  insert into public.orders(id,order_number,customer_name,customer_phone,customer_address,payment_method,payment_status,status,tracking_hash)
  values(v_order_id,v_order_number,btrim(p_customer_name),btrim(p_customer_phone),btrim(p_customer_address),p_payment_method,'pending','placed',encode(digest(v_token,'sha256'),'hex'));

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    begin
      v_product_id := (v_item->>'product_id')::uuid;
    exception when others then
      raise exception 'A selected product reference is invalid. Please remove it from cart and add it again.';
    end;

    begin
      v_variant_id := nullif(btrim(coalesce(nullif(v_item->>'variant_id',''),nullif(v_item->>'selected_variant_id',''),'')),'')::uuid;
    exception when others then
      v_variant_id := null;
    end;
    begin
      v_offer_id := nullif(v_item->>'offer_id','')::uuid;
    exception when others then
      v_offer_id := null;
    end;
    begin
      v_qty := greatest(1,coalesce((v_item->>'quantity')::integer,1));
    exception when others then
      v_qty := 1;
    end;

    v_color := nullif(btrim(coalesce(nullif(v_item->>'color',''),nullif(v_item->>'selected_color',''),'')),'');
    v_size := nullif(btrim(coalesce(nullif(v_item->>'size',''),nullif(v_item->>'selected_option',''),nullif(v_item->>'variant',''),'')),'');
    if lower(coalesce(v_color,''))='default' then v_color:=null; end if;
    if lower(coalesce(v_size,''))='standard' then v_size:=null; end if;

    select * into v_product from public.products where id=v_product_id for update;
    if not found or coalesce(v_product.status,'active')<>'active' then
      raise exception 'One selected product is no longer available.';
    end if;

    select exists(
      select 1 from public.product_variants
      where product_id=v_product.id and coalesce(stock_status,'in_stock')<>'hidden'
    ) into v_has_variants;

    -- Parent stock flags can be stale on old complicated products. When variants exist,
    -- the exact variant is authoritative. Parent stock is authoritative only for simple products.
    if not v_has_variants and coalesce(v_product.stock_status,'in_stock')='out_of_stock' then
      raise exception '% is out of stock.',v_product.name;
    end if;

    v_option_name:=coalesce(nullif(btrim(v_product.option_title),''),'Option');
    v_variant:=null;

    -- Exact id is the strongest identifier. If it belongs to this product, use it and
    -- canonicalize display dimensions from the database instead of rejecting legacy labels.
    if v_variant_id is not null then
      select * into v_variant
      from public.product_variants
      where id=v_variant_id and product_id=v_product.id and coalesce(stock_status,'in_stock')<>'hidden'
      for update;
      if not found then
        v_variant_id:=null;
        v_variant:=null;
      else
        v_actual_color:=nullif(btrim(coalesce(nullif(v_variant.color,''),nullif(v_variant.unit,''),'')),'');
        v_actual_size:=nullif(btrim(coalesce(nullif(v_variant.size,''),nullif(v_variant.label,''),'')),'');
        if v_actual_color is not null then v_color:=v_actual_color; end if;
        if v_actual_size is not null and (v_size is null or not public.wellone_option_matches(v_actual_size,v_size)) then
          v_size:=v_actual_size;
        end if;
      end if;
    end if;

    -- Recover older carts by their selected colour + option. Legacy rows containing
    -- "7, 8, 9" in one size field are supported by wellone_option_matches().
    if v_variant_id is null and v_has_variants and (v_color is not null or v_size is not null) then
      select count(*) into v_candidate_count
      from public.product_variants v
      where v.product_id=v_product.id
        and coalesce(v.stock_status,'in_stock')<>'hidden'
        and (v_color is null or lower(btrim(coalesce(nullif(v.color,''),nullif(v.unit,''),'')))=lower(btrim(v_color)))
        and (v_size is null or public.wellone_option_matches(coalesce(nullif(v.size,''),nullif(v.label,'')),v_size));

      if v_candidate_count > 0 and (v_candidate_count=1 or (v_color is not null and v_size is not null)) then
        select * into v_variant
        from public.product_variants v
        where v.product_id=v_product.id
          and coalesce(v.stock_status,'in_stock')<>'hidden'
          and (v_color is null or lower(btrim(coalesce(nullif(v.color,''),nullif(v.unit,''),'')))=lower(btrim(v_color)))
          and (v_size is null or public.wellone_option_matches(coalesce(nullif(v.size,''),nullif(v.label,'')),v_size))
        order by case when lower(btrim(coalesce(nullif(v.size,''),nullif(v.label,''),'')))=lower(btrim(coalesce(v_size,''))) then 0 else 1 end,
                 v.sort_order nulls last,v.id
        limit 1 for update;
        if found then v_variant_id:=v_variant.id; end if;
      end if;
    end if;

    if v_variant_id is null and v_has_variants then
      select count(*) into v_candidate_count
      from public.product_variants
      where product_id=v_product.id and coalesce(stock_status,'in_stock')<>'hidden';
      if v_candidate_count=1 then
        select * into v_variant
        from public.product_variants
        where product_id=v_product.id and coalesce(stock_status,'in_stock')<>'hidden'
        order by sort_order nulls last,id
        limit 1 for update;
        v_variant_id:=v_variant.id;
      else
        raise exception 'Please reselect the exact colour and % for %.',lower(v_option_name),v_product.name;
      end if;
    end if;

    if v_variant_id is not null then
      v_actual_color:=nullif(btrim(coalesce(nullif(v_variant.color,''),nullif(v_variant.unit,''),'')),'');
      v_actual_size:=nullif(btrim(coalesce(nullif(v_variant.size,''),nullif(v_variant.label,''),'')),'');
      if v_actual_color is not null then v_color:=v_actual_color; end if;
      if v_actual_size is not null and (v_size is null or not public.wellone_option_matches(v_actual_size,v_size)) then v_size:=v_actual_size; end if;
      if coalesce(v_variant.stock_status,'in_stock') in ('out_of_stock','hidden') then
        raise exception '% selected option is out of stock.',v_product.name;
      end if;
    end if;

    if v_product.track_inventory then
      if v_variant_id is not null then
        if coalesce(v_variant.stock,0)<v_qty then
          raise exception 'Only % unit(s) of % are available.',greatest(coalesce(v_variant.stock,0),0),v_product.name;
        end if;
        update public.product_variants
        set stock=stock-v_qty,
            stock_status=case when stock-v_qty>0 then 'in_stock' else 'out_of_stock' end
        where id=v_variant_id;
      else
        if coalesce(v_product.stock_quantity,0)<v_qty then
          raise exception 'Only % unit(s) of % are available.',greatest(coalesce(v_product.stock_quantity,0),0),v_product.name;
        end if;
        update public.products
        set stock_quantity=stock_quantity-v_qty,
            stock_status=case when stock_quantity-v_qty>0 then 'in_stock' else 'out_of_stock' end,
            updated_at=now()
        where id=v_product.id;
      end if;
    end if;

    v_offer_price:=null;
    if v_offer_id is not null then
      select oi.offer_price into v_offer_price
      from public.offer_items oi
      where oi.id=v_offer_id and oi.is_active=true and (oi.valid_until is null or oi.valid_until>now())
        and coalesce(oi.item_link,'') ~ ('(^|[?&])id=' || v_product.id::text || '(&|$)')
      limit 1;
    end if;

    v_price:=coalesce(v_offer_price,nullif(v_variant.price,0),nullif(v_product.price,0),nullif(v_variant.mrp,0),nullif(v_product.mrp,0),0);
    -- Exact-size rows may intentionally inherit the one shared image attached to the first
    -- row of their colour. Resolve that colour image before falling back to the product image.
    if v_variant_id is not null and v_color is not null then
      select coalesce(
        nullif(v_variant.image_url,''),
        (
          select nullif(v_img.image_url,'')
          from public.product_variants v_img
          where v_img.product_id=v_product.id
            and coalesce(v_img.stock_status,'in_stock')<>'hidden'
            and nullif(v_img.image_url,'') is not null
            and lower(btrim(coalesce(nullif(v_img.color,''),nullif(v_img.unit,''),''))) = lower(btrim(coalesce(v_color,'')))
          order by v_img.sort_order nulls last,v_img.id
          limit 1
        ),
        nullif(v_product.main_image_url,'')
      ) into v_image;
    else
      v_image:=coalesce(nullif(v_variant.image_url,''),nullif(v_product.main_image_url,''));
    end if;

    insert into public.order_items(
      order_id,product_id,variant_id,product_name,product_barcode,color,size,option_name,quantity,unit_price,line_total,image_url,stock_reserved
    ) values(
      v_order_id,v_product.id,v_variant_id,v_product.name,v_product.barcode,v_color,v_size,v_option_name,v_qty,v_price,v_price*v_qty,v_image,v_product.track_inventory
    );
    v_total:=v_total+(v_price*v_qty);

    insert into public.stock_movements(product_id,variant_id,quantity_delta,reason,reference_id,actor_type,actor_label)
    values(v_product.id,v_variant_id,-v_qty,case when v_product.track_inventory then 'customer_order' else 'customer_order_manual_stock' end,v_order_id,'customer',btrim(p_customer_name));

    if v_product.track_inventory and v_variant_id is not null then
      perform public.wellone_recalc_product_stock(v_product.id);
    end if;
  end loop;

  update public.orders set subtotal=v_total,total=v_total,updated_at=now() where id=v_order_id;
  insert into public.order_status_history(order_id,status,note,actor_type,actor_label)
  values(v_order_id,'placed','Order placed','customer',btrim(p_customer_name));

  return jsonb_build_object(
    'order_id',v_order_id,
    'order_number',v_order_number,
    'tracking_token',v_token,
    'status','placed',
    'total',v_total,
    'payment_method',p_payment_method
  );
end;
$$;

revoke all on function public.create_customer_order(text,text,text,text,jsonb) from public;
grant execute on function public.create_customer_order(text,text,text,text,jsonb) to anon, authenticated;

create or replace function public.get_customer_order(p_order_id uuid, p_tracking_token text)
returns jsonb
language sql
security definer
set search_path = public, extensions
as $$
select case when o.id is null then null else jsonb_build_object(
  'id',o.id,'order_number',o.order_number,'customer_name',o.customer_name,'customer_phone',o.customer_phone,'customer_address',o.customer_address,
  'payment_method',o.payment_method,'payment_status',o.payment_status,'status',o.status,'subtotal',o.subtotal,'total',o.total,
  'cancellation_reason',o.cancellation_reason,'cancelled_at',o.cancelled_at,'created_at',o.created_at,'updated_at',o.updated_at,
  'items',coalesce((select jsonb_agg(jsonb_build_object(
    'id',i.id,'product_id',i.product_id,'variant_id',i.variant_id,'product_name',i.product_name,'product_barcode',i.product_barcode,
    'color',i.color,'size',i.size,'option_name',i.option_name,'quantity',i.quantity,'unit_price',i.unit_price,'line_total',i.line_total,
    'image_url',i.image_url,'stock_reserved',i.stock_reserved
  ) order by i.created_at) from public.order_items i where i.order_id=o.id),'[]'::jsonb),
  'history',coalesce((select jsonb_agg(jsonb_build_object('status',h.status,'note',h.note,'actor_type',h.actor_type,'actor_label',h.actor_label,'created_at',h.created_at) order by h.created_at) from public.order_status_history h where h.order_id=o.id),'[]'::jsonb)
) end
from public.orders o
where o.id=p_order_id and o.tracking_hash=encode(digest(coalesce(p_tracking_token,''),'sha256'),'hex');
$$;

revoke all on function public.get_customer_order(uuid,text) from public;
grant execute on function public.get_customer_order(uuid,text) to anon, authenticated;

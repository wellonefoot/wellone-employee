-- WellOne v85: reliable cart/order lifecycle, configurable options and employee search
-- Run AFTER 05_inventory_barcode_offers.sql, 08_orders_employees_variants.sql and 09_realtime_exact_variant_sync.sql.

alter table public.orders drop constraint if exists orders_status_check;
alter table public.orders alter column status set default 'placed';
alter table public.orders add constraint orders_status_check
  check (status in ('placed','confirmed','packed','out_for_delivery','delivered','cancelled'));

alter table public.order_items add column if not exists option_name text;
update public.order_items set option_name='Size' where option_name is null and nullif(btrim(size),'') is not null;

-- Customer order creation always resolves the exact database variant and stores
-- the product's configurable option name (Size, Quantity, ml, Pack, etc.).
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
    values(v_product.id,v_variant_id,-v_qty,'customer_order',v_order_id,'customer',btrim(p_customer_name));

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
  'items',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'product_id',i.product_id,'variant_id',i.variant_id,'product_name',i.product_name,'color',i.color,'size',i.size,'option_name',i.option_name,'quantity',i.quantity,'unit_price',i.unit_price,'line_total',i.line_total,'image_url',i.image_url,'stock_reserved',i.stock_reserved) order by i.created_at) from public.order_items i where i.order_id=o.id),'[]'::jsonb),
  'history',coalesce((select jsonb_agg(jsonb_build_object('status',h.status,'note',h.note,'actor_type',h.actor_type,'actor_label',h.actor_label,'created_at',h.created_at) order by h.created_at) from public.order_status_history h where h.order_id=o.id),'[]'::jsonb)
) end
from public.orders o
where o.id=p_order_id and o.tracking_hash=encode(digest(coalesce(p_tracking_token,''),'sha256'),'hex');
$$;
revoke all on function public.get_customer_order(uuid,text) from public;
grant execute on function public.get_customer_order(uuid,text) to anon, authenticated;

create or replace function public.admin_update_order_status(p_order_id uuid, p_status text, p_note text default null)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_admin uuid := auth.uid(); v_old text;
begin
  if v_admin is null or not exists(select 1 from public.admin_users where id=v_admin) then raise exception 'Admin login required.'; end if;
  if p_status not in ('placed','confirmed','packed','out_for_delivery','delivered','cancelled') then raise exception 'Invalid order status.'; end if;
  select status into v_old from public.orders where id=p_order_id for update;
  if not found then raise exception 'Order not found.'; end if;
  if v_old='cancelled' and p_status<>'cancelled' then raise exception 'Cancelled order cannot be reopened.'; end if;
  if p_status='cancelled' and v_old<>'cancelled' then perform public.restore_order_stock(p_order_id,'admin',v_admin::text); end if;
  update public.orders set status=p_status,cancellation_reason=case when p_status='cancelled' then coalesce(nullif(btrim(p_note),''),'Cancelled by admin') else cancellation_reason end,cancelled_at=case when p_status='cancelled' then now() else cancelled_at end,updated_at=now() where id=p_order_id;
  insert into public.order_status_history(order_id,status,note,actor_type,actor_label) values(p_order_id,p_status,nullif(btrim(p_note),''),'admin',v_admin::text);
end;
$$;
revoke all on function public.admin_update_order_status(uuid,text,text) from public;
grant execute on function public.admin_update_order_status(uuid,text,text) to authenticated;

-- Shared employee-safe product payload. Employees can sell products that have
-- no barcode by finding them by name; exact variant stock remains authoritative.
create or replace function public.employee_get_product(p_token text, p_product_id uuid)
returns jsonb
language plpgsql security definer set search_path=public,extensions as $$
declare v_emp uuid; p record;
begin
  v_emp := public.employee_from_token(p_token); if v_emp is null then raise exception 'Employee login expired.'; end if;
  select pr.* into p from public.products pr where pr.id=p_product_id and coalesce(pr.status,'active')='active' limit 1;
  if not found then return null; end if;
  return jsonb_build_object(
    'id',p.id,'name',p.name,'barcode',case when p.barcode_enabled then p.barcode else null end,'image_url',p.main_image_url,'option_title',p.option_title,
    'track_inventory',p.track_inventory,'stock_quantity',p.stock_quantity,'stock_status',p.stock_status,
    'variants',coalesce((select jsonb_agg(jsonb_build_object('id',v.id,'color',coalesce(nullif(v.color,''),nullif(v.unit,'')),'size',coalesce(nullif(v.size,''),nullif(v.label,'')),'stock',v.stock,'stock_status',v.stock_status,'price',coalesce(v.price,p.price),'image_url',coalesce(nullif(v.image_url,''),p.main_image_url)) order by v.sort_order,v.id) from public.product_variants v where v.product_id=p.id),'[]'::jsonb)
  );
end; $$;
revoke all on function public.employee_get_product(text,uuid) from public;
grant execute on function public.employee_get_product(text,uuid) to anon, authenticated;

create or replace function public.employee_get_product_by_barcode(p_token text, p_barcode text)
returns jsonb
language plpgsql security definer set search_path=public,extensions as $$
declare v_emp uuid; v_product_id uuid;
begin
  v_emp := public.employee_from_token(p_token); if v_emp is null then raise exception 'Employee login expired.'; end if;
  select id into v_product_id from public.products where barcode_enabled=true and lower(barcode)=lower(btrim(p_barcode)) and coalesce(status,'active')='active' limit 1;
  if v_product_id is null then return null; end if;
  return public.employee_get_product(p_token,v_product_id);
end; $$;
revoke all on function public.employee_get_product_by_barcode(text,text) from public;
grant execute on function public.employee_get_product_by_barcode(text,text) to anon, authenticated;

create or replace function public.employee_search_products(p_token text, p_query text)
returns jsonb
language plpgsql security definer set search_path=public,extensions as $$
declare v_emp uuid; v_query text:=btrim(coalesce(p_query,'')); v_result jsonb;
begin
  v_emp := public.employee_from_token(p_token); if v_emp is null then raise exception 'Employee login expired.'; end if;
  if v_query='' then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(public.employee_get_product(p_token,x.id) order by x.exact_barcode desc,x.name),'[]'::jsonb)
    into v_result
    from (
      select p.id,p.name,(p.barcode_enabled=true and lower(coalesce(p.barcode,''))=lower(v_query)) as exact_barcode
      from public.products p
      where coalesce(p.status,'active')='active'
        and (p.name ilike '%'||v_query||'%' or (p.barcode_enabled=true and p.barcode ilike '%'||v_query||'%'))
      order by exact_barcode desc,p.name
      limit 20
    ) x;
  return v_result;
end; $$;
revoke all on function public.employee_search_products(text,text) from public;
grant execute on function public.employee_search_products(text,text) to anon, authenticated;

create or replace function public.employee_record_sale(p_token text, p_product_id uuid, p_variant_id uuid, p_quantity integer default 1)
returns jsonb
language plpgsql security definer set search_path=public,extensions as $$
declare v_emp uuid; v_username text; p public.products%rowtype; v public.product_variants%rowtype; q integer := greatest(1,coalesce(p_quantity,1));
begin
  v_emp := public.employee_from_token(p_token); if v_emp is null then raise exception 'Employee login expired.'; end if;
  select username into v_username from public.employees where id=v_emp;
  select * into p from public.products where id=p_product_id for update;
  if not found then raise exception 'Product not found.'; end if;
  if not p.track_inventory then raise exception 'Stock tracking is off for this item. Turn it on in Admin first.'; end if;
  if p_variant_id is not null then
    select * into v from public.product_variants where id=p_variant_id and product_id=p.id for update;
    if not found then raise exception 'Option not found.'; end if;
    if coalesce(v.stock_status,'in_stock')='out_of_stock' or coalesce(v.stock,0)<q then raise exception 'Only % unit(s) are available.',greatest(coalesce(v.stock,0),0); end if;
    update public.product_variants set stock=stock-q,stock_status=case when stock-q>0 then 'in_stock' else 'out_of_stock' end where id=v.id;
    perform public.wellone_recalc_product_stock(p.id);
  else
    if exists(select 1 from public.product_variants where product_id=p.id) then raise exception 'Select the exact product option.'; end if;
    if coalesce(p.stock_quantity,0)<q then raise exception 'Only % unit(s) are available.',greatest(coalesce(p.stock_quantity,0),0); end if;
    update public.products set stock_quantity=stock_quantity-q,stock_status=case when stock_quantity-q>0 then 'in_stock' else 'out_of_stock' end,updated_at=now() where id=p.id;
  end if;
  insert into public.stock_movements(product_id,variant_id,quantity_delta,reason,actor_type,actor_label) values(p.id,p_variant_id,-q,'employee_sale','employee',v_username);
  return public.employee_get_product(p_token,p.id);
end; $$;
revoke all on function public.employee_record_sale(text,uuid,uuid,integer) from public;
grant execute on function public.employee_record_sale(text,uuid,uuid,integer) to anon, authenticated;

-- Ensure order updates remain live after the new status migration.
do $$
begin
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='orders') then
    alter publication supabase_realtime add table public.orders;
  end if;
exception when others then
  raise notice 'Could not add orders to supabase_realtime publication automatically: %', sqlerrm;
end $$;

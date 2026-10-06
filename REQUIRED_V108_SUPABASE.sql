-- SHOPIZO v108 — per-staff sales history + admin sales dashboard
-- Run this file once in Supabase SQL Editor AFTER the existing v107 schema.

create unique index if not exists employees_username_unique on public.employees(lower(username));

create table if not exists public.staff_sales (
  id bigserial primary key,
  source_movement_id bigint unique references public.stock_movements(id) on delete set null,
  employee_id uuid references public.employees(id) on delete set null,
  employee_username text not null,
  product_id uuid references public.products(id) on delete set null,
  variant_id uuid references public.product_variants(id) on delete set null,
  product_name text not null,
  variant_label text,
  product_barcode text,
  quantity integer not null check (quantity > 0),
  unit_price numeric(12,2) not null default 0,
  total_amount numeric(12,2) not null default 0,
  created_at timestamptz not null default now()
);

create index if not exists staff_sales_employee_created_idx on public.staff_sales(employee_id, created_at desc);
create index if not exists staff_sales_created_idx on public.staff_sales(created_at desc);
create index if not exists staff_sales_username_created_idx on public.staff_sales(lower(employee_username), created_at desc);

alter table public.staff_sales enable row level security;
revoke all on table public.staff_sales from anon, authenticated;

-- Recover historical staff sales already present in stock_movements.
-- source_movement_id keeps this backfill safe to run more than once.
insert into public.staff_sales(
  source_movement_id,employee_id,employee_username,product_id,variant_id,
  product_name,variant_label,product_barcode,quantity,unit_price,total_amount,created_at
)
select
  sm.id,
  e.id,
  coalesce(nullif(sm.actor_label,''),e.username,'Unknown staff'),
  sm.product_id,
  sm.variant_id,
  coalesce(nullif(p.name,''),'Deleted product'),
  nullif(concat_ws(' · ',nullif(v.color,''),nullif(v.size,''),nullif(v.unit,'')),''),
  nullif(p.barcode,''),
  greatest(abs(sm.quantity_delta),1),
  coalesce(nullif(v.price::text,'')::numeric,nullif(p.price::text,'')::numeric,0),
  greatest(abs(sm.quantity_delta),1) * coalesce(nullif(v.price::text,'')::numeric,nullif(p.price::text,'')::numeric,0),
  sm.created_at
from public.stock_movements sm
left join public.employees e on lower(e.username)=lower(coalesce(sm.actor_label,''))
left join public.products p on p.id=sm.product_id
left join public.product_variants v on v.id=sm.variant_id
where sm.actor_type='employee'
  and sm.reason in ('employee_sale','employee_sale_manual_stock')
  and sm.quantity_delta < 0
on conflict (source_movement_id) do nothing;

-- Record a stock sale AND a permanent staff-attributed sale-history row atomically.
create or replace function public.employee_record_sale(
  p_token text,
  p_product_id uuid,
  p_variant_id uuid,
  p_quantity integer default 1
)
returns jsonb
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
  v_emp uuid;
  v_username text;
  p public.products%rowtype;
  v public.product_variants%rowtype;
  q integer:=greatest(1,coalesce(p_quantity,1));
  v_movement_id bigint;
  v_unit_price numeric(12,2):=0;
  v_variant_label text;
begin
  v_emp:=public.employee_from_token_role(p_token,'sales');
  if v_emp is null then raise exception 'Sales staff login expired or not permitted.'; end if;

  select username into v_username from public.employees where id=v_emp;
  select * into p from public.products where id=p_product_id and coalesce(status,'active')='active' for update;
  if not found then raise exception 'Product not found.'; end if;
  if coalesce(p.stock_status,'in_stock')='out_of_stock' then raise exception 'This item is out of stock.'; end if;

  if p_variant_id is not null then
    select * into v from public.product_variants
      where id=p_variant_id and product_id=p.id and coalesce(stock_status,'in_stock')<>'hidden'
      for update;
    if not found then raise exception 'This option is unavailable.'; end if;
    if coalesce(v.stock_status,'in_stock')='out_of_stock' then raise exception 'This exact option is out of stock.'; end if;

    v_unit_price:=coalesce(nullif(v.price::text,'')::numeric,nullif(p.price::text,'')::numeric,0);
    v_variant_label:=nullif(concat_ws(' · ',nullif(v.color,''),nullif(v.size,''),nullif(v.unit,'')),'');
    if v_variant_label is null then v_variant_label:=coalesce(nullif(v.label,''),'Standard option'); end if;

    if p.track_inventory then
      if coalesce(v.stock,0)<q then raise exception 'Only % unit(s) are available.',greatest(coalesce(v.stock,0),0); end if;
      update public.product_variants
        set stock=stock-q,
            stock_status=case when stock-q>0 then 'in_stock' else 'out_of_stock' end
        where id=v.id;
      perform public.wellone_recalc_product_stock(p.id);
    end if;
  else
    if exists(select 1 from public.product_variants where product_id=p.id and coalesce(stock_status,'in_stock')<>'hidden') then
      raise exception 'Select the exact product option.';
    end if;
    v_unit_price:=coalesce(nullif(p.price::text,'')::numeric,0);
    v_variant_label:='Standard item';
    if p.track_inventory then
      if coalesce(p.stock_quantity,0)<q then raise exception 'Only % unit(s) are available.',greatest(coalesce(p.stock_quantity,0),0); end if;
      update public.products
        set stock_quantity=stock_quantity-q,
            stock_status=case when stock_quantity-q>0 then 'in_stock' else 'out_of_stock' end,
            updated_at=now()
        where id=p.id;
    end if;
  end if;

  insert into public.stock_movements(product_id,variant_id,quantity_delta,reason,actor_type,actor_label)
  values(p.id,p_variant_id,-q,case when p.track_inventory then 'employee_sale' else 'employee_sale_manual_stock' end,'employee',v_username)
  returning id into v_movement_id;

  insert into public.staff_sales(
    source_movement_id,employee_id,employee_username,product_id,variant_id,
    product_name,variant_label,product_barcode,quantity,unit_price,total_amount,created_at
  ) values(
    v_movement_id,v_emp,v_username,p.id,p_variant_id,
    p.name,v_variant_label,nullif(p.barcode,''),q,v_unit_price,(q*v_unit_price),now()
  );

  return public.employee_get_product(p_token,p.id);
end;
$$;
revoke all on function public.employee_record_sale(text,uuid,uuid,integer) from public;
grant execute on function public.employee_record_sale(text,uuid,uuid,integer) to anon, authenticated;

-- Sales staff can read only the history linked to their own current login token.
drop function if exists public.employee_sales_history(text,date,date);
create function public.employee_sales_history(
  p_token text,
  p_from date default null,
  p_to date default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
  v_emp uuid;
  v_sales jsonb;
  v_summary jsonb;
begin
  v_emp:=public.employee_from_token_role(p_token,'sales');
  if v_emp is null then raise exception 'Sales staff login expired or not permitted.'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id',x.id,
      'product_name',x.product_name,
      'variant_label',x.variant_label,
      'barcode',x.product_barcode,
      'quantity',x.quantity,
      'unit_price',x.unit_price,
      'total_amount',x.total_amount,
      'created_at',x.created_at,
      'sale_date',to_char(x.created_at at time zone 'Asia/Kolkata','YYYY-MM-DD')
    ) order by x.created_at desc),'[]'::jsonb)
  into v_sales
  from public.staff_sales x
  where x.employee_id=v_emp
    and (p_from is null or x.created_at >= (p_from::timestamp at time zone 'Asia/Kolkata'))
    and (p_to is null or x.created_at < ((p_to+1)::timestamp at time zone 'Asia/Kolkata'));

  select jsonb_build_object(
      'transactions',count(*),
      'units',coalesce(sum(x.quantity),0),
      'amount',coalesce(sum(x.total_amount),0)
    )
  into v_summary
  from public.staff_sales x
  where x.employee_id=v_emp
    and (p_from is null or x.created_at >= (p_from::timestamp at time zone 'Asia/Kolkata'))
    and (p_to is null or x.created_at < ((p_to+1)::timestamp at time zone 'Asia/Kolkata'));

  return jsonb_build_object('sales',v_sales,'summary',v_summary);
end;
$$;
revoke all on function public.employee_sales_history(text,date,date) from public;
grant execute on function public.employee_sales_history(text,date,date) to anon, authenticated;

-- Admin dashboard: filtered sale list + date-range leaderboard across all Sales Staff.
drop function if exists public.admin_staff_sales_dashboard(uuid,date,date);
create function public.admin_staff_sales_dashboard(
  p_employee_id uuid default null,
  p_from date default null,
  p_to date default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
  v_sales jsonb;
  v_leaderboard jsonb;
  v_staff jsonb;
  v_totals jsonb;
begin
  if auth.uid() is null or not exists(select 1 from public.admin_users au where au.id=auth.uid()) then
    raise exception 'Admin login required.';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id',x.id,
      'employee_id',x.employee_id,
      'employee_username',x.employee_username,
      'product_name',x.product_name,
      'variant_label',x.variant_label,
      'barcode',x.product_barcode,
      'quantity',x.quantity,
      'unit_price',x.unit_price,
      'total_amount',x.total_amount,
      'created_at',x.created_at,
      'sale_date',to_char(x.created_at at time zone 'Asia/Kolkata','YYYY-MM-DD')
    ) order by x.created_at desc),'[]'::jsonb)
  into v_sales
  from public.staff_sales x
  where (p_employee_id is null or x.employee_id=p_employee_id)
    and (p_from is null or x.created_at >= (p_from::timestamp at time zone 'Asia/Kolkata'))
    and (p_to is null or x.created_at < ((p_to+1)::timestamp at time zone 'Asia/Kolkata'));

  select coalesce(jsonb_agg(jsonb_build_object(
      'employee_id',r.employee_id,
      'username',r.username,
      'transactions',r.transactions,
      'units',r.units,
      'amount',r.amount
    ) order by r.units desc,r.transactions desc,r.amount desc,r.username),'[]'::jsonb)
  into v_leaderboard
  from (
    select
      s.employee_id,
      coalesce(max(e.username),max(s.employee_username),'Unknown staff') as username,
      count(*)::bigint as transactions,
      coalesce(sum(s.quantity),0)::bigint as units,
      coalesce(sum(s.total_amount),0)::numeric(14,2) as amount
    from public.staff_sales s
    left join public.employees e on e.id=s.employee_id
    where (p_from is null or s.created_at >= (p_from::timestamp at time zone 'Asia/Kolkata'))
      and (p_to is null or s.created_at < ((p_to+1)::timestamp at time zone 'Asia/Kolkata'))
    group by s.employee_id
  ) r;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id',e.id,'username',e.username,'is_active',e.is_active
    ) order by lower(e.username)),'[]'::jsonb)
  into v_staff
  from public.employees e
  where coalesce(e.portal_role,'sales')='sales';

  select jsonb_build_object(
      'transactions',count(*),
      'units',coalesce(sum(s.quantity),0),
      'amount',coalesce(sum(s.total_amount),0)
    )
  into v_totals
  from public.staff_sales s
  where (p_employee_id is null or s.employee_id=p_employee_id)
    and (p_from is null or s.created_at >= (p_from::timestamp at time zone 'Asia/Kolkata'))
    and (p_to is null or s.created_at < ((p_to+1)::timestamp at time zone 'Asia/Kolkata'));

  return jsonb_build_object(
    'sales',v_sales,
    'leaderboard',v_leaderboard,
    'staff',v_staff,
    'totals',v_totals
  );
end;
$$;
revoke all on function public.admin_staff_sales_dashboard(uuid,date,date) from public;
grant execute on function public.admin_staff_sales_dashboard(uuid,date,date) to authenticated;

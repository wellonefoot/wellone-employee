-- SHOPIZO v109 — reverse an individual staff sale and return exact tracked stock.
-- PREREQUISITE: run REQUIRED_V108_SUPABASE.sql first, if not already applied.
-- Run this migration once in Supabase SQL Editor BEFORE deploying the v109 employee site.
-- Safe to re-run: ADD COLUMN IF NOT EXISTS and CREATE OR REPLACE FUNCTION.

begin;

alter table public.staff_sales
  add column if not exists undone_at timestamptz,
  add column if not exists undone_by_employee_id uuid references public.employees(id) on delete set null,
  add column if not exists undo_movement_id bigint references public.stock_movements(id) on delete set null;

create unique index if not exists staff_sales_undo_movement_unique
  on public.staff_sales(undo_movement_id) where undo_movement_id is not null;

-- A sales staff account may reverse ONLY its own sales. The row is locked so
-- concurrent button presses cannot return stock more than once. The original
-- stock movement records whether inventory was tracked at sale time.
create or replace function public.employee_undo_sale(
  p_token text,
  p_sale_id bigint
)
returns jsonb
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
  v_emp uuid;
  v_username text;
  v_sale public.staff_sales%rowtype;
  v_original_reason text;
  v_product public.products%rowtype;
  v_variant public.product_variants%rowtype;
  v_undo_movement_id bigint;
  v_restored boolean:=false;
begin
  v_emp:=public.employee_from_token_role(p_token,'sales');
  if v_emp is null then
    raise exception 'Sales staff login expired or not permitted.';
  end if;

  select * into v_sale
  from public.staff_sales
  where id=p_sale_id and employee_id=v_emp
  for update;
  if not found then
    raise exception 'Sale not found in your account.';
  end if;
  if v_sale.undone_at is not null then
    raise exception 'This sale has already been undone.';
  end if;

  -- Never guess whether an old sale originally reduced stock.
  -- Missing original movement -> ask the admin to reconcile manually.
  select sm.reason into v_original_reason
  from public.stock_movements sm
  where sm.id=v_sale.source_movement_id
    and sm.reason in ('employee_sale','employee_sale_manual_stock')
    and sm.quantity_delta=-v_sale.quantity
    and sm.actor_type='employee'
    and sm.product_id is not distinct from v_sale.product_id
    and sm.variant_id is not distinct from v_sale.variant_id;
  if v_original_reason is null then
    raise exception 'Cannot safely undo: original stock movement is missing or changed. Contact admin.';
  end if;

  select username into v_username from public.employees where id=v_emp;

  if v_original_reason='employee_sale' then
    if v_sale.product_id is null then
      raise exception 'Cannot restore stock because this product was deleted. Contact admin.';
    end if;

    select * into v_product from public.products
    where id=v_sale.product_id for update;
    if not found then
      raise exception 'Cannot restore stock because this product was deleted. Contact admin.';
    end if;

    if v_sale.variant_id is not null then
      select * into v_variant from public.product_variants
      where id=v_sale.variant_id and product_id=v_product.id for update;
      if not found then
        raise exception 'The original colour/size was removed. Contact admin to restore stock.';
      end if;

      update public.product_variants
      set stock=greatest(coalesce(stock,0),0)+v_sale.quantity,
          stock_status=case
            when coalesce(stock_status,'in_stock')='hidden' then 'hidden'
            when v_product.track_inventory then 'in_stock'
            else stock_status
          end
      where id=v_variant.id;
      if v_product.track_inventory then
        perform public.wellone_recalc_product_stock(v_product.id);
      end if;
    else
      if exists(select 1 from public.product_variants where product_id=v_product.id) then
        raise exception 'Product options changed since this sale. Contact admin to restore exact stock.';
      end if;
      update public.products
      set stock_quantity=greatest(coalesce(stock_quantity,0),0)+v_sale.quantity,
          stock_status=case when track_inventory then 'in_stock' else stock_status end,
          updated_at=now()
      where id=v_product.id;
    end if;

    insert into public.stock_movements(
      product_id,variant_id,quantity_delta,reason,actor_type,actor_label
    ) values(
      v_sale.product_id,v_sale.variant_id,v_sale.quantity,
      'employee_sale_undo','employee',v_username
    ) returning id into v_undo_movement_id;

    v_restored:=true;
  end if;
  -- An 'employee_sale_manual_stock' never deducted physical inventory.
  -- Reverse the accounting sale only; do NOT create fake stock.

  update public.staff_sales
  set undone_at=now(),
      undone_by_employee_id=v_emp,
      undo_movement_id=v_undo_movement_id
  where id=v_sale.id;

  return jsonb_build_object(
    'sale_id',v_sale.id,
    'product_id',v_sale.product_id,
    'variant_id',v_sale.variant_id,
    'quantity',v_sale.quantity,
    'stock_restored',v_restored
  );
end;
$$;
revoke all on function public.employee_undo_sale(text,bigint) from public;
grant execute on function public.employee_undo_sale(text,bigint) to anon,authenticated;

-- Sales history keeps undone rows visible for accountability, but only counts
-- active sales in sales/units/amount summary.
create or replace function public.employee_sales_history(
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
      'undone_at',x.undone_at,
      'sale_date',to_char(x.created_at at time zone 'Asia/Kolkata','YYYY-MM-DD')
    ) order by x.created_at desc,x.id desc),'[]'::jsonb)
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
  where x.employee_id=v_emp and x.undone_at is null
    and (p_from is null or x.created_at >= (p_from::timestamp at time zone 'Asia/Kolkata'))
    and (p_to is null or x.created_at < ((p_to+1)::timestamp at time zone 'Asia/Kolkata'));

  return jsonb_build_object('sales',v_sales,'summary',v_summary);
end;
$$;
revoke all on function public.employee_sales_history(text,date,date) from public;
grant execute on function public.employee_sales_history(text,date,date) to anon,authenticated;

-- Admin's existing dashboard remains compatible, with undone sales excluded
-- from active records, totals and leaderboard; full audit rows remain in staff_sales.
create or replace function public.admin_staff_sales_dashboard(
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
  where x.undone_at is null
    and (p_employee_id is null or x.employee_id=p_employee_id)
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
    where s.undone_at is null
      and (p_from is null or s.created_at >= (p_from::timestamp at time zone 'Asia/Kolkata'))
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
  where s.undone_at is null
    and (p_employee_id is null or s.employee_id=p_employee_id)
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

commit;

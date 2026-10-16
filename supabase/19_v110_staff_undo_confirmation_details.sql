-- SHOPIZO Sales Staff v110 — supply exact product image and item ID for Undo Sale confirmation.
-- Prerequisite: existing REQUIRED_V109_SUPABASE.sql is already applied.
-- Run once in Supabase SQL Editor, then deploy the v110 employee site.
-- No changes to stock or sales data; safe to re-run.

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
      'product_id',x.product_id,
      'item_id',coalesce(nullif(x.product_barcode,''),nullif(p.barcode,''),x.product_id::text),
      'image_url',coalesce(nullif(v.image_url,''),nullif(p.main_image_url,'')),
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
  left join public.products p on p.id=x.product_id
  left join public.product_variants v on v.id=x.variant_id and v.product_id=x.product_id
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

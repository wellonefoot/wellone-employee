-- WellOne v82: reliable realtime inventory sync for customer/admin/employee/order sites
-- Run once AFTER 08_orders_employees_variants.sql. Safe to run more than once.

do $$
declare t text;
begin
  foreach t in array array['products','product_variants','orders','offer_items'] loop
    if to_regclass('public.' || t) is not null and not exists(
      select 1 from pg_publication_tables
      where pubname='supabase_realtime' and schemaname='public' and tablename=t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
exception when others then
  raise notice 'Realtime publication update notice: %', sqlerrm;
end $$;

-- Make sure exact colour + size lookups stay fast as the catalogue grows.
create index if not exists product_variants_product_color_size_stock_idx
  on public.product_variants(product_id, lower(coalesce(color,'')), lower(coalesce(size,'')), stock);

create index if not exists products_enabled_barcode_idx
  on public.products(barcode) where barcode_enabled = true;

-- Include complete old variant rows in realtime DELETE payloads so open employee/customer views can refresh reliably.
do $$
begin
  if to_regclass('public.product_variants') is not null then
    alter table public.product_variants replica identity full;
  end if;
exception when others then
  raise notice 'Could not set product_variants replica identity: %', sqlerrm;
end $$;

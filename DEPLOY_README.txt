WellOne Employee v85 — flexible product sales
- Separate deployment; index.html is at ZIP root.
- Login with employee username/password created in Admin > Employees.
- One search accepts a product name or barcode.
- Employees can sell an exact colour + size, ml, litre, pack or any custom admin-created option.
- Sold quantity defaults to 1; only the selected exact option is deducted.
- v85 uses a fresh service-worker/cache namespace and keeps live Supabase inventory calls network-fresh.
- Run supabase/10_v85_heavy_commerce_flow.sql once before using this build.

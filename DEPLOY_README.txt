WellOne Employee v83 — fixed/optimized
- Separate deployment; index.html is at ZIP root.
- Login with employee username/password created in Admin > Employees.
- Barcode lookup shows exact colour + size variants and stock.
- Sold quantity defaults to 1; only the selected exact variant is deducted.
- v83 uses a fresh service-worker/cache namespace and keeps live Supabase inventory calls network-fresh.
- No new database migration is required for this v83 performance/fix pass.

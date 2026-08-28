WellOne Employee v86 — exact-option sales desk

DATABASE FIRST
- If migration 10 is not already installed, run supabase/10_v85_heavy_commerce_flow.sql.
- Then run supabase/11_v86_exact_options_manual_stock_live.sql.

DEPLOY
- Deploy the contents of this folder to the employee site root.

V86
- Login uses employee username/password created in Admin > Employees.
- One search accepts product name or barcode.
- Exact colour + size/ml/pack options appear separately and must be selected separately.
- Tracked stock deducts only the selected exact variant.
- Manual-stock sales are recorded while availability remains controlled by Admin.
- Fixed the realtime-variable crash that could stop the desk immediately after login.

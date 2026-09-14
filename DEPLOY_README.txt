WellOne Employee v88 — stable staff login + exact-option sales

DATABASE
- v88 client reliability changes require NO new SQL.
- Existing employee RPCs require migrations 10 and 11 if they were never installed.

DEPLOY
- Deploy the CONTENTS of this folder to the Employee site root.

V88 PERFORMANCE / RELIABILITY
- Removed artificial Promise.race timeouts from employee login, product search and sale writes. This avoids false timeout messages while a valid Supabase request is still running.
- Employee search is server-side and the SQL RPC is capped to 20 product matches.
- Product stock refreshes live only for the currently opened product.
- Exact colour + option groups remain independent.
- Manual-stock sales are recorded without fake quantity deduction; Admin controls availability.

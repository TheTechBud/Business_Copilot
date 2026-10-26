-- 02_verify_raw_load.sql
-- Run in DBeaver with Alt+X (Execute Script). Sections A-B work BEFORE loading (schema check);
-- sections C-G are for AFTER the load. "Expected" values were computed from your source files.

-- A. The eight tables exist
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'raw' ORDER BY table_name;

-- B. Foreign keys: expect 8 rows, convalidated = true
SELECT conrelid::regclass AS child_table, conname, confrelid::regclass AS parent_table, convalidated
FROM pg_constraint
WHERE contype = 'f' AND connamespace = 'raw'::regnamespace
ORDER BY 1, 2;

-- C. Row counts vs the published Berka counts: every "matches" should be true
WITH counts AS (
    SELECT 'district' AS table_name, COUNT(*) AS n FROM raw.district
    UNION ALL SELECT 'account', COUNT(*) FROM raw.account
    UNION ALL SELECT 'client',  COUNT(*) FROM raw.client
    UNION ALL SELECT 'disp',    COUNT(*) FROM raw.disp
    UNION ALL SELECT 'card',    COUNT(*) FROM raw.card
    UNION ALL SELECT 'loan',    COUNT(*) FROM raw.loan
    UNION ALL SELECT 'order',   COUNT(*) FROM raw."order"
    UNION ALL SELECT 'trans',   COUNT(*) FROM raw.trans
), expected(table_name, expected_n) AS (
    VALUES ('district',77),('account',4500),('client',5369),('disp',5369),
           ('card',892),('loan',682),('order',6471),('trans',1056320)
)
SELECT c.table_name, c.n AS actual, e.expected_n, (c.n = e.expected_n) AS matches
FROM counts c JOIN expected e USING (table_name)
ORDER BY e.expected_n;

-- D. Orphan check (should all be 0; the foreign keys already guarantee it)
SELECT 'trans -> account' AS relationship, COUNT(*) AS orphans
FROM raw.trans t LEFT JOIN raw.account a ON a.account_id = t.account_id WHERE a.account_id IS NULL
UNION ALL
SELECT 'disp -> client', COUNT(*)
FROM raw.disp d LEFT JOIN raw.client c ON c.client_id = d.client_id WHERE c.client_id IS NULL
UNION ALL
SELECT 'card -> disp', COUNT(*)
FROM raw.card k LEFT JOIN raw.disp d ON d.disp_id = k.disp_id WHERE d.disp_id IS NULL;

-- E. Raw integer date ranges. Expected: trans 930101..981231, account 930101..971229, loan 930705..981208
SELECT 'trans' AS tbl, MIN(date), MAX(date) FROM raw.trans
UNION ALL SELECT 'account', MIN(date), MAX(date) FROM raw.account
UNION ALL SELECT 'loan',    MIN(date), MAX(date) FROM raw.loan;

-- F. Money totals. Expected: amount 6257793560.30, balance 40687683194.00
SELECT SUM(amount) AS total_amount, SUM(balance) AS total_balance FROM raw.trans;

-- G. How empty fields were stored in raw.trans. Expected:
--    operation NULL 183114 | k_symbol NULL 481881 | k_symbol single space 53433 | bank NULL 782812 | account NULL 760931
SELECT COUNT(*) FILTER (WHERE operation IS NULL)  AS operation_null,
       COUNT(*) FILTER (WHERE k_symbol  IS NULL)  AS k_symbol_null,
       COUNT(*) FILTER (WHERE k_symbol  = ' ')    AS k_symbol_space,
       COUNT(*) FILTER (WHERE bank      IS NULL)  AS bank_null,
       COUNT(*) FILTER (WHERE account   IS NULL)  AS account_null
FROM raw.trans;

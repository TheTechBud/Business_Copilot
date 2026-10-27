-- 05_validate_staging.sql
-- Run AFTER 04_create_staging.sql. One query at a time (Ctrl+Enter). Every "Expected" value was computed
-- independently from the source files. If something differs, send me the query number and your result.

-- V1. Row counts: staging must have exactly as many rows as raw (every "matches" = true)
WITH s AS (
    SELECT 'district' AS t, COUNT(*) AS n FROM staging.district
    UNION ALL SELECT 'account', COUNT(*) FROM staging.account
    UNION ALL SELECT 'client',  COUNT(*) FROM staging.client
    UNION ALL SELECT 'disp',    COUNT(*) FROM staging.disp
    UNION ALL SELECT 'card',    COUNT(*) FROM staging.card
    UNION ALL SELECT 'loan',    COUNT(*) FROM staging.loan
    UNION ALL SELECT 'order',   COUNT(*) FROM staging.standing_order
    UNION ALL SELECT 'trans',   COUNT(*) FROM staging.trans
), r AS (
    SELECT 'district' AS t, COUNT(*) AS n FROM raw.district
    UNION ALL SELECT 'account', COUNT(*) FROM raw.account
    UNION ALL SELECT 'client',  COUNT(*) FROM raw.client
    UNION ALL SELECT 'disp',    COUNT(*) FROM raw.disp
    UNION ALL SELECT 'card',    COUNT(*) FROM raw.card
    UNION ALL SELECT 'loan',    COUNT(*) FROM raw.loan
    UNION ALL SELECT 'order',   COUNT(*) FROM raw."order"
    UNION ALL SELECT 'trans',   COUNT(*) FROM raw.trans
)
SELECT s.t AS table_name, r.n AS raw_rows, s.n AS staging_rows, (r.n = s.n) AS matches
FROM s JOIN r USING (t)
ORDER BY r.n;


-- V2. Codes that were not translated (rule 3). Expected: every "problems" = 0
SELECT 'account.statement_frequency' AS check_name, COUNT(*) AS problems FROM staging.account WHERE statement_frequency IS NULL
UNION ALL SELECT 'trans.direction',    COUNT(*) FROM staging.trans WHERE direction IS NULL
UNION ALL SELECT 'trans.txn_category', COUNT(*) FROM staging.trans WHERE txn_category IS NULL
UNION ALL SELECT 'loan.status_desc',   COUNT(*) FROM staging.loan  WHERE status_desc IS NULL
UNION ALL SELECT 'client.gender/birth_date', COUNT(*) FROM staging.client WHERE gender IS NULL OR birth_date IS NULL
UNION ALL SELECT 'card.issued_date',   COUNT(*) FROM staging.card  WHERE issued_date IS NULL;


-- V3. Date ranges after conversion. Expected:
--   trans 1993-01-01..1998-12-31 | account 1993-01-01..1997-12-29 | loan 1993-07-05..1998-12-08
--   card 1993-11-07..1998-12-29  | client birth 1911-08-20..1987-09-27
SELECT 'trans' AS tbl, MIN(trans_date) AS first_date, MAX(trans_date) AS last_date FROM staging.trans
UNION ALL SELECT 'account', MIN(opened_date), MAX(opened_date) FROM staging.account
UNION ALL SELECT 'loan',    MIN(loan_date),   MAX(loan_date)   FROM staging.loan
UNION ALL SELECT 'card',    MIN(issued_date), MAX(issued_date) FROM staging.card
UNION ALL SELECT 'client birth', MIN(birth_date), MAX(birth_date) FROM staging.client;


-- V4. Gender decoded from birth_number. Expected: M 2,724 | F 2,645
SELECT gender, COUNT(*) AS clients FROM staging.client GROUP BY gender ORDER BY gender DESC;


-- V5. District placeholders turned into NULL. Expected: exactly 1 row, Jesenik
SELECT district_name, unemployment_rate_95, crimes_95
FROM staging.district
WHERE unemployment_rate_95 IS NULL OR crimes_95 IS NULL;


-- V6. Money by direction. Expected: credit 405,083 txns / 3,227,472,424.50 | debit 651,237 txns / 3,030,321,135.80
SELECT direction, COUNT(*) AS txns, SUM(amount) AS total_amount
FROM staging.trans
GROUP BY direction
ORDER BY direction;

-- V6b. Net flow of the whole bank. Expected: 197,151,288.70
SELECT SUM(signed_amount) AS net_flow FROM staging.trans;


-- V7. Transaction categories. Expected:
--   cash_withdrawal 274,675 | interest_credit 183,114 | cash_deposit 156,743 | statement_fee 155,832
--   household_payment 118,065 | transfer_out 60,972 | transfer_in 34,888 | pension_credit 30,338
--   insurance_payment 18,500 | loan_payment 13,580 | card_withdrawal 8,036 | penalty_interest 1,577
SELECT txn_category, COUNT(*) AS txns
FROM staging.trans
GROUP BY txn_category
ORDER BY txns DESC;

-- V7b. Bank-generated postings (interest, penalty interest, statement fees). Expected: 340,523
SELECT COUNT(*) AS bank_generated FROM staging.trans WHERE is_bank_generated;


-- V8. The lesson behind the category rule: what does operation 'VYBER' (cash withdrawal) really contain?
-- Expected: none 274,675 | SLUZBY 155,832 | SIPO 2,811 | SANKC. UROK 1,577 | POJISTNE 23
-- More than a third of "cash withdrawals" are statement fees. Counting operation alone would be wrong.
SELECT operation_code, k_symbol_code, COUNT(*) AS txns
FROM staging.trans
WHERE operation_code = 'VYBER'
GROUP BY operation_code, k_symbol_code
ORDER BY txns DESC;


-- V9. Is the sign convention right? Test on rows with NO ordering ambiguity: the account has exactly one
-- transaction that day AND on its previous active day. There, balance_after must equal previous balance + signed amount.
-- Expected: PRIJEM 137,349 rows ~96.97% | VYBER 9,597 rows 100.00% | VYDAJ 259,995 rows ~99.56%
-- (VYBER = 100% is the proof that type VYBER is a debit. The ~3% PRIJEM gap is unexplained - a good thing to investigate.)
-- This scans 1 million rows with window functions: allow it a few seconds.
WITH day_counts AS (
    SELECT t.*, COUNT(*) OVER (PARTITION BY account_id, trans_date) AS n_day
    FROM staging.trans t
), chained AS (
    SELECT d.*,
           LAG(balance_after) OVER w AS prev_balance,
           LAG(n_day)         OVER w AS prev_n_day
    FROM day_counts d
    WINDOW w AS (PARTITION BY account_id ORDER BY trans_date, trans_id)
)
SELECT type_code,
       COUNT(*) AS rows_tested,
       ROUND(100.0 * COUNT(*) FILTER (WHERE prev_balance + signed_amount = balance_after) / COUNT(*), 2) AS pct_reconciled
FROM chained
WHERE n_day = 1 AND prev_n_day = 1
GROUP BY type_code
ORDER BY type_code;


-- V10. Know your limits: transactions have a DATE but no time of day, so order within a day is unknown.
-- Expected: 43.7 (% of transactions that share their day with another transaction of the same account)
SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE n_day > 1) / COUNT(*), 1) AS pct_rows_on_busy_days
FROM (
    SELECT COUNT(*) OVER (PARTITION BY account_id, trans_date) AS n_day
    FROM staging.trans
) x;

-- 07_validate_analytics.sql
-- Run AFTER 06_create_analytics.sql. One query at a time (Ctrl+Enter).
-- Every "Expected" value was computed independently from the source files.

-- W1. Row counts. Expected: dim_date 2,191 | dim_district 77 | dim_account 4,500 | dim_txn_category 12
--                           | fact_transactions 1,056,320 | fact_loans 682
SELECT 'dim_date' AS table_name, COUNT(*) AS n FROM analytics.dim_date
UNION ALL SELECT 'dim_district',     COUNT(*) FROM analytics.dim_district
UNION ALL SELECT 'dim_account',      COUNT(*) FROM analytics.dim_account
UNION ALL SELECT 'dim_txn_category', COUNT(*) FROM analytics.dim_txn_category
UNION ALL SELECT 'fact_transactions', COUNT(*) FROM analytics.fact_transactions
UNION ALL SELECT 'fact_loans',       COUNT(*) FROM analytics.fact_loans;


-- W2. No "fan-out": joining accounts to their owner must not create duplicates. Expected: 4,500 and 4,500
SELECT COUNT(*) AS rows, COUNT(DISTINCT account_id) AS distinct_accounts FROM analytics.dim_account;


-- W3. Owners. Expected: M 2,292 | F 2,208, and owner age at account opening from 10 to 79
SELECT owner_gender, COUNT(*) AS accounts FROM analytics.dim_account GROUP BY owner_gender ORDER BY owner_gender DESC;
SELECT MIN(owner_age_at_opening) AS youngest, MAX(owner_age_at_opening) AS oldest FROM analytics.dim_account;


-- W4. Cards and loans. Expected: total cards 892 | accounts with a card 892 | accounts with a loan 682
SELECT SUM(card_count) AS total_cards,
       COUNT(*) FILTER (WHERE has_card) AS accounts_with_card,
       COUNT(*) FILTER (WHERE has_loan) AS accounts_with_loan
FROM analytics.dim_account;


-- W5. The star must carry exactly what staging carried. Expected: rows equal, totals equal, net flow 197,151,288.70
SELECT f.n AS fact_rows, s.n AS staging_rows,
       f.net AS fact_net_flow, s.net AS staging_net_flow,
       (f.n = s.n AND f.net = s.net) AS matches
FROM (SELECT COUNT(*) AS n, SUM(signed_amount) AS net FROM analytics.fact_transactions) f,
     (SELECT COUNT(*) AS n, SUM(signed_amount) AS net FROM staging.trans) s;


-- W6. Category flags agree between staging and the dimension. Expected: 0
SELECT COUNT(*) AS mismatches
FROM staging.trans t
JOIN analytics.dim_txn_category c ON c.txn_category = t.txn_category
WHERE t.is_bank_generated <> c.is_bank_generated;


-- W7. THE STAR PAYS OFF: monthly credits and debits for 1998 through dim_date. This must reproduce Q6 from
-- 03_initial_exploration.sql without any date arithmetic. Expected (txns / credit / debit):
--   Jan 42,940 / 79,269,558.30 / 112,812,799.90      Feb 23,995 / 74,628,756.00 / 54,120,571.00
--   Mar 25,341 / 77,311,535.80 /  70,876,874.90      Jun 27,833 / 98,321,360.50 / 111,580,666.00
--   Dec 23,553 / 95,155,975.90 /  76,541,117.80
-- Notice January (many transactions), and June and December (credits jump ~20M). Those are puzzles to explain.
SELECT d.month, d.month_name,
       COUNT(*) AS txns,
       SUM(f.amount) FILTER (WHERE f.direction = 'credit') AS credit,
       SUM(f.amount) FILTER (WHERE f.direction = 'debit')  AS debit
FROM analytics.fact_transactions f
JOIN analytics.dim_date d ON d.date_key = f.date_key
WHERE d.year = 1998
GROUP BY d.month, d.month_name
ORDER BY d.month;


-- W8. A three-dimension question: 1998 net flow by region. Expected (txns / net flow):
--   south Moravia 55,571 / 4,506,485.90 | north Moravia 57,219 / 4,467,785.80 | east Bohemia 37,697 / 3,590,384.30
--   Prague 40,178 / 3,525,059.60 | central Bohemia 41,733 / 3,464,066.00 | north Bohemia 32,798 / 2,923,410.40
--   west Bohemia 30,774 / 2,654,297.60 | south Bohemia 26,307 / 2,013,717.50
SELECT dd.region, COUNT(*) AS txns, SUM(f.signed_amount) AS net_flow
FROM analytics.fact_transactions f
JOIN analytics.dim_account  a  ON a.account_id  = f.account_id
JOIN analytics.dim_district dd ON dd.district_id = a.district_id
JOIN analytics.dim_date     d  ON d.date_key    = f.date_key
WHERE d.year = 1998
GROUP BY dd.region
ORDER BY net_flow DESC;

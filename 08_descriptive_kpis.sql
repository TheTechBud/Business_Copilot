-- 08_descriptive_kpis.sql
-- Phase 4 (start): descriptive KPIs on the analytics star schema. Read-only. Run AFTER 06/07 passed.
-- One query at a time (Ctrl+Enter). "Expected" values were computed independently from the source files.
-- Definitions of every KPI are in docs/business_questions_and_kpis.md. Read them first.
--
-- "Customer-initiated" below means: NOT is_bank_generated (excludes interest, penalty interest, statement fees).
-- Bank postings happen to every account whether or not the customer does anything, so they say nothing about activity.


-- K1. Yearly activity   (answers D1 and G1)
-- Expected (year | accounts open at year end | active accounts | customer txns | txns per active account):
--   1993 | 1,139 | 1,139 | 19,209  | 16.9
--   1994 | 1,578 | 1,578 | 61,794  | 39.2
--   1995 | 2,239 | 2,239 | 90,155  | 40.3
--   1996 | 3,602 | 3,602 | 133,052 | 36.9
--   1997 | 4,500 | 4,496 | 192,063 | 42.7
--   1998 | 4,500 | 4,492 | 219,524 | 48.9
-- Caution: accounts opened mid-year only have part of a year, which pulls the per-account figure down.
SELECT d.year,
       (SELECT COUNT(*) FROM analytics.dim_account a
        WHERE a.opened_date <= make_date(d.year, 12, 31))             AS accounts_open_at_year_end,
       COUNT(DISTINCT f.account_id)                                   AS active_accounts,
       COUNT(*)                                                       AS customer_txns,
       ROUND(COUNT(*)::NUMERIC / COUNT(DISTINCT f.account_id), 1)     AS txns_per_active_account
FROM analytics.fact_transactions f
JOIN analytics.dim_date         d ON d.date_key     = f.date_key
JOIN analytics.dim_txn_category c ON c.txn_category = f.txn_category
WHERE NOT c.is_bank_generated
GROUP BY d.year
ORDER BY d.year;


-- K2. What do customers do?  By COUNT versus by VALUE   (answers D2)
-- Expected (category | % of txns | % of value):
--   cash_deposit 14.8 / 38.6 | cash_withdrawal 26.0 / 37.0 | transfer_in 3.3 / 9.8 | household_payment 11.2 / 8.0
--   pension_credit 2.9 / 2.7 | transfer_out 5.8 / 1.9 | loan_payment 1.3 / 0.9 | interest_credit 17.3 / 0.4
--   insurance_payment 1.8 / 0.4 | card_withdrawal 0.8 / 0.3 | statement_fee 14.8 / 0.0 | penalty_interest 0.1 / 0.0
-- Think: statement fees are 14.8% of all transactions but almost none of the money. Which one is "activity"?
SELECT f.txn_category,
       COUNT(*)                                                       AS txns,
       SUM(f.amount)                                                  AS total_amount,
       ROUND(100.0 * COUNT(*)      / SUM(COUNT(*))      OVER (), 1)   AS pct_of_txns,
       ROUND(100.0 * SUM(f.amount) / SUM(SUM(f.amount)) OVER (), 1)   AS pct_of_value
FROM analytics.fact_transactions f
GROUP BY f.txn_category
ORDER BY total_amount DESC;


-- K3. Regions: activity and net flow per account (customer-initiated only)   (answers D3)
-- Expected (region | accounts | txns per account | net flow per account):
--   north Moravia 793 | 163.5 | 38,389.5     south Moravia 778 | 158.3 | 38,277.0
--   central Bohemia 574 | 159.3 | 38,394.5   Prague 554 | 162.3 | 39,263.9
--   east Bohemia 544 | 150.4 | 38,193.7      north Bohemia 457 | 159.7 | 38,688.8
--   west Bohemia 430 | 160.5 | 38,206.2      south Bohemia 370 | 156.4 | 36,499.5
-- Notice how SIMILAR the regions are. Absence of a difference is also a finding.
WITH per_account AS (
    SELECT f.account_id, COUNT(*) AS txns, SUM(f.signed_amount) AS net_flow
    FROM analytics.fact_transactions f
    JOIN analytics.dim_txn_category c ON c.txn_category = f.txn_category
    WHERE NOT c.is_bank_generated
    GROUP BY f.account_id
)
SELECT dd.region,
       COUNT(*)                                AS accounts,
       ROUND(AVG(COALESCE(p.txns, 0)), 1)      AS txns_per_account,
       ROUND(AVG(COALESCE(p.net_flow, 0)), 1)  AS net_flow_per_account
FROM analytics.dim_account a
JOIN analytics.dim_district dd ON dd.district_id = a.district_id
LEFT JOIN per_account p        ON p.account_id   = a.account_id
GROUP BY dd.region
ORDER BY accounts DESC;


-- K4. Fee income, our revenue PROXY   (answers D1)
-- Berka has no revenue column. The only income we can see is fees; interest credited is a cost to the bank.
-- Expected (year | statement fees | penalty interest | interest paid to customers):
--   1993 |  49,921.60 |     75.00 |   810,862.90      1994 | 232,651.60 |    696.70 | 2,293,651.90
--   1995 | 343,631.80 |  1,120.80 | 3,298,008.60      1996 | 500,804.80 |  1,821.60 | 5,010,410.20
--   1997 | 743,714.00 |  6,823.20 | 7,372,897.70      1998 | 815,694.40 | 27,126.00 | 8,684,858.20
-- Penalty interest grows about 4x in 1998 while the number of accounts is flat. See "Your turn" task 3.
SELECT d.year,
       SUM(f.amount) FILTER (WHERE f.txn_category = 'statement_fee')    AS statement_fees,
       SUM(f.amount) FILTER (WHERE f.txn_category = 'penalty_interest') AS penalty_interest,
       SUM(f.amount) FILTER (WHERE f.txn_category = 'interest_credit')  AS interest_paid_to_customers
FROM analytics.fact_transactions f
JOIN analytics.dim_date d ON d.date_key = f.date_key
GROUP BY d.year
ORDER BY d.year;


-- K5. Loan book by year of issue   (answers D4)
-- Expected (year | loans | total issued | average):
--   1993 | 20 |  2,619,276 | 130,964     1994 | 101 | 13,379,904 | 132,474     1995 |  90 | 13,344,372 | 148,271
--   1996 | 117 | 18,317,676 | 156,561     1997 | 196 | 30,731,364 | 156,793     1998 | 158 | 24,869,148 | 157,400
SELECT d.year,
       COUNT(*)                     AS loans,
       SUM(l.loan_amount)           AS total_issued,
       ROUND(AVG(l.loan_amount), 0) AS avg_loan
FROM analytics.fact_loans l
JOIN analytics.dim_date d ON d.date_key = l.date_key
GROUP BY d.year
ORDER BY d.year;


-- K6. Loan amount in trouble by region   (feeds R1)
-- "In trouble" = status B (finished, not paid) or D (running, client in debt). Amounts are ORIGINAL loan amounts,
-- not what is still owed. Loans with status C may still go bad later: the data ends in 1998.
-- Expected (region | loans | total | in trouble | %):
--   south Moravia 129 | 19,678,848 | 2,822,976 | 14.3     north Moravia 117 | 18,081,312 | 3,871,092 | 21.4
--   central Bohemia 90 | 13,985,304 | 2,013,000 | 14.4    east Bohemia 84 | 13,943,724 | 1,670,004 | 12.0
--   Prague 84 | 12,932,412 | 2,027,136 | 15.7             south Bohemia 60 | 9,374,136 | 1,589,544 | 17.0
--   west Bohemia 57 | 7,779,384 | 1,411,656 | 18.1         north Bohemia 61 | 7,486,620 | 174,744 | 2.3
--   TOTAL: 103,261,740 issued, 15,580,152 in trouble (15.1%)
-- Same warning as Q9: north Bohemia is 1 bad loan out of 61. Small numbers swing percentages.
SELECT dd.region,
       COUNT(*)           AS loans,
       SUM(l.loan_amount) AS total_amount,
       SUM(l.loan_amount) FILTER (WHERE l.status_code IN ('B', 'D')) AS amount_in_trouble,
       ROUND(100.0 * SUM(l.loan_amount) FILTER (WHERE l.status_code IN ('B', 'D')) / SUM(l.loan_amount), 1) AS pct_in_trouble
FROM analytics.fact_loans l
JOIN analytics.dim_account  a  ON a.account_id   = l.account_id
JOIN analytics.dim_district dd ON dd.district_id = a.district_id
GROUP BY dd.region
ORDER BY total_amount DESC;


-- ============================== YOUR TURN ==============================
-- 1. G1: K1 shows customer transactions grew every year. Split the 1996 -> 1997 increase into
--    (a) more active accounts and (b) more transactions per active account.
--    Identity: new_total - old_total = (A1 - A0) * t0  +  A1 * (t1 - t0)   where A = active accounts, t = txns per account.
--    Which part is bigger, and what does that tell the bank?
-- 2. G2: explain January 1998 (volume) and June / December 1998 (credits). Start from
--    analytics.fact_transactions + dim_date + dim_txn_category. Report fact vs interpretation separately.
-- 3. Why does penalty interest jump ~4x in 1998 (K4)? Hint: penalty interest is charged on negative balances.
--    Count accounts with balance_after < 0 per year and see whether that explains it.
-- 4. Open the ~3% of PRIJEM transactions that did NOT reconcile in V9 of 05_validate_staging.sql. What do they have in common?

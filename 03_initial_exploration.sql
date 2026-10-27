-- 03_initial_exploration.sql
-- Phase 2b: first look at the raw Berka data with SQL. Read-only (SELECT only) - nothing here changes data.
-- Run ONE query at a time in DBeaver: click inside it and press Ctrl+Enter.
-- "Expected" values were computed independently from the source files - compare them with your results.
--
-- Dates in raw tables are integers like 980131 (YYMMDD, all years are 19xx here).
-- Decoding trick used below:  make_date(1900 + date/10000, date/100 % 100, date % 100)
--   date/10000  -> integer division drops the decimals: 980131 / 10000 = 98
--   date/100 % 100 -> (980131 / 100) % 100 = 9801 % 100 = 01   (month)
--   date % 100  -> 980131 % 100 = 31                              (day)
-- Why not to_date(..., 'YYMMDD')? It guesses the century. make_date makes the century explicit.


-- Q1. Date range of transactions (teaches: MIN/MAX, decoding dates)
-- Expected: 1993-01-01  to  1998-12-31
SELECT MIN(make_date(1900 + date/10000, date/100 % 100, date % 100)) AS first_txn,
       MAX(make_date(1900 + date/10000, date/100 % 100, date % 100)) AS last_txn
FROM raw.trans;


-- Q2. Transactions per year (teaches: GROUP BY an expression)
-- Expected: 1993 28,205 | 1994 91,628 | 1995 133,022 | 1996 196,779 | 1997 284,409 | 1998 322,277
-- Think: why does volume grow every year? (Accounts keep opening - see Q2b.)
SELECT 1900 + date/10000 AS year, COUNT(*) AS transactions
FROM raw.trans
GROUP BY 1
ORDER BY 1;

-- Q2b. Accounts opened per year (teaches: the same pattern on another table)
SELECT 1900 + date/10000 AS year, COUNT(*) AS accounts_opened
FROM raw.account
GROUP BY 1
ORDER BY 1;


-- Q3a. Transactions by type (teaches: COUNT + GROUP BY on a text column)
-- Expected: VYDAJ 634,571 | PRIJEM 405,083 | VYBER 16,666      (VYDAJ = debit, PRIJEM = credit)
SELECT type, COUNT(*) AS n
FROM raw.trans
GROUP BY type
ORDER BY n DESC;

-- Q3b. Transactions by operation (teaches: NULL is its own group)
-- Expected: VYBER 434,918 | PREVOD NA UCET 208,283 | NULL 183,114 | VKLAD 156,743
--           | PREVOD Z UCTU 65,226 | VYBER KARTOU 8,036
SELECT operation, COUNT(*) AS n
FROM raw.trans
GROUP BY operation
ORDER BY n DESC;


-- Q4. Accounts per region (teaches: JOIN, and why the key is called a1 in district)
-- Expected: north Moravia 793 | south Moravia 778 | central Bohemia 574 | Prague 554
--           | east Bohemia 544 | north Bohemia 457 | west Bohemia 430 | south Bohemia 370   (total 4,500)
SELECT d.a3 AS region, COUNT(*) AS accounts
FROM raw.account a
JOIN raw.district d ON d.a1 = a.district_id
GROUP BY d.a3
ORDER BY accounts DESC;


-- Q5. Loans by status (teaches: several aggregates at once)
-- Status meaning (from the challenge docs): A finished OK | B finished, not paid | C running OK | D running, in debt
-- Expected: A 203 (avg 91,641.46) | B 31 (140,720.90) | C 403 (171,410.35) | D 45 (249,284.53)
-- Hypothesis to TEST later (not a conclusion): within A-vs-B and C-vs-D, the bad status has larger average loans.
SELECT status,
       COUNT(*)              AS loans,
       ROUND(AVG(amount), 2) AS avg_amount,
       SUM(amount)           AS total_amount
FROM raw.loan
GROUP BY status
ORDER BY status;


-- Q6. 1998 monthly credits vs debits (teaches: FILTER inside aggregates)
-- Debit here = types VYDAJ and VYBER (my balance check supports treating VYBER as a debit).
-- Expected: Jan 42,940 txns | Feb 23,995 | Mar 25,341 | ... | Dec 23,553
--           Jan credit 79,269,558.30, debit 112,812,799.90
-- Look at January. That is not normal. See "Your turn" task 1.
SELECT date/100 % 100 AS month,
       COUNT(*) AS txns,
       SUM(amount) FILTER (WHERE type = 'PRIJEM')            AS credit,
       SUM(amount) FILTER (WHERE type IN ('VYDAJ', 'VYBER')) AS debit
FROM raw.trans
WHERE date BETWEEN 980101 AND 981231
GROUP BY 1
ORDER BY 1;


-- Q7. Top 5 accounts by LATEST balance (teaches: CTE + window function ROW_NUMBER)
-- "Latest" = most recent date, ties broken by the highest trans_id.
-- CAUTION (found later): trans_id does NOT follow time order, and there is no time-of-day column, so order within
-- a day is unknown. 183 accounts have 2+ transactions on their last day; where the true closing balance can be worked
-- out (141 accounts), this tie-break picks it only about half the time (76 of 141). Accounts 8856 and 8132 below are
-- affected. Treat Q7 as a lesson in window functions, not as a reliable ranking. Phase 3 fixes this properly.
-- Expected: account 8856 (138,317.20) | 3255 (127,380.10) | 2245 (125,279.80) | 2599 (124,641.30) | 8132 (124,602.80)
WITH ranked AS (
    SELECT account_id, date, trans_id, balance,
           ROW_NUMBER() OVER (PARTITION BY account_id ORDER BY date DESC, trans_id DESC) AS rn
    FROM raw.trans
)
SELECT account_id, date, trans_id, balance
FROM ranked
WHERE rn = 1
ORDER BY balance DESC
LIMIT 5;


-- Q8. Who holds accounts? (teaches: the bridge table disp)
-- Expected: OWNER 4,500 | DISPONENT 869
SELECT type, COUNT(*) AS n
FROM raw.disp
GROUP BY type;


-- Q9. Loan outcome by region (teaches: JOINing three tables, percentages, small-sample caution)
-- Expected loans / bad(B or D) / bad %:
--   south Moravia 129/13/10.1 | north Moravia 117/18/15.4 | central Bohemia 90/10/11.1 | Prague 84/7/8.3
--   east Bohemia 84/9/10.7 | north Bohemia 61/1/1.6 | south Bohemia 60/9/15.0 | west Bohemia 57/9/15.8   (682 / 76 total)
-- Caution: north Bohemia has 1 bad loan out of 61. With numbers this small, regional differences may be noise.
-- Deciding that properly is what the statistics phase (confidence intervals) is for.
SELECT d.a3 AS region,
       COUNT(*) AS loans,
       COUNT(*) FILTER (WHERE l.status IN ('B', 'D')) AS bad_loans,
       ROUND(100.0 * COUNT(*) FILTER (WHERE l.status IN ('B', 'D')) / COUNT(*), 1) AS bad_pct
FROM raw.loan l
JOIN raw.account  a ON a.account_id = l.account_id
JOIN raw.district d ON d.a1 = a.district_id
GROUP BY d.a3
ORDER BY loans DESC, region;


-- ======================= YOUR TURN (write these yourself; ChatGPT may help with syntax) =======================
-- 1. January 1998 has ~43k transactions; other months have ~24-28k. Find out WHY.
--    Hint: break January down by day, then by operation, and compare with February. I checked: there is a clear
--    answer in the data. Tell me what you find, and whether you think it is real behaviour or a data artifact.
-- 2. type = 'VYBER' appears on 16,666 rows. Which operation values does it carry? Compare with type = 'VYDAJ'.
-- 3. For every account: first transaction date, last transaction date and number of transactions.
--    Which 5 accounts have the most transactions?
-- 4. Prove that every account has exactly ONE owner in raw.disp (GROUP BY account_id ... HAVING).
--    Expected: zero accounts that violate it.

-- Q1. Date range of transactions (teaches: MIN/MAX, decoding dates)
SELECT MIN(make_date(1900 + date/10000, date/100 % 100, date % 100)) AS first_txn,
       MAX(make_date(1900 + date/10000, date/100 % 100, date % 100)) AS last_txn
FROM raw.trans;


-- Q2. Transactions per year (teaches: GROUP BY an expression)
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
SELECT type, COUNT(*) AS n
FROM raw.trans
GROUP BY type
ORDER BY n DESC;

-- Q3b. Transactions by operation (teaches: NULL is its own group)
SELECT operation, COUNT(*) AS n
FROM raw.trans
GROUP BY operation
ORDER BY n DESC;


-- Q4. Accounts per region (teaches: JOIN, and why the key is called a1 in district)
SELECT d.a3 AS region, COUNT(*) AS accounts
FROM raw.account a
JOIN raw.district d ON d.a1 = a.district_id
GROUP BY d.a3
ORDER BY accounts DESC;


-- Q5. Loans by status (teaches: several aggregates at once)
SELECT status,
       COUNT(*)              AS loans,
       ROUND(AVG(amount), 2) AS avg_amount,
       SUM(amount)           AS total_amount
FROM raw.loan
GROUP BY status
ORDER BY status;


-- Q6. 1998 monthly credits vs debits (teaches: FILTER inside aggregates)

SELECT date/100 % 100 AS month,
       COUNT(*) AS txns,
       SUM(amount) FILTER (WHERE type = 'PRIJEM')            AS credit,
       SUM(amount) FILTER (WHERE type IN ('VYDAJ', 'VYBER')) AS debit
FROM raw.trans
WHERE date BETWEEN 980101 AND 981231
GROUP BY 1
ORDER BY 1;


-- Q7. Top 5 accounts by LATEST balance (teaches: CTE + window function ROW_NUMBER)

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

SELECT type, COUNT(*) AS n
FROM raw.disp
GROUP BY type;


-- Q9. Loan outcome by region (teaches: JOINing three tables, percentages, small-sample caution)

SELECT d.a3 AS region,
       COUNT(*) AS loans,
       COUNT(*) FILTER (WHERE l.status IN ('B', 'D')) AS bad_loans,
       ROUND(100.0 * COUNT(*) FILTER (WHERE l.status IN ('B', 'D')) / COUNT(*), 1) AS bad_pct
FROM raw.loan l
JOIN raw.account  a ON a.account_id = l.account_id
JOIN raw.district d ON d.a1 = a.district_id
GROUP BY d.a3
ORDER BY loans DESC, region;
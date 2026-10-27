-- 04_create_staging.sql
-- Phase 3: the STAGING layer = raw data made usable. Raw stays untouched; everything here is derived from it.
-- Run the WHOLE file in DBeaver with Alt+X (Execute Script). Then check it with 05_validate_staging.sql.
--
-- Rules of this layer
--   1. Real data types: integer dates -> DATE, text numbers -> NUMERIC/INTEGER.
--   2. Readable names and English labels, but the ORIGINAL code is kept next to every label.
--   3. Unknown codes become NULL (never silently guessed); 05_validate_staging.sql counts them (expected 0).
--   4. No business labels (e.g. "bad loan") here. Those need leakage-safe rules and belong to the ML phase.
--   5. Rebuildable: this script can be re-run any time. It only ever drops the staging schema, never raw.
--
-- Why TABLES and not VIEWS? Raw never changes, so we compute once and index it. A view would redo the
-- conversion on 1 million rows every time someone queries it.

DROP SCHEMA IF EXISTS staging CASCADE;   -- derived layer only: safe to rebuild, raw is not touched
CREATE SCHEMA staging;

-- A reusable function: 980131 -> 1998-01-31. One definition = one place to fix if the rule ever changes.
CREATE FUNCTION staging.yymmdd_to_date(d INTEGER) RETURNS DATE
LANGUAGE sql IMMUTABLE
AS $$ SELECT make_date(1900 + d / 10000, d / 100 % 100, d % 100) $$;


-- 1. district: meaningful column names (from the challenge documentation); '?' becomes NULL.
CREATE TABLE staging.district AS
SELECT a.a1                               AS district_id,
       a.a2                               AS district_name,
       a.a3                               AS region,
       a.a4::INTEGER                      AS inhabitants,
       a.a5::INTEGER                      AS municipalities_lt_500,
       a.a6::INTEGER                      AS municipalities_500_1999,
       a.a7::INTEGER                      AS municipalities_2000_9999,
       a.a8::INTEGER                      AS municipalities_gt_10000,
       a.a9::INTEGER                      AS cities,
       a.a10::NUMERIC(5, 1)               AS urban_inhabitants_pct,
       a.a11::INTEGER                     AS avg_salary,
       NULLIF(a.a12, '?')::NUMERIC(4, 2)  AS unemployment_rate_95,
       a.a13::NUMERIC(4, 2)               AS unemployment_rate_96,
       a.a14::INTEGER                     AS entrepreneurs_per_1000,
       NULLIF(a.a15, '?')::INTEGER        AS crimes_95,
       a.a16::INTEGER                     AS crimes_96
FROM raw.district a;
ALTER TABLE staging.district ADD PRIMARY KEY (district_id);


-- 2. account: real opened date, readable statement frequency.
CREATE TABLE staging.account AS
SELECT a.account_id,
       a.district_id,
       a.frequency                    AS frequency_code,
       CASE a.frequency
            WHEN 'POPLATEK MESICNE'   THEN 'monthly'
            WHEN 'POPLATEK TYDNE'     THEN 'weekly'
            WHEN 'POPLATEK PO OBRATU' THEN 'after_transaction'
       END                            AS statement_frequency,
       staging.yymmdd_to_date(a.date) AS opened_date
FROM raw.account a;
ALTER TABLE staging.account ADD PRIMARY KEY (account_id);


-- 3. client: birth_number is YYMMDD for men and YYMM+50DD for women, so month > 50 means female.
CREATE TABLE staging.client AS
WITH parsed AS (
    SELECT c.client_id,
           c.district_id,
           substr(c.birth_number, 1, 2)::INTEGER AS yy,
           substr(c.birth_number, 3, 2)::INTEGER AS mm_raw,
           substr(c.birth_number, 5, 2)::INTEGER AS dd
    FROM raw.client c
)
SELECT client_id,
       district_id,
       CASE WHEN mm_raw > 50 THEN 'F' ELSE 'M' END AS gender,
       make_date(1900 + yy, CASE WHEN mm_raw > 50 THEN mm_raw - 50 ELSE mm_raw END, dd) AS birth_date
FROM parsed;
ALTER TABLE staging.client ADD PRIMARY KEY (client_id);


-- 4. disp: links clients to accounts. Only an OWNER can order payments or ask for a loan.
CREATE TABLE staging.disp AS
SELECT d.disp_id, d.client_id, d.account_id, d.type AS disposition_type
FROM raw.disp d;
ALTER TABLE staging.disp ADD PRIMARY KEY (disp_id);


-- 5. card: issued is text like '931107 00:00:00' - keep the first six characters.
CREATE TABLE staging.card AS
SELECT c.card_id,
       c.disp_id,
       c.type AS card_type,
       staging.yymmdd_to_date(substr(c.issued, 1, 6)::INTEGER) AS issued_date
FROM raw.card c;
ALTER TABLE staging.card ADD PRIMARY KEY (card_id);


-- 6. loan: status decoded. NOTE: no good/bad label here on purpose (see rule 4).
CREATE TABLE staging.loan AS
SELECT l.loan_id,
       l.account_id,
       staging.yymmdd_to_date(l.date) AS loan_date,
       l.amount                       AS loan_amount,
       l.duration                     AS duration_months,
       l.payments                     AS monthly_payment,
       l.status                       AS status_code,
       CASE l.status
            WHEN 'A' THEN 'finished_ok'
            WHEN 'B' THEN 'finished_not_paid'
            WHEN 'C' THEN 'running_ok'
            WHEN 'D' THEN 'running_in_debt'
       END                            AS status_desc,
       (l.status IN ('A', 'B'))       AS is_finished
FROM raw.loan l;
ALTER TABLE staging.loan ADD PRIMARY KEY (loan_id);


-- 7. standing_order (raw name: "order", a SQL keyword, so we avoid it here). Blank k_symbol -> 'none'.
CREATE TABLE staging.standing_order AS
SELECT o.order_id,
       o.account_id,
       o.bank_to,
       o.account_to,
       o.amount,
       COALESCE(NULLIF(TRIM(o.k_symbol), ''), 'none') AS k_symbol_code
FROM raw."order" o;
ALTER TABLE staging.standing_order ADD PRIMARY KEY (order_id);


-- 8. trans: the big one.
--   direction / signed_amount : credit = +, debit = -. Type 'VYBER' (undocumented, 16,666 rows) is treated as a
--                               debit; checked against the running balance (see 05_validate_staging.sql).
--   k_symbol_code             : NULL and a lone space both become 'none' (the space only ever appears on debits and
--                               carries no extra meaning we can see).
--   txn_category              : my own grouping. k_symbol is checked FIRST because `operation` misleads:
--                               155,832 statement fees are recorded with operation 'VYBER' (cash withdrawal).
--   is_bank_generated         : interest, penalty interest and statement fees are posted by the bank, not by the
--                               customer. Customer-activity analysis (and any churn/decline label) must exclude them.
CREATE TABLE staging.trans AS
WITH base AS (
    SELECT t.*,
           COALESCE(NULLIF(TRIM(t.k_symbol), ''), 'none') AS k_symbol_code
    FROM raw.trans t
)
SELECT b.trans_id,
       b.account_id,
       staging.yymmdd_to_date(b.date) AS trans_date,
       b.type                         AS type_code,
       CASE b.type
            WHEN 'PRIJEM' THEN 'credit'
            WHEN 'VYDAJ'  THEN 'debit'
            WHEN 'VYBER'  THEN 'debit'
       END                            AS direction,
       b.amount,
       CASE b.type
            WHEN 'PRIJEM' THEN  b.amount
            WHEN 'VYDAJ'  THEN -b.amount
            WHEN 'VYBER'  THEN -b.amount
       END                            AS signed_amount,
       b.balance                      AS balance_after,
       b.operation                    AS operation_code,
       b.k_symbol_code,
       CASE
            WHEN b.k_symbol_code = 'UROK'        THEN 'interest_credit'
            WHEN b.k_symbol_code = 'SANKC. UROK' THEN 'penalty_interest'
            WHEN b.k_symbol_code = 'SLUZBY'      THEN 'statement_fee'
            WHEN b.k_symbol_code = 'POJISTNE'    THEN 'insurance_payment'
            WHEN b.k_symbol_code = 'SIPO'        THEN 'household_payment'
            WHEN b.k_symbol_code = 'DUCHOD'      THEN 'pension_credit'
            WHEN b.k_symbol_code = 'UVER'        THEN 'loan_payment'
            WHEN b.operation = 'VKLAD'           THEN 'cash_deposit'
            WHEN b.operation = 'VYBER'           THEN 'cash_withdrawal'
            WHEN b.operation = 'VYBER KARTOU'    THEN 'card_withdrawal'
            WHEN b.operation = 'PREVOD Z UCTU'   THEN 'transfer_in'
            WHEN b.operation = 'PREVOD NA UCET'  THEN 'transfer_out'
       END                            AS txn_category,
       (b.k_symbol_code IN ('UROK', 'SANKC. UROK', 'SLUZBY')) AS is_bank_generated,
       b.bank                         AS partner_bank,
       b.account                      AS partner_account
FROM base b;

ALTER TABLE staging.trans ADD PRIMARY KEY (trans_id);
-- Indexes: without them, "all transactions of account X" scans 1 million rows every time.
CREATE INDEX ix_trans_account_date ON staging.trans (account_id, trans_date);
CREATE INDEX ix_trans_date         ON staging.trans (trans_date);

ANALYZE;   -- refresh the planner's statistics so the new indexes get used

-- 06_create_analytics.sql
-- Phase 3 (finish): the ANALYTICS layer = a star schema for reporting (Power BI, SQL analysis, the later API).
-- Run the WHOLE file in DBeaver with Alt+X, AFTER 04_create_staging.sql has been run and checked.
-- Then check it with 07_validate_analytics.sql.
--
-- Star schema in one paragraph: FACTS are the events you count and sum (one row per transaction, one row per loan).
-- DIMENSIONS are the things you slice by (date, account, district, transaction category). A fact row points to its
-- dimension rows through keys. "Revenue by region by month" becomes: join the fact to the dimensions and GROUP BY.
--
-- Design decisions (be ready to explain these in an interview)
--   * Grain first: fact_transactions = ONE ROW PER TRANSACTION; fact_loans = ONE ROW PER LOAN.
--   * "Customer" = the ACCOUNT. Every account has exactly one OWNER, so we flatten the owner into dim_account.
--     That avoids the many-to-many client<->account link inside the star. Disponents (extra users) are left out for now.
--   * Natural keys (account_id, district_id) are kept as keys: they are small, stable integers from the source.
--     (A bigger warehouse would add surrogate keys, mainly to track history.)
--   * dim_date is generated, not loaded: it makes "by month / quarter / weekday" a simple join.
--   * Rebuildable: this script only drops the analytics schema; raw and staging are untouched.

DROP SCHEMA IF EXISTS analytics CASCADE;
CREATE SCHEMA analytics;


-- ---------------------------------------------------------------- dim_date
CREATE TABLE analytics.dim_date (
    date_key      INTEGER PRIMARY KEY,        -- 19980131 style: sortable, readable
    full_date     DATE     NOT NULL UNIQUE,
    year          SMALLINT NOT NULL,
    quarter       SMALLINT NOT NULL,
    month         SMALLINT NOT NULL,
    month_name    TEXT     NOT NULL,
    year_month    TEXT     NOT NULL,          -- '1998-01' sorts correctly as text
    day_of_month  SMALLINT NOT NULL,
    day_of_week   SMALLINT NOT NULL,          -- ISO: 1 = Monday ... 7 = Sunday
    day_name      TEXT     NOT NULL,
    is_weekend    BOOLEAN  NOT NULL,
    is_month_end  BOOLEAN  NOT NULL
);

-- Month/day names come from arrays, not to_char(), so the result does not depend on the computer's language.
INSERT INTO analytics.dim_date
    (date_key, full_date, year, quarter, month, month_name, year_month,
     day_of_month, day_of_week, day_name, is_weekend, is_month_end)
SELECT to_char(g.d, 'YYYYMMDD')::INTEGER,
       g.d::date,
       EXTRACT(YEAR    FROM g.d)::SMALLINT,
       EXTRACT(QUARTER FROM g.d)::SMALLINT,
       EXTRACT(MONTH   FROM g.d)::SMALLINT,
       (ARRAY['January','February','March','April','May','June','July','August',
              'September','October','November','December'])[EXTRACT(MONTH FROM g.d)::INTEGER],
       to_char(g.d, 'YYYY-MM'),
       EXTRACT(DAY     FROM g.d)::SMALLINT,
       EXTRACT(ISODOW  FROM g.d)::SMALLINT,
       (ARRAY['Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'])[EXTRACT(ISODOW FROM g.d)::INTEGER],
       EXTRACT(ISODOW FROM g.d) IN (6, 7),
       EXTRACT(DAY FROM g.d + INTERVAL '1 day') = 1     -- tomorrow is the 1st  =>  today is month end
FROM generate_series('1993-01-01'::timestamp, '1998-12-31'::timestamp, INTERVAL '1 day') AS g(d);


-- ------------------------------------------------------------- dim_district
CREATE TABLE analytics.dim_district AS
SELECT * FROM staging.district;
ALTER TABLE analytics.dim_district ADD PRIMARY KEY (district_id);


-- -------------------------------------------------------------- dim_account
-- WARNING for the ML phase: has_card, card_count and has_loan describe the WHOLE period. Using them as model
-- features would leak the future (e.g. a loan taken after the prediction date). They are for reporting only.
CREATE TABLE analytics.dim_account AS
SELECT a.account_id,
       a.district_id,
       a.opened_date,
       a.statement_frequency,
       o.client_id                                                      AS owner_client_id,
       c.gender                                                         AS owner_gender,
       c.birth_date                                                     AS owner_birth_date,
       EXTRACT(YEAR FROM age(a.opened_date, c.birth_date))::INTEGER     AS owner_age_at_opening,
       COALESCE(k.card_count, 0)                                        AS card_count,
       (k.card_count IS NOT NULL)                                       AS has_card,
       (l.loan_count IS NOT NULL)                                       AS has_loan
FROM staging.account a
JOIN staging.disp   o ON o.account_id = a.account_id AND o.disposition_type = 'OWNER'
JOIN staging.client c ON c.client_id  = o.client_id
LEFT JOIN (SELECT d.account_id, COUNT(*) AS card_count
           FROM staging.card cd
           JOIN staging.disp d ON d.disp_id = cd.disp_id
           GROUP BY d.account_id) k ON k.account_id = a.account_id
LEFT JOIN (SELECT account_id, COUNT(*) AS loan_count
           FROM staging.loan
           GROUP BY account_id) l ON l.account_id = a.account_id;
ALTER TABLE analytics.dim_account ADD PRIMARY KEY (account_id);
ALTER TABLE analytics.dim_account
    ADD CONSTRAINT fk_dim_account_district FOREIGN KEY (district_id) REFERENCES analytics.dim_district (district_id);


-- ------------------------------------------------------- dim_txn_category
-- The 12 categories built in staging, grouped for reporting. is_bank_generated matches the staging flag.
CREATE TABLE analytics.dim_txn_category (
    txn_category      TEXT PRIMARY KEY,
    category_group    TEXT    NOT NULL,
    is_bank_generated BOOLEAN NOT NULL,
    description       TEXT    NOT NULL
);
INSERT INTO analytics.dim_txn_category (txn_category, category_group, is_bank_generated, description) VALUES
    ('interest_credit',   'bank_posting', TRUE,  'Interest credited by the bank (k_symbol UROK)'),
    ('penalty_interest',  'bank_posting', TRUE,  'Sanction interest charged when the balance is negative (SANKC. UROK)'),
    ('statement_fee',     'bank_posting', TRUE,  'Payment for the account statement (SLUZBY)'),
    ('cash_deposit',      'cash',         FALSE, 'Credit in cash (VKLAD)'),
    ('cash_withdrawal',   'cash',         FALSE, 'Withdrawal in cash (VYBER, excluding fees and recurring payments)'),
    ('card_withdrawal',   'cash',         FALSE, 'Withdrawal with a credit card (VYBER KARTOU)'),
    ('transfer_in',       'transfer',     FALSE, 'Collection from another bank (PREVOD Z UCTU)'),
    ('transfer_out',      'transfer',     FALSE, 'Remittance to another bank (PREVOD NA UCET)'),
    ('household_payment', 'recurring',    FALSE, 'Household payment (SIPO)'),
    ('insurance_payment', 'recurring',    FALSE, 'Insurance payment (POJISTNE)'),
    ('loan_payment',      'recurring',    FALSE, 'Loan payment (UVER)'),
    ('pension_credit',    'recurring',    FALSE, 'Old-age pension credited (DUCHOD)');


-- --------------------------------------------------------- fact_transactions
-- Explicit table definition (not CREATE TABLE AS): the data types and NOT NULLs are part of the design.
CREATE TABLE analytics.fact_transactions (
    trans_id        INTEGER       NOT NULL,
    account_id      INTEGER       NOT NULL,
    date_key        INTEGER       NOT NULL,
    txn_category    TEXT          NOT NULL,
    direction       TEXT          NOT NULL,    -- 'credit' or 'debit'
    amount          NUMERIC(15,2) NOT NULL,    -- always >= 0
    signed_amount   NUMERIC(15,2) NOT NULL,    -- credit +, debit -
    balance_after   NUMERIC(15,2) NOT NULL,
    partner_bank    TEXT,
    partner_account TEXT
);

INSERT INTO analytics.fact_transactions
    (trans_id, account_id, date_key, txn_category, direction, amount, signed_amount, balance_after,
     partner_bank, partner_account)
SELECT t.trans_id,
       t.account_id,
       to_char(t.trans_date, 'YYYYMMDD')::INTEGER,
       t.txn_category,
       t.direction,
       t.amount,
       t.signed_amount,
       t.balance_after,
       t.partner_bank,
       t.partner_account
FROM staging.trans t;

-- Keys are added AFTER the bulk insert: checking a million rows once is faster than checking each insert.
ALTER TABLE analytics.fact_transactions ADD PRIMARY KEY (trans_id);
ALTER TABLE analytics.fact_transactions
    ADD CONSTRAINT fk_fact_trans_account  FOREIGN KEY (account_id)   REFERENCES analytics.dim_account (account_id),
    ADD CONSTRAINT fk_fact_trans_date     FOREIGN KEY (date_key)     REFERENCES analytics.dim_date (date_key),
    ADD CONSTRAINT fk_fact_trans_category FOREIGN KEY (txn_category) REFERENCES analytics.dim_txn_category (txn_category);
CREATE INDEX ix_fact_trans_account_date ON analytics.fact_transactions (account_id, date_key);
CREATE INDEX ix_fact_trans_date         ON analytics.fact_transactions (date_key);


-- --------------------------------------------------------------- fact_loans
CREATE TABLE analytics.fact_loans (
    loan_id          INTEGER       NOT NULL,
    account_id       INTEGER       NOT NULL,
    date_key         INTEGER       NOT NULL,
    loan_amount      NUMERIC(15,2) NOT NULL,
    duration_months  INTEGER       NOT NULL,
    monthly_payment  NUMERIC(15,2) NOT NULL,
    status_code      TEXT          NOT NULL,
    status_desc      TEXT          NOT NULL,
    is_finished      BOOLEAN       NOT NULL
);

INSERT INTO analytics.fact_loans
    (loan_id, account_id, date_key, loan_amount, duration_months, monthly_payment,
     status_code, status_desc, is_finished)
SELECT l.loan_id,
       l.account_id,
       to_char(l.loan_date, 'YYYYMMDD')::INTEGER,
       l.loan_amount,
       l.duration_months,
       l.monthly_payment,
       l.status_code,
       l.status_desc,
       l.is_finished
FROM staging.loan l;

ALTER TABLE analytics.fact_loans ADD PRIMARY KEY (loan_id);
ALTER TABLE analytics.fact_loans
    ADD CONSTRAINT fk_fact_loans_account FOREIGN KEY (account_id) REFERENCES analytics.dim_account (account_id),
    ADD CONSTRAINT fk_fact_loans_date    FOREIGN KEY (date_key)   REFERENCES analytics.dim_date (date_key);
CREATE INDEX ix_fact_loans_account ON analytics.fact_loans (account_id);

ANALYZE;

-- 01_create_raw_schema.sql
-- Phase 2: raw schema for the Berka banking dataset (exactly as already executed in DBeaver).
-- Kept in version control so the database can be rebuilt. Do NOT run this against a database
-- that already has these tables: CREATE TABLE will fail (that is deliberate - it protects data).
-- Raw layer rule: store the source as-is. Dates stay as YYMMDD integers; cleaning is a later phase.
-- In DBeaver run the whole file with Alt+X (Execute Script), not Ctrl+Enter.

CREATE SCHEMA IF NOT EXISTS raw;

-- 1. Districts
CREATE TABLE raw.district (
    a1 INTEGER PRIMARY KEY,
    a2 TEXT,
    a3 TEXT,
    a4 TEXT,
    a5 TEXT,
    a6 TEXT,
    a7 TEXT,
    a8 TEXT,
    a9 TEXT,
    a10 TEXT,
    a11 TEXT,
    a12 TEXT,
    a13 TEXT,
    a14 TEXT,
    a15 TEXT,
    a16 TEXT
);

-- 2. Accounts
CREATE TABLE raw.account (
    account_id INTEGER PRIMARY KEY,
    district_id INTEGER NOT NULL,
    frequency TEXT NOT NULL,
    date INTEGER NOT NULL,
    CONSTRAINT fk_account_district
        FOREIGN KEY (district_id)
        REFERENCES raw.district(a1)
);

-- 3. Clients
CREATE TABLE raw.client (
    client_id INTEGER PRIMARY KEY,
    birth_number TEXT NOT NULL,
    district_id INTEGER NOT NULL,
    CONSTRAINT fk_client_district
        FOREIGN KEY (district_id)
        REFERENCES raw.district(a1)
);

-- 4. Dispositions (links clients to accounts)
CREATE TABLE raw.disp (
    disp_id INTEGER PRIMARY KEY,
    client_id INTEGER NOT NULL,
    account_id INTEGER NOT NULL,
    type TEXT NOT NULL,
    CONSTRAINT fk_disp_client
        FOREIGN KEY (client_id)
        REFERENCES raw.client(client_id),
    CONSTRAINT fk_disp_account
        FOREIGN KEY (account_id)
        REFERENCES raw.account(account_id)
);

-- 5. Cards
CREATE TABLE raw.card (
    card_id INTEGER PRIMARY KEY,
    disp_id INTEGER NOT NULL,
    type TEXT NOT NULL,
    issued TEXT NOT NULL,
    CONSTRAINT fk_card_disp
        FOREIGN KEY (disp_id)
        REFERENCES raw.disp(disp_id)
);

-- 6. Loans
CREATE TABLE raw.loan (
    loan_id INTEGER PRIMARY KEY,
    account_id INTEGER NOT NULL,
    date INTEGER NOT NULL,
    amount NUMERIC(15, 2) NOT NULL,
    duration INTEGER NOT NULL,
    payments NUMERIC(15, 2) NOT NULL,
    status TEXT NOT NULL,
    CONSTRAINT fk_loan_account
        FOREIGN KEY (account_id)
        REFERENCES raw.account(account_id)
);

-- 7. Standing orders ("order" is a SQL keyword, so it must be quoted)
CREATE TABLE raw."order" (
    order_id INTEGER PRIMARY KEY,
    account_id INTEGER NOT NULL,
    bank_to TEXT,
    account_to TEXT,
    amount NUMERIC(15, 2) NOT NULL,
    k_symbol TEXT,
    CONSTRAINT fk_order_account
        FOREIGN KEY (account_id)
        REFERENCES raw.account(account_id)
);

-- 8. Transactions
CREATE TABLE raw.trans (
    trans_id INTEGER PRIMARY KEY,
    account_id INTEGER NOT NULL,
    date INTEGER NOT NULL,
    type TEXT NOT NULL,
    operation TEXT,
    amount NUMERIC(15, 2) NOT NULL,
    balance NUMERIC(15, 2) NOT NULL,
    k_symbol TEXT,
    bank TEXT,
    account TEXT,
    CONSTRAINT fk_trans_account
        FOREIGN KEY (account_id)
        REFERENCES raw.account(account_id)
);

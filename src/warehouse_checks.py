"""
warehouse_checks.py - the project's "golden values".

Each Check is a SQL query that returns ONE value and the value we expect. The expected values were computed
independently from the Berka source files and match what you verified by hand in DBeaver.
Used by src/build_warehouse.py (after every build) and by tests/test_warehouse.py (pytest).
These numbers belong to THIS dataset: if you ever change the data or the rules, update them on purpose.
"""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal


@dataclass(frozen=True)
class Check:
    name: str
    sql: str
    expected: object

    def run(self, cur):
        """Return (passed, actual)."""
        actual = cur.execute(self.sql).fetchone()[0]
        return actual == self.expected, actual


ROWS = [
    ("district", 77), ("account", 4_500), ("client", 5_369), ("disp", 5_369),
    ("card", 892), ("loan", 682), ("order", 6_471), ("trans", 1_056_320),
]


def _raw(table: str) -> str:
    return 'raw."order"' if table == "order" else f"raw.{table}"


def _staging(table: str) -> str:
    return "staging.standing_order" if table == "order" else f"staging.{table}"


CHECKS: list[Check] = []

# ---- raw: row counts, foreign keys, money ----
CHECKS += [Check(f"raw rows: {t}", f"SELECT COUNT(*) FROM {_raw(t)}", n) for t, n in ROWS]
CHECKS += [
    Check("raw foreign keys validated",
          "SELECT COUNT(*) FROM pg_constraint WHERE contype = 'f' AND convalidated "
          "AND connamespace = 'raw'::regnamespace", 8),
    Check("raw trans total amount", "SELECT SUM(amount) FROM raw.trans", Decimal("6257793560.30")),
    Check("raw trans total balance", "SELECT SUM(balance) FROM raw.trans", Decimal("40687683194.00")),
]

# ---- staging: same row counts as raw, no untranslated codes, money, categories ----
CHECKS += [Check(f"staging rows: {t}", f"SELECT COUNT(*) FROM {_staging(t)}", n) for t, n in ROWS]
CHECKS += [
    Check("staging untranslated codes (must be 0)",
          "SELECT (SELECT COUNT(*) FROM staging.trans WHERE direction IS NULL OR txn_category IS NULL)"
          " + (SELECT COUNT(*) FROM staging.account WHERE statement_frequency IS NULL)"
          " + (SELECT COUNT(*) FROM staging.loan WHERE status_desc IS NULL)"
          " + (SELECT COUNT(*) FROM staging.client WHERE gender IS NULL OR birth_date IS NULL)"
          " + (SELECT COUNT(*) FROM staging.card WHERE issued_date IS NULL)", 0),
    Check("staging clients: men", "SELECT COUNT(*) FROM staging.client WHERE gender = 'M'", 2_724),
    Check("staging clients: women", "SELECT COUNT(*) FROM staging.client WHERE gender = 'F'", 2_645),
    Check("staging first transaction date", "SELECT MIN(trans_date)::text FROM staging.trans", "1993-01-01"),
    Check("staging last transaction date", "SELECT MAX(trans_date)::text FROM staging.trans", "1998-12-31"),
    Check("staging credit total",
          "SELECT SUM(amount) FROM staging.trans WHERE direction = 'credit'", Decimal("3227472424.50")),
    Check("staging debit total",
          "SELECT SUM(amount) FROM staging.trans WHERE direction = 'debit'", Decimal("3030321135.80")),
    Check("staging net flow", "SELECT SUM(signed_amount) FROM staging.trans", Decimal("197151288.70")),
    Check("staging bank-generated postings",
          "SELECT COUNT(*) FROM staging.trans WHERE is_bank_generated", 340_523),
    Check("staging cash_withdrawal transactions",
          "SELECT COUNT(*) FROM staging.trans WHERE txn_category = 'cash_withdrawal'", 274_675),
    Check("staging statement_fee transactions",
          "SELECT COUNT(*) FROM staging.trans WHERE txn_category = 'statement_fee'", 155_832),
]

# ---- analytics: dimensions, no fan-out, facts agree with staging ----
CHECKS += [
    Check("analytics rows: dim_date", "SELECT COUNT(*) FROM analytics.dim_date", 2_191),
    Check("analytics rows: dim_district", "SELECT COUNT(*) FROM analytics.dim_district", 77),
    Check("analytics rows: dim_account", "SELECT COUNT(*) FROM analytics.dim_account", 4_500),
    Check("analytics rows: dim_txn_category", "SELECT COUNT(*) FROM analytics.dim_txn_category", 12),
    Check("analytics rows: fact_transactions", "SELECT COUNT(*) FROM analytics.fact_transactions", 1_056_320),
    Check("analytics rows: fact_loans", "SELECT COUNT(*) FROM analytics.fact_loans", 682),
    Check("analytics dim_account has no duplicate accounts",
          "SELECT COUNT(DISTINCT account_id) FROM analytics.dim_account", 4_500),
    Check("analytics owners: men", "SELECT COUNT(*) FROM analytics.dim_account WHERE owner_gender = 'M'", 2_292),
    Check("analytics owners: women", "SELECT COUNT(*) FROM analytics.dim_account WHERE owner_gender = 'F'", 2_208),
    Check("analytics total cards", "SELECT SUM(card_count) FROM analytics.dim_account", 892),
    Check("analytics accounts with a loan", "SELECT COUNT(*) FROM analytics.dim_account WHERE has_loan", 682),
    Check("analytics fact net flow equals staging",
          "SELECT SUM(signed_amount) FROM analytics.fact_transactions", Decimal("197151288.70")),
    Check("analytics category flag mismatches (must be 0)",
          "SELECT COUNT(*) FROM staging.trans t JOIN analytics.dim_txn_category c "
          "ON c.txn_category = t.txn_category WHERE t.is_bank_generated <> c.is_bank_generated", 0),
    Check("analytics foreign keys validated",
          "SELECT COUNT(*) FROM pg_constraint WHERE contype = 'f' AND convalidated "
          "AND connamespace = 'analytics'::regnamespace", 6),
    Check("analytics January 1998 transactions via the star",
          "SELECT COUNT(*) FROM analytics.fact_transactions f JOIN analytics.dim_date d "
          "ON d.date_key = f.date_key WHERE d.year = 1998 AND d.month = 1", 42_940),
]


# ======================================================================================
# Added after the analytics layer and the K1-K6 KPI queries were verified by hand in DBeaver.
# These pin the verified baseline: dates, ranges, the VYBER sign convention, and the exact KPI results.
# "Strings" below are one-value summaries (many numbers joined with string_agg) so a single check covers a whole table.
# ======================================================================================

_FACT_STAR = (
    "FROM analytics.fact_transactions f "
    "JOIN analytics.dim_date d ON d.date_key = f.date_key "
)

CHECKS += [
    # ---- structure ----
    Check("primary keys exist on all 14 staging + analytics tables",
          "SELECT COUNT(*) FROM information_schema.table_constraints "
          "WHERE constraint_type = 'PRIMARY KEY' AND table_schema IN ('staging', 'analytics')", 14),

    # ---- dates: would catch a swapped month/day or a wrong century, not just the min and max ----
    Check("staging transactions per year",
          "SELECT string_agg(y::text || ':' || n, ',' ORDER BY y) FROM "
          "(SELECT EXTRACT(YEAR FROM trans_date)::INTEGER AS y, COUNT(*) AS n FROM staging.trans GROUP BY 1) x",
          "1993:28205,1994:91628,1995:133022,1996:196779,1997:284409,1998:322277"),
    Check("staging account opened range",
          "SELECT MIN(opened_date)::text || ' to ' || MAX(opened_date)::text FROM staging.account",
          "1993-01-01 to 1997-12-29"),
    Check("staging loan date range",
          "SELECT MIN(loan_date)::text || ' to ' || MAX(loan_date)::text FROM staging.loan",
          "1993-07-05 to 1998-12-08"),
    Check("staging card issued range",
          "SELECT MIN(issued_date)::text || ' to ' || MAX(issued_date)::text FROM staging.card",
          "1993-11-07 to 1998-12-29"),
    Check("staging client birth range",
          "SELECT MIN(birth_date)::text || ' to ' || MAX(birth_date)::text FROM staging.client",
          "1911-08-20 to 1987-09-27"),
    Check("dim_date has 366 days in 1996 (leap year)",
          "SELECT COUNT(*) FROM analytics.dim_date WHERE year = 1996", 366),
    Check("dim_date has 72 month ends (6 years x 12)",
          "SELECT COUNT(*) FROM analytics.dim_date WHERE is_month_end", 72),
    Check("dim_date: 1998-01-31 is a Saturday and a month end",
          "SELECT day_name || ':' || is_month_end::text FROM analytics.dim_date WHERE full_date = DATE '1998-01-31'",
          "Saturday:true"),

    # ---- ranges and codes ----
    Check("no negative transaction amounts", "SELECT COUNT(*) FROM analytics.fact_transactions WHERE amount < 0", 0),
    Check("zero-amount postings (14 interest/penalty rows, kept on purpose)",
          "SELECT COUNT(*) FROM analytics.fact_transactions WHERE amount = 0", 14),
    Check("owner age at account opening is between 0 and 100 (must be 0 violations)",
          "SELECT COUNT(*) FROM analytics.dim_account WHERE owner_age_at_opening NOT BETWEEN 0 AND 100", 0),
    Check("loan durations are only 12/24/36/48/60 months (must be 0 others)",
          "SELECT COUNT(*) FROM staging.loan WHERE duration_months NOT IN (12, 24, 36, 48, 60)", 0),
    Check("staging k_symbol_code 'none' (NULL and lone space merged)",
          "SELECT COUNT(*) FROM staging.trans WHERE k_symbol_code = 'none'", 535_314),
    Check("staging k_symbol_code is never an empty string",
          "SELECT COUNT(*) FROM staging.trans WHERE k_symbol_code = ''", 0),

    # ---- the sign convention (VYBER = debit) proven on rows with no ordering ambiguity ----
    # Format  type:rows tested:% reconciled.  VYBER at 100.00 is the proof that VYBER is a debit.
    Check("balance reconciliation on unambiguous rows (proves the sign convention)",
          "WITH day_counts AS ("
          "  SELECT t.*, COUNT(*) OVER (PARTITION BY account_id, trans_date) AS n_day FROM staging.trans t), "
          "chained AS ("
          "  SELECT d.*, LAG(balance_after) OVER w AS prev_balance, LAG(n_day) OVER w AS prev_n_day "
          "  FROM day_counts d WINDOW w AS (PARTITION BY account_id ORDER BY trans_date, trans_id)), "
          "per_type AS ("
          "  SELECT type_code, COUNT(*) AS n, "
          "         ROUND(100.0 * COUNT(*) FILTER (WHERE prev_balance + signed_amount = balance_after) / COUNT(*), 2) AS pct "
          "  FROM chained WHERE n_day = 1 AND prev_n_day = 1 GROUP BY type_code) "
          "SELECT string_agg(type_code || ':' || n || ':' || pct, ',' ORDER BY type_code) FROM per_type",
          "PRIJEM:137349:96.97,VYBER:9597:100.00,VYDAJ:259995:99.56"),

    # ---- verified baselines from 07_validate_analytics.sql and 08_descriptive_kpis.sql ----
    Check("K1 yearly: year:active accounts:customer transactions",
          "SELECT string_agg(x.year::text || ':' || x.accts || ':' || x.txns, ',' ORDER BY x.year) FROM "
          "(SELECT d.year, COUNT(DISTINCT f.account_id) AS accts, COUNT(*) AS txns "
          + _FACT_STAR +
          "JOIN analytics.dim_txn_category c ON c.txn_category = f.txn_category "
          "WHERE NOT c.is_bank_generated GROUP BY d.year) x",
          "1993:1139:19209,1994:1578:61794,1995:2239:90155,1996:3602:133052,1997:4496:192063,1998:4492:219524"),
    Check("K2 total amount per transaction category",
          "SELECT string_agg(txn_category || ':' || total, ',' ORDER BY txn_category COLLATE \"C\") FROM "
          "(SELECT txn_category, SUM(amount) AS total FROM analytics.fact_transactions GROUP BY txn_category) x",
          "card_withdrawal:18170400.00,cash_deposit:2418521782.00,cash_withdrawal:2314362168.00,"
          "household_payment:498506416.00,insurance_payment:24175193.00,interest_credit:27470689.50,"
          "loan_payment:55252303.30,penalty_interest:37663.30,pension_credit:167472118.00,"
          "statement_fee:2686418.20,transfer_in:614007835.00,transfer_out:117130574.00"),
    Check("K4 fee income by year: year:statement fees:penalty interest:interest paid",
          "SELECT string_agg(y::text || ':' || fees || ':' || pen || ':' || intr, ',' ORDER BY y) FROM "
          "(SELECT d.year AS y, "
          "  SUM(f.amount) FILTER (WHERE f.txn_category = 'statement_fee')    AS fees, "
          "  SUM(f.amount) FILTER (WHERE f.txn_category = 'penalty_interest') AS pen, "
          "  SUM(f.amount) FILTER (WHERE f.txn_category = 'interest_credit')  AS intr "
          + _FACT_STAR + "GROUP BY d.year) x",
          "1993:49921.60:75.00:810862.90,1994:232651.60:696.70:2293651.90,1995:343631.80:1120.80:3298008.60,"
          "1996:500804.80:1821.60:5010410.20,1997:743714.00:6823.20:7372897.70,1998:815694.40:27126.00:8684858.20"),
    Check("K5 loans by issue year: year:loans:total issued",
          "SELECT string_agg(y::text || ':' || n || ':' || total, ',' ORDER BY y) FROM "
          "(SELECT d.year AS y, COUNT(*) AS n, SUM(l.loan_amount) AS total FROM analytics.fact_loans l "
          "JOIN analytics.dim_date d ON d.date_key = l.date_key GROUP BY d.year) x",
          "1993:20:2619276.00,1994:101:13379904.00,1995:90:13344372.00,1996:117:18317676.00,"
          "1997:196:30731364.00,1998:158:24869148.00"),
    Check("K6 total loan amount issued", "SELECT SUM(loan_amount) FROM analytics.fact_loans", Decimal("103261740.00")),
    Check("K6 loan amount in trouble (status B or D)",
          "SELECT SUM(loan_amount) FROM analytics.fact_loans WHERE status_code IN ('B', 'D')", Decimal("15580152.00")),
    Check("W7 transactions per month in 1998: month:transactions",
          "SELECT string_agg(m::text || ':' || n, ',' ORDER BY m) FROM "
          "(SELECT d.month AS m, COUNT(*) AS n " + _FACT_STAR + "WHERE d.year = 1998 GROUP BY d.month) x",
          "1:42940,2:23995,3:25341,4:25297,5:25634,6:27833,7:25582,8:25622,9:25450,10:25689,11:25341,12:23553"),
    Check("W8 1998 region: region:transactions:net flow",
          "SELECT string_agg(region || ':' || n || ':' || net, ',' ORDER BY region COLLATE \"C\") FROM "
          "(SELECT dd.region, COUNT(*) AS n, SUM(f.signed_amount) AS net " + _FACT_STAR +
          "JOIN analytics.dim_account a ON a.account_id = f.account_id "
          "JOIN analytics.dim_district dd ON dd.district_id = a.district_id "
          "WHERE d.year = 1998 GROUP BY dd.region) x",
          "Prague:40178:3525059.60,central Bohemia:41733:3464066.00,east Bohemia:37697:3590384.30,"
          "north Bohemia:32798:2923410.40,north Moravia:57219:4467785.80,south Bohemia:26307:2013717.50,"
          "south Moravia:55571:4506485.90,west Bohemia:30774:2654297.60"),
]

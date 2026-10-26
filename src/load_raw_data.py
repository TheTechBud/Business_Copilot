"""
load_raw_data.py - Phase 2: load the eight Berka .asc files into PostgreSQL (schema "raw").

How it works
------------
* Method: PostgreSQL COPY (psycopg 3), streaming the file row by row.
  This replaces pandas.to_sql(method="multi"), which built one gigantic INSERT with
  rows x columns bind parameters (PostgreSQL allows at most 65,535 per statement).
* Safety: the WHOLE load is ONE transaction. Before COMMIT the script compares, for every
  table, the row count and the column totals in the database with the source files.
  Any problem -> ROLLBACK -> the database is exactly as it was. Fix, then run again.
* Nothing is silently dropped: a row with the wrong number of fields, or a non-numeric
  value in a numeric column, stops the load with the table and line number.
* Raw layer rule: values are loaded as they appear in the file. The only change is that a
  completely empty field becomes NULL. (A field holding a single space stays a space;
  the staging layer will tidy that later.) Dates stay as integers such as 930101.

Run (PowerShell, virtual environment active, from the project folder):
    python src\\load_raw_data.py            # first load (tables must be empty)
    python src\\load_raw_data.py --reload   # replace existing rows (asks you to confirm)
"""

from __future__ import annotations

import argparse
import csv
import os
import time
from decimal import Decimal, InvalidOperation
from getpass import getpass
from pathlib import Path

import psycopg
from psycopg import sql

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

PROJECT_DIR = Path(__file__).resolve().parents[1]
DATA_DIR = PROJECT_DIR / "Data" / "raw"

SCHEMA = "raw"
ENCODING = "latin-1"  # never fails to decode; the Berka files are plain ASCII anyway
PROGRESS_EVERY = 100_000
NUMERIC_TYPES = {"smallint", "integer", "bigint", "numeric"}
EXPECTED_FOREIGN_KEYS = 8

DB_SETTINGS = {
    "host": os.environ.get("PGHOST", "localhost"),
    "port": int(os.environ.get("PGPORT", "5432")),
    "dbname": os.environ.get("PGDATABASE", "business_analytics_copilot"),
    "user": os.environ.get("PGUSER", "postgres"),
}

# Parents before children (foreign-key safe order): (table, source file)
TABLES = [
    ("district", "district.asc"),
    ("account", "account.asc"),
    ("client", "client.asc"),
    ("disp", "disp.asc"),
    ("card", "card.asc"),
    ("loan", "loan.asc"),
    ("order", "order.asc"),
    ("trans", "trans.asc"),
]

# Validation targets (the published Berka counts). A difference is reported, not assumed wrong.
EXPECTED_ROWS = {
    "district": 77,
    "account": 4_500,
    "client": 5_369,
    "disp": 5_369,
    "card": 892,
    "loan": 682,
    "order": 6_471,
    "trans": 1_056_320,
}


def log(message: str = "") -> None:
    print(message, flush=True)


# --------------------------------------------------------------------------
# Database helpers
# --------------------------------------------------------------------------

def table_ident(table: str) -> sql.Identifier:
    return sql.Identifier(SCHEMA, table)  # renders "raw"."order" etc. (handles keywords)


def preflight(cur, reload: bool) -> dict[str, list[tuple[str, str]]]:
    """Check database, schema, constraints and emptiness. Returns {table: [(column, type)]}."""
    dbname = cur.execute("SELECT current_database()").fetchone()[0]
    if dbname != DB_SETTINGS["dbname"]:
        raise RuntimeError(f"Connected to {dbname!r}, expected {DB_SETTINGS['dbname']!r}.")
    log(f"Connected to database: {dbname}")

    meta: dict[str, list[tuple[str, str]]] = {}
    rows = cur.execute(
        """
        SELECT table_name, column_name, data_type
        FROM information_schema.columns
        WHERE table_schema = %s
        ORDER BY table_name, ordinal_position
        """,
        (SCHEMA,),
    ).fetchall()
    for table_name, column_name, data_type in rows:
        meta.setdefault(table_name, []).append((column_name, data_type))

    missing = [t for t, _ in TABLES if t not in meta]
    if missing:
        raise RuntimeError(f"Tables missing from schema {SCHEMA!r}: {missing}")

    fk_count = cur.execute(
        "SELECT COUNT(*) FROM pg_constraint WHERE contype = 'f' AND connamespace = %s::regnamespace",
        (SCHEMA,),
    ).fetchone()[0]
    if fk_count != EXPECTED_FOREIGN_KEYS:
        raise RuntimeError(
            f"Expected {EXPECTED_FOREIGN_KEYS} foreign keys in schema {SCHEMA!r}, found {fk_count}. "
            "Run sql/02_verify_raw_load.sql (section B) to see which are missing."
        )
    log(f"Schema check passed: {len(TABLES)} tables, {fk_count} foreign keys.")

    if reload:
        # TRUNCATE is transactional in PostgreSQL: if the load fails, the old rows come back.
        # All eight tables must be named in ONE statement because of the foreign keys.
        names = sql.SQL(", ").join(table_ident(t) for t, _ in reversed(TABLES))
        cur.execute(sql.SQL("TRUNCATE {}").format(names))
        log("--reload: existing rows removed (inside the transaction).")
    else:
        for table, _ in TABLES:
            count = cur.execute(sql.SQL("SELECT COUNT(*) FROM {}").format(table_ident(table))).fetchone()[0]
            if count != 0:
                raise RuntimeError(
                    f"{SCHEMA}.{table} already has {count:,} rows. Refusing to load on top of existing "
                    "data. If you want to replace it, run again with --reload."
                )
        log("All eight destination tables are empty.")
    return meta


def load_table(cur, table: str, path: Path, columns: list[tuple[str, str]]) -> dict:
    """Stream one source file into raw.<table> with COPY. Returns what the SOURCE contained."""
    db_columns = [name for name, _ in columns]
    numeric = {name for name, data_type in columns if data_type in NUMERIC_TYPES}
    started = time.time()
    rows = 0

    log(f"\nLoading {path.name} -> {SCHEMA}.{table}")
    with open(path, newline="", encoding=ENCODING) as handle:
        reader = csv.reader(handle, delimiter=";", quotechar='"')
        try:
            header = [name.strip().lower() for name in next(reader)]
            if sorted(header) != sorted(db_columns):
                raise ValueError(
                    f"{path.name}: header {header} does not match table columns {db_columns}."
                )
            numeric_positions = [(i, name) for i, name in enumerate(header) if name in numeric]
            sums = {name: Decimal(0) for _, name in numeric_positions}

            copy_query = sql.SQL("COPY {} ({}) FROM STDIN").format(
                table_ident(table),
                sql.SQL(", ").join(sql.Identifier(name) for name in header),
            )

            with cur.copy(copy_query) as copy:
                for row in reader:
                    if len(row) != len(header):
                        raise ValueError(
                            f"{path.name} line {reader.line_num}: {len(row)} fields, expected {len(header)}."
                        )
                    values = [value if value != "" else None for value in row]  # empty -> NULL

                    for position, name in numeric_positions:
                        value = values[position]
                        if value is None:
                            continue
                        try:
                            sums[name] += Decimal(value)
                        except InvalidOperation:
                            raise ValueError(
                                f"{path.name} line {reader.line_num}, column {name}: "
                                f"{value!r} is not a number."
                            ) from None

                    copy.write_row(values)
                    rows += 1
                    if rows % PROGRESS_EVERY == 0:
                        log(f"  {rows:>10,} rows sent ({time.time() - started:.0f}s)")
        except Exception:
            log(
                f"\nERROR while loading {table} (source file line about {reader.line_num}; "
                "line 1 is the header. A database message such as 'COPY ..., line N' counts "
                "from the first data row, so source line = N + 1)."
            )
            raise

    log(f"  finished {table}: {rows:,} rows in {time.time() - started:.1f}s")
    return {"rows": rows, "sums": sums}


def db_stats(cur, table: str, numeric_columns: list[str]) -> dict:
    parts = [sql.SQL("COUNT(*)")] + [sql.SQL("SUM({})").format(sql.Identifier(c)) for c in numeric_columns]
    query = sql.SQL("SELECT {} FROM {}").format(sql.SQL(", ").join(parts), table_ident(table))
    result = cur.execute(query).fetchone()
    sums = {c: Decimal(result[i + 1] if result[i + 1] is not None else 0) for i, c in enumerate(numeric_columns)}
    return {"rows": result[0], "sums": sums}


def verify(cur, source_stats: dict) -> None:
    """Compare database contents with what the source files contained. Raise on any difference."""
    log("\nVERIFYING database against source files (before commit)")
    problems = []
    for table, _ in TABLES:
        source = source_stats[table]
        database = db_stats(cur, table, list(source["sums"]))
        issues = []
        if database["rows"] != source["rows"]:
            issues.append(f"rows: source {source['rows']:,} vs database {database['rows']:,}")
        for column, total in source["sums"].items():
            if database["sums"][column] != total:
                issues.append(f"sum({column}): source {total} vs database {database['sums'][column]}")

        expected = EXPECTED_ROWS[table]
        note = "" if source["rows"] == expected else f"  (differs from published count {expected:,} - check)"
        status = "OK  " if not issues else "FAIL"
        log(f"  {status} {table:9} rows={database['rows']:>10,}  numeric columns checked={len(source['sums'])}{note}")
        problems += [f"{table}: {issue}" for issue in issues]

    if problems:
        raise RuntimeError("Verification failed - nothing will be committed:\n  " + "\n  ".join(problems))


def final_report(password: str) -> None:
    """Fresh connection after the commit: prove the data is really there."""
    log("\nFINAL CHECK (new connection, after commit)")
    with psycopg.connect(password=password, **DB_SETTINGS) as conn:
        with conn.cursor() as cur:
            for table, _ in TABLES:
                count = cur.execute(sql.SQL("SELECT COUNT(*) FROM {}").format(table_ident(table))).fetchone()[0]
                log(f"  {table:9} {count:>10,}")
            fks = cur.execute(
                """
                SELECT conrelid::regclass::text, conname, convalidated
                FROM pg_constraint
                WHERE contype = 'f' AND connamespace = %s::regnamespace
                ORDER BY 1, 2
                """,
                (SCHEMA,),
            ).fetchall()
            validated = sum(1 for _, _, ok in fks if ok)
            log(f"  foreign keys: {validated} of {len(fks)} validated")


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(description="Load the Berka .asc files into PostgreSQL schema raw.")
    parser.add_argument("--reload", action="store_true",
                        help="replace rows that are already in the raw tables (asks for confirmation)")
    args = parser.parse_args()

    for _, filename in TABLES:
        path = DATA_DIR / filename
        if not path.is_file():
            raise FileNotFoundError(f"Missing source file: {path}")
    log(f"All eight source files found in {DATA_DIR}")

    if args.reload:
        answer = input("--reload will DELETE every row in the eight raw tables and load them again.\n"
                       "Type RELOAD to continue: ")
        if answer.strip() != "RELOAD":
            log("Cancelled. Nothing was changed.")
            return

    password = os.environ.get("PGPASSWORD") or getpass(f"PostgreSQL password for user {DB_SETTINGS['user']}: ")
    started = time.time()

    try:
        # Leaving this block normally COMMITS; any exception inside it ROLLS BACK.
        with psycopg.connect(password=password, **DB_SETTINGS) as conn:
            with conn.cursor() as cur:
                meta = preflight(cur, reload=args.reload)
                source_stats = {}
                for table, filename in TABLES:
                    source_stats[table] = load_table(cur, table, DATA_DIR / filename, meta[table])
                verify(cur, source_stats)
            log("\nVerification passed. Committing ...")
    except Exception as exc:
        log("\nLOAD FAILED. Nothing was committed (the database is unchanged).")
        diag = getattr(exc, "diag", None)
        if diag is not None:
            if diag.message_primary:
                log(f"  database message: {diag.message_primary}")
            if diag.message_detail:
                log(f"  detail          : {diag.message_detail}")
            if diag.context:
                log(f"  context         : {diag.context}")
        raise

    log(f"Committed in {time.time() - started:.0f}s.")
    final_report(password)
    log("\nDone. All rows loaded, verified against the source files, and committed.")


if __name__ == "__main__":
    main()

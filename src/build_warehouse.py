"""
build_warehouse.py - check the staging and analytics layers, or rebuild them and check.

    python src\build_warehouse.py             # DEFAULT: read-only. Runs every check and changes nothing.
    python src\build_warehouse.py --rebuild   # DROP and recreate staging + analytics, then check (asks you to confirm)

Safety
  * The default run opens a READ-ONLY transaction, so even a mistake cannot write anything.
  * --rebuild first lists what will be dropped, warns about any object it did not create, and asks you to type REBUILD.
  * Rebuild runs both SQL files and every check in ONE transaction. If any check fails the script rolls back, so
    staging and analytics are exactly as they were. (PostgreSQL DDL is transactional; a crash also rolls back.)
  * Only the schemas "staging" and "analytics" are dropped, with CASCADE. Anything anyone put in them is lost, and
    CASCADE also drops objects in OTHER schemas that depend on them. Keep ML features and predictions elsewhere (e.g. a schema "ml").
  * The raw schema is only ever read.
  * A rebuild takes locks on staging/analytics: close DBeaver tabs with an open transaction, or the script will wait.
"""

from __future__ import annotations

import argparse
import sys
import time

import psycopg

from db_config import DB_SETTINGS, SQL_DIR, get_password
from warehouse_checks import CHECKS

SQL_STEPS = [
    ("staging layer", "04_create_staging.sql"),
    ("analytics layer", "06_create_analytics.sql"),
]

# What the two SQL files create. Anything else found in these schemas would be destroyed by a rebuild.
EXPECTED_OBJECTS = {
    "staging": {"district", "account", "client", "disp", "card", "loan", "standing_order", "trans"},
    "analytics": {"dim_date", "dim_district", "dim_account", "dim_txn_category", "fact_transactions", "fact_loans"},
}


def log(message: str = "") -> None:
    print(message, flush=True)


def parse_args(argv=None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Check (default) or rebuild the staging and analytics layers.")
    parser.add_argument("--rebuild", action="store_true",
                        help="drop and recreate the staging and analytics schemas, then run the checks")
    parser.add_argument("--yes", action="store_true",
                        help="with --rebuild: skip the typed confirmation (refused if unexpected objects exist)")
    return parser.parse_args(argv)


def confirm_rebuild(cur, assume_yes: bool) -> bool:
    """Show what a rebuild would destroy. Return True only if the user agrees."""
    rows = cur.execute(
        "SELECT table_schema, table_name FROM information_schema.tables "
        "WHERE table_schema IN ('staging', 'analytics') ORDER BY 1, 2"
    ).fetchall()
    found = {schema: set() for schema in EXPECTED_OBJECTS}
    for schema, name in rows:
        found[schema].add(name)

    log("\nA rebuild will DROP these schemas (CASCADE) and create them again:")
    unexpected = []
    for schema, expected in EXPECTED_OBJECTS.items():
        log(f"  {schema}: {len(found[schema])} tables/views present")
        unexpected += [f"{schema}.{name}" for name in sorted(found[schema] - expected)]
    if unexpected:
        log("\n  WARNING - these objects are not created by the build scripts and would be LOST:")
        for name in unexpected:
            log(f"    {name}")
    if assume_yes:
        if unexpected:
            log("\n--yes refused because of the unexpected objects above. Run again without --yes.")
            return False
        return True
    return input("\nType REBUILD to continue: ").strip() == "REBUILD"


def run_checks(cur) -> int:
    """Run every check, print PASS/FAIL, return how many failed."""
    failed = 0
    log(f"\nRUNNING {len(CHECKS)} CHECKS")
    for check in CHECKS:
        passed, actual = check.run(cur)
        if passed:
            log(f"  PASS  {check.name}")
        else:
            failed += 1
            log(f"  FAIL  {check.name}\n          expected {check.expected!r}\n          but got  {actual!r}")
    log(f"\n{len(CHECKS) - failed} passed, {failed} failed")
    return failed


def main(argv=None) -> int:
    args = parse_args(argv)

    scripts = []
    if args.rebuild:
        for label, filename in SQL_STEPS:
            path = SQL_DIR / filename
            if not path.is_file():
                raise FileNotFoundError(f"Missing SQL file: {path}")
            scripts.append((label, path))

    password = get_password()
    started = time.time()
    try:
        with psycopg.connect(password=password, **DB_SETTINGS) as conn:
            if not args.rebuild:
                conn.read_only = True          # must be set before the first statement
            with conn.cursor() as cur:
                log(f"Connected to database: {conn.info.dbname}")
                if args.rebuild:
                    if not confirm_rebuild(cur, args.yes):
                        log("Cancelled. Nothing was changed.")
                        return 0
                    for label, path in scripts:
                        step_started = time.time()
                        log(f"\nBuilding {label} ({path.name}) ...")
                        cur.execute(path.read_text(encoding="utf-8"))   # no parameters: several statements are fine
                        log(f"  done in {time.time() - step_started:.0f}s")
                else:
                    log("Check-only mode (read-only transaction). Nothing will be changed. Use --rebuild to rebuild.")
                if run_checks(cur):
                    log("\nSome checks failed." + (" Rolling back: nothing was changed." if args.rebuild else ""))
                    sys.exit(1)   # leaving the with-block with an exception triggers the rollback
            if args.rebuild:
                log("\nCommitting ...")
    except psycopg.Error as exc:
        log("\nFAILED. Nothing was committed.")
        diag = exc.diag
        if diag.message_primary:
            log(f"  database message: {diag.message_primary}")
        if diag.context:
            log(f"  context         : {diag.context}")
        raise

    log(f"Done in {time.time() - started:.0f}s. All checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

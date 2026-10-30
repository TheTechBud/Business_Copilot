"""
pytest tests for the data pipeline.

    python -m pytest -q                     # tests that need no database
    $env:PGPASSWORD = "your-password"       # PowerShell, this window only
    python -m pytest -q                     # now the database checks run too
"""

import os
import re

import pytest

from db_config import DB_SETTINGS, SQL_DIR
from warehouse_checks import CHECKS


# ---------- tests that need NO database ----------

def test_derived_layers_never_touch_raw():
    """Only 01_create_raw_schema.sql may mention the raw schema in a destructive statement."""
    bad = re.compile(r"(DROP|TRUNCATE|DELETE\s+FROM|ALTER|UPDATE|INSERT\s+INTO)\s+(SCHEMA\s+(IF\s+EXISTS\s+)?|TABLE\s+(IF\s+EXISTS\s+)?)?raw\b",
                     re.IGNORECASE)
    for path in SQL_DIR.glob("*.sql"):
        if path.name.startswith("01_"):
            continue
        text = re.sub(r"--.*", "", path.read_text(encoding="utf-8"))   # ignore comments
        assert not bad.search(text), f"{path.name} modifies the raw schema"


def test_check_names_are_unique():
    names = [c.name for c in CHECKS]
    assert len(names) == len(set(names))


def test_default_run_is_check_only():
    """Running build_warehouse.py with no flags must never rebuild anything."""
    from build_warehouse import parse_args
    args = parse_args([])
    assert args.rebuild is False and args.yes is False


def test_loader_loads_parents_before_children():
    from load_raw_data import TABLES
    parents = {"district": [], "account": ["district"], "client": ["district"], "disp": ["client", "account"],
               "card": ["disp"], "loan": ["account"], "order": ["account"], "trans": ["account"]}
    order = [t for t, _ in TABLES]
    for child, needed in parents.items():
        for parent in needed:
            assert order.index(parent) < order.index(child), f"{parent} must load before {child}"


# ---------- tests that need the database (skipped if PGPASSWORD is not set) ----------

@pytest.fixture(scope="module")
def cur():
    password = os.environ.get("PGPASSWORD")
    if not password:
        pytest.skip("set PGPASSWORD to run the database checks")
    import psycopg
    with psycopg.connect(password=password, **DB_SETTINGS) as conn:
        conn.read_only = True            # the tests may read, never write
        with conn.cursor() as cursor:
            yield cursor


@pytest.mark.parametrize("check", CHECKS, ids=lambda c: c.name)
def test_database_check(cur, check):
    passed, actual = check.run(cur)
    assert passed, f"expected {check.expected!r} but got {actual!r}"

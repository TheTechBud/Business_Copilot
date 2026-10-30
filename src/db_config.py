"""Shared database settings for the project scripts (the password is never stored)."""

import os
from getpass import getpass
from pathlib import Path

PROJECT_DIR = Path(__file__).resolve().parents[1]
SQL_DIR = PROJECT_DIR / "sql"

DB_SETTINGS = {
    "host": os.environ.get("PGHOST", "localhost"),
    "port": int(os.environ.get("PGPORT", "5432")),
    "dbname": os.environ.get("PGDATABASE", "business_analytics_copilot"),
    "user": os.environ.get("PGUSER", "postgres"),
}


def get_password() -> str:
    """Use PGPASSWORD if it is set (handy for tests), otherwise ask. Never print it."""
    return os.environ.get("PGPASSWORD") or getpass(f"PostgreSQL password for user {DB_SETTINGS['user']}: ")

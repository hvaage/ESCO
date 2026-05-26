#!/usr/bin/env python3
"""Apply repo SQL migrations directly with DATABASE_URL.

This is a lightweight fallback for environments where the Supabase CLI is not
linked yet. It does not update Supabase's migration-history table; prefer
`supabase db push` for long-lived team workflows.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

import psycopg
from dotenv import load_dotenv


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--migrations-dir", type=Path, default=Path("supabase/migrations"))
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    files = sorted(args.migrations_dir.glob("*.sql"))
    if not files:
        print(f"No migrations found in {args.migrations_dir}", file=sys.stderr)
        return 2

    for path in files:
        print(f"{'Would apply' if args.dry_run else 'Applying'} {path}")

    if args.dry_run:
        return 0

    load_dotenv()
    database_url = os.getenv("DATABASE_URL")
    if not database_url:
        print("DATABASE_URL is required. Put it in .env or export it.", file=sys.stderr)
        return 2

    with psycopg.connect(database_url) as conn:
        with conn.cursor() as cur:
            for path in files:
                cur.execute(path.read_text(encoding="utf-8"))
        conn.commit()

    print("Migrations applied.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

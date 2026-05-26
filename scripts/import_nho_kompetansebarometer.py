#!/usr/bin/env python3
"""Import an NHO Kompetansebarometer migration package into Supabase."""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import os
import sys
import zipfile
from pathlib import Path
from typing import Any, Iterable

from dotenv import load_dotenv


DEFAULT_ZIP_PATH = Path("/private/tmp/nho-kompetansebarometer-2025-migreringspakke-20260526-141932.zip")
SOURCES_CSV_SUFFIX = "/data/normalized/all_sources_manifest.csv"
OBSERVATIONS_CSV_SUFFIX = "/data/normalized/all_observations_long.csv"
CHUNK_SIZE = 5000


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--zip-path", type=Path, default=DEFAULT_ZIP_PATH)
    parser.add_argument(
        "--replace-year",
        type=int,
        help="Delete and re-import one report year while preserving other years.",
    )
    parser.add_argument(
        "--reset-nho",
        action="store_true",
        help="Delete all imported NHO years before import. Use only for full rebuilds.",
    )
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if args.reset_nho and args.replace_year:
        parser.error("--reset-nho and --replace-year cannot be used together.")
    return args


def chunks(rows: list[dict[str, Any]], size: int = CHUNK_SIZE) -> Iterable[list[dict[str, Any]]]:
    for index in range(0, len(rows), size):
        yield rows[index : index + size]


def as_int(value: str | None) -> int | None:
    if value is None or value == "":
        return None
    return int(float(value))


def as_numeric(value: str | None) -> str | None:
    if value is None or value == "":
        return None
    return value.replace(",", ".")


def as_json_text(value: str | None, fallback: Any) -> str:
    if not value:
        return json.dumps(fallback, ensure_ascii=False)
    try:
        return json.dumps(json.loads(value), ensure_ascii=False)
    except json.JSONDecodeError:
        return json.dumps(fallback, ensure_ascii=False)


def observation_key(row: dict[str, str]) -> str:
    stable_fields = [
        "source_id",
        "sheet",
        "xlsx_row_number",
        "question",
        "subquestion",
        "breakdown_variable",
        "breakdown_value",
        "variable_name",
        "variable_label",
        "measure_name",
        "value_text",
        "dimensions_json",
    ]
    payload = json.dumps({field: row.get(field, "") for field in stable_fields}, sort_keys=True)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def find_package_file(zip_file: zipfile.ZipFile, suffix: str) -> str:
    matches = [name for name in zip_file.namelist() if name.endswith(suffix)]
    if len(matches) != 1:
        raise FileNotFoundError(f"Expected exactly one *{suffix}, found {len(matches)}")
    return matches[0]


def open_csv(zip_file: zipfile.ZipFile, name: str) -> csv.DictReader:
    if name not in zip_file.namelist():
        raise FileNotFoundError(name)
    handle = zip_file.open(name)
    text = io.TextIOWrapper(handle, encoding="utf-8-sig", newline="")
    return csv.DictReader(text)


def source_row(row: dict[str, str]) -> dict[str, Any]:
    return {
        "source_id": row["source_id"],
        "year": as_int(row["year"]),
        "group_type": row.get("group") or None,
        "subgroup": row.get("subgroup") or None,
        "chapter": row.get("chapter") or None,
        "classification": row.get("classification") or None,
        "title": row.get("title") or None,
        "rows_including_header": as_int(row.get("rows_including_header")),
        "data_rows": as_int(row.get("data_rows")),
        "columns_count": as_int(row.get("columns")),
        "header": row.get("header") or None,
        "header_json": as_json_text(row.get("header_json"), []),
        "source_url": row.get("source_url") or None,
        "page_url": row.get("page_url") or None,
        "md5": row.get("md5") or None,
        "bytes": as_int(row.get("bytes")),
    }


def observation_row(row: dict[str, str]) -> dict[str, Any]:
    return {
        "observation_key": observation_key(row),
        "source_id": row["source_id"],
        "year": as_int(row["year"]),
        "group_type": row.get("group") or None,
        "subgroup": row.get("subgroup") or None,
        "chapter": row.get("chapter") or None,
        "classification": row.get("classification") or None,
        "page_url": row.get("page_url") or None,
        "source_url": row.get("source_url") or None,
        "source_file": row.get("source_file") or None,
        "sheet": row.get("sheet") or None,
        "xlsx_row_number": as_int(row.get("xlsx_row_number")),
        "question": row.get("question") or None,
        "subquestion": row.get("subquestion") or None,
        "breakdown_variable": row.get("breakdown_variable") or None,
        "breakdown_value": row.get("breakdown_value") or None,
        "variable_name": row.get("variable_name") or None,
        "variable_label": row.get("variable_label") or None,
        "measure_name": row.get("measure_name") or None,
        "value_text": row.get("value_text") or None,
        "value_numeric": as_numeric(row.get("value_numeric")),
        "dimensions": as_json_text(row.get("dimensions_json"), {}),
    }


def reset_nho(conn: Any) -> None:
    with conn.cursor() as cur:
        cur.execute(
            """
            truncate table
              public.nho_kb_observations,
              public.nho_kb_sources
            restart identity cascade
            """
        )
    conn.commit()


def replace_year(conn: Any, year: int) -> None:
    with conn.cursor() as cur:
        cur.execute("delete from public.nho_kb_observations where year = %s", (year,))
        cur.execute("delete from public.nho_kb_sources where year = %s", (year,))
    conn.commit()


def import_sources(conn: Any, rows: list[dict[str, Any]]) -> None:
    with conn.cursor() as cur:
        cur.executemany(
            """
            insert into public.nho_kb_sources (
              source_id, year, group_type, subgroup, chapter, classification,
              title, rows_including_header, data_rows, columns_count, header,
              header_json, source_url, page_url, md5, bytes, imported_at
            )
            values (
              %(source_id)s, %(year)s, %(group_type)s, %(subgroup)s, %(chapter)s,
              %(classification)s, %(title)s, %(rows_including_header)s,
              %(data_rows)s, %(columns_count)s, %(header)s, %(header_json)s::jsonb,
              %(source_url)s, %(page_url)s, %(md5)s, %(bytes)s, now()
            )
            on conflict (source_id) do update set
              year = excluded.year,
              group_type = excluded.group_type,
              subgroup = excluded.subgroup,
              chapter = excluded.chapter,
              classification = excluded.classification,
              title = excluded.title,
              rows_including_header = excluded.rows_including_header,
              data_rows = excluded.data_rows,
              columns_count = excluded.columns_count,
              header = excluded.header,
              header_json = excluded.header_json,
              source_url = excluded.source_url,
              page_url = excluded.page_url,
              md5 = excluded.md5,
              bytes = excluded.bytes,
              imported_at = now()
            """,
            rows,
        )
    conn.commit()


def import_observations(conn: Any, rows: list[dict[str, Any]]) -> None:
    statement = """
        insert into public.nho_kb_observations (
          observation_key, source_id, year, group_type, subgroup, chapter,
          classification, page_url, source_url, source_file, sheet,
          xlsx_row_number, question, subquestion, breakdown_variable,
          breakdown_value, variable_name, variable_label, measure_name,
          value_text, value_numeric, dimensions, imported_at
        )
        values (
          %(observation_key)s, %(source_id)s, %(year)s, %(group_type)s,
          %(subgroup)s, %(chapter)s, %(classification)s, %(page_url)s,
          %(source_url)s, %(source_file)s, %(sheet)s, %(xlsx_row_number)s,
          %(question)s, %(subquestion)s, %(breakdown_variable)s,
          %(breakdown_value)s, %(variable_name)s, %(variable_label)s,
          %(measure_name)s, %(value_text)s, %(value_numeric)s,
          %(dimensions)s::jsonb, now()
        )
        on conflict (observation_key) do update set
          source_id = excluded.source_id,
          year = excluded.year,
          group_type = excluded.group_type,
          subgroup = excluded.subgroup,
          chapter = excluded.chapter,
          classification = excluded.classification,
          page_url = excluded.page_url,
          source_url = excluded.source_url,
          source_file = excluded.source_file,
          sheet = excluded.sheet,
          xlsx_row_number = excluded.xlsx_row_number,
          question = excluded.question,
          subquestion = excluded.subquestion,
          breakdown_variable = excluded.breakdown_variable,
          breakdown_value = excluded.breakdown_value,
          variable_name = excluded.variable_name,
          variable_label = excluded.variable_label,
          measure_name = excluded.measure_name,
          value_text = excluded.value_text,
          value_numeric = excluded.value_numeric,
          dimensions = excluded.dimensions,
          imported_at = now()
    """
    with conn.cursor() as cur:
        for batch in chunks(rows):
            cur.executemany(statement, batch)
    conn.commit()


def update_import_metadata(conn: Any, source_rows: list[dict[str, Any]], observation_count: int, package_name: str) -> None:
    imported_years = sorted({row["year"] for row in source_rows if row.get("year") is not None})
    with conn.cursor() as cur:
        cur.execute(
            """
            select coalesce(array_agg(year order by year), '{}'::integer[])
            from (
              select distinct year
              from public.nho_kb_sources
            ) years
            """
        )
        available_years = list(cur.fetchone()[0] or [])
        cur.execute("select max(year) from public.nho_kb_sources")
        latest_year = cur.fetchone()[0]
        cur.execute(
            """
            update public.external_data_sources
            set imported_at = now(),
                version = coalesce(%s::text, version),
                metadata = metadata
                  || jsonb_build_object(
                    'status', 'imported',
                    'latest_year', %s::integer,
                    'available_years', %s::jsonb,
                    'last_import', jsonb_build_object(
                      'package', %s::text,
                      'years', %s::jsonb,
                      'source_count', %s::integer,
                      'observation_count', %s::integer,
                      'imported_at', now()
                    )
                  )
            where source_key = 'nho_kompetansebarometeret'
            """,
            (
                str(latest_year) if latest_year is not None else None,
                latest_year,
                json.dumps(available_years),
                package_name,
                json.dumps(imported_years),
                len(source_rows),
                observation_count,
            ),
        )
    conn.commit()


def main() -> int:
    args = parse_args()
    zip_path = args.zip_path.expanduser()
    if not zip_path.exists():
        print(f"NHO package not found: {zip_path}", file=sys.stderr)
        return 2

    with zipfile.ZipFile(zip_path) as zip_file:
        sources_csv = find_package_file(zip_file, SOURCES_CSV_SUFFIX)
        observations_csv = find_package_file(zip_file, OBSERVATIONS_CSV_SUFFIX)
        source_rows = [source_row(row) for row in open_csv(zip_file, sources_csv)]
        observation_rows: list[dict[str, Any]] = []
        for row in open_csv(zip_file, observations_csv):
            observation_rows.append(observation_row(row))

    imported_years = sorted({row["year"] for row in source_rows if row.get("year") is not None})
    print(f"NHO sources: {len(source_rows)}")
    print(f"NHO observations: {len(observation_rows)}")
    print(f"NHO years in package: {', '.join(str(year) for year in imported_years)}")
    if not source_rows or not observation_rows:
        print("Package did not contain expected normalized CSV rows.", file=sys.stderr)
        return 2
    if args.replace_year and imported_years != [args.replace_year]:
        print(
            f"--replace-year {args.replace_year} does not match package years {imported_years}",
            file=sys.stderr,
        )
        return 2

    if args.dry_run:
        return 0

    load_dotenv(dotenv_path=".env")
    database_url = os.getenv("DATABASE_URL")
    if not database_url:
        print("DATABASE_URL is required. Put it in .env or export it.", file=sys.stderr)
        return 2

    import psycopg

    with psycopg.connect(database_url) as conn:
        if args.reset_nho:
            reset_nho(conn)
        if args.replace_year:
            replace_year(conn, args.replace_year)
        import_sources(conn, source_rows)
        import_observations(conn, observation_rows)
        update_import_metadata(conn, source_rows, len(observation_rows), zip_path.name)

    print("NHO Kompetansebarometer imported.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

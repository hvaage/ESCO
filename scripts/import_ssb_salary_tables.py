#!/usr/bin/env python3
"""Import SSB salary tables used by market-capacity signals."""

from __future__ import annotations

import argparse
import hashlib
import itertools
import json
import os
import sys
from pathlib import Path
from typing import Any, Iterable
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from dotenv import load_dotenv


SSB_API_BASE = "https://data.ssb.no/api/v0/no/table"
DEFAULT_TABLE = "11418"
CHUNK_SIZE = 2000
STATISTIC_VALUES = ["02", "01", "051", "061", "10"]
SECTOR_VALUES = ["ALLE", "A+B+D+E", "6500", "6100"]
GENDER_VALUES = ["0", "2", "1"]
WORKING_TIME_11418_VALUES = ["0"]
WORKING_TIME_VALUES = ["0", "5", "6"]
SALARY_CONTENT_VALUES = ["Manedslonn"]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--table-id",
        default=DEFAULT_TABLE,
        help="SSB table to import. v1 is tested with 11418.",
    )
    parser.add_argument(
        "--year",
        help="Year to import. Defaults to latest year available in SSB metadata.",
    )
    parser.add_argument(
        "--all-years",
        action="store_true",
        help="Import every available year for the selected table.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Fetch and validate without writing to Postgres.",
    )
    args = parser.parse_args()
    if args.year and args.all_years:
        parser.error("--year and --all-years cannot be used together.")
    return args


def chunks(rows: list[dict[str, Any]], size: int = CHUNK_SIZE) -> Iterable[list[dict[str, Any]]]:
    for index in range(0, len(rows), size):
        yield rows[index : index + size]


def request_json(url: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
    data = None
    headers = {"User-Agent": "karrierenmin-data-import/1.0"}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = Request(url, data=data, headers=headers)
    try:
        with urlopen(request, timeout=60) as response:
            return json.loads(response.read().decode("utf-8"))
    except HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"SSB API error {exc.code}: {body[:500]}") from exc


def variable(metadata: dict[str, Any], code: str) -> dict[str, Any]:
    for item in metadata.get("variables") or []:
        if item.get("code") == code:
            return item
    raise KeyError(f"SSB table metadata has no variable {code!r}")


def variable_values(metadata: dict[str, Any], code: str) -> list[str]:
    return list(variable(metadata, code).get("values") or [])


def latest_year(metadata: dict[str, Any]) -> str:
    years = [value for value in variable_values(metadata, "Tid") if value.isdigit()]
    if not years:
        raise ValueError("No plain year values found in SSB Tid dimension")
    return max(years)


def four_digit_occupations(metadata: dict[str, Any]) -> list[str]:
    return [
        value
        for value in variable_values(metadata, "Yrke")
        if len(value) == 4 and value.isdigit() and value != "0000"
    ]


def all_values(metadata: dict[str, Any], code: str) -> list[str]:
    return variable_values(metadata, code)


def selected_values(metadata: dict[str, Any], code: str, preferred: list[str]) -> list[str]:
    available = set(variable_values(metadata, code))
    return [value for value in preferred if value in available]


def selected_nace_values(metadata: dict[str, Any]) -> list[str]:
    return [
        value
        for value in all_values(metadata, "NACE2007")
        if value not in {"00", "Ialt"}
    ]


def build_query(metadata: dict[str, Any], years: list[str]) -> dict[str, Any]:
    table_id = metadata.get("id")
    if table_id not in {"11418", "11420", "11421"}:
        raise ValueError("This importer currently supports SSB tables 11418, 11420 and 11421.")

    if table_id == "11418":
        query = [
            {
                "code": "MaaleMetode",
                "selection": {"filter": "item", "values": selected_values(metadata, "MaaleMetode", STATISTIC_VALUES[:4])},
            },
            {
                "code": "Yrke",
                "selection": {"filter": "item", "values": four_digit_occupations(metadata)},
            },
            {
                "code": "Sektor",
                "selection": {"filter": "item", "values": selected_values(metadata, "Sektor", SECTOR_VALUES)},
            },
            {"code": "Kjonn", "selection": {"filter": "item", "values": ["0"]}},
            {"code": "AvtaltVanlig", "selection": {"filter": "item", "values": WORKING_TIME_11418_VALUES}},
            {"code": "ContentsCode", "selection": {"filter": "item", "values": SALARY_CONTENT_VALUES}},
            {"code": "Tid", "selection": {"filter": "item", "values": years}},
        ]
    elif table_id == "11420":
        query = [
            {
                "code": "MaaleMetode",
                "selection": {"filter": "item", "values": selected_values(metadata, "MaaleMetode", STATISTIC_VALUES)},
            },
            {
                "code": "Sektor",
                "selection": {"filter": "item", "values": selected_values(metadata, "Sektor", SECTOR_VALUES)},
            },
            {
                "code": "UtdanNivaa",
                "selection": {"filter": "item", "values": all_values(metadata, "UtdanNivaa")},
            },
            {
                "code": "NACE2007",
                "selection": {"filter": "item", "values": selected_nace_values(metadata)},
            },
            {
                "code": "Kjonn",
                "selection": {"filter": "item", "values": selected_values(metadata, "Kjonn", GENDER_VALUES)},
            },
            {
                "code": "ArbeidsTid",
                "selection": {"filter": "item", "values": selected_values(metadata, "ArbeidsTid", WORKING_TIME_VALUES)},
            },
            {"code": "ContentsCode", "selection": {"filter": "item", "values": SALARY_CONTENT_VALUES}},
            {"code": "Tid", "selection": {"filter": "item", "values": years}},
        ]
    else:
        query = [
            {
                "code": "MaaleMetode",
                "selection": {"filter": "item", "values": selected_values(metadata, "MaaleMetode", STATISTIC_VALUES)},
            },
            {
                "code": "Sektor",
                "selection": {"filter": "item", "values": selected_values(metadata, "Sektor", SECTOR_VALUES)},
            },
            {
                "code": "NACE2007",
                "selection": {"filter": "item", "values": selected_nace_values(metadata)},
            },
            {
                "code": "Alder",
                "selection": {"filter": "item", "values": all_values(metadata, "Alder")},
            },
            {
                "code": "Kjonn",
                "selection": {"filter": "item", "values": selected_values(metadata, "Kjonn", GENDER_VALUES)},
            },
            {
                "code": "ArbeidsTid",
                "selection": {"filter": "item", "values": selected_values(metadata, "ArbeidsTid", WORKING_TIME_VALUES)},
            },
            {"code": "ContentsCode", "selection": {"filter": "item", "values": SALARY_CONTENT_VALUES}},
            {"code": "Tid", "selection": {"filter": "item", "values": years}},
        ]

    return {
        "query": query,
        "response": {"format": "JSON-stat2"},
    }


def ordered_codes(dimension: dict[str, Any]) -> list[str]:
    category = dimension.get("category") or {}
    labels = category.get("label") or {}
    index = category.get("index") or {}
    if isinstance(index, dict):
        return [code for code, _ in sorted(index.items(), key=lambda item: item[1])]
    if isinstance(index, list):
        return [code for code, _ in sorted(zip(labels.keys(), index), key=lambda item: item[1])]
    return list(labels.keys())


def metric_unit(payload: dict[str, Any], metric_code: str | None) -> str | None:
    if not metric_code:
        return None
    metric_dimensions = (payload.get("role") or {}).get("metric") or []
    for dimension_id in metric_dimensions:
        dimension = (payload.get("dimension") or {}).get(dimension_id) or {}
        unit = ((dimension.get("category") or {}).get("unit") or {}).get(metric_code) or {}
        if unit.get("base"):
            return unit["base"]
    return None


def flatten_dataset(table_id: str, payload: dict[str, Any], source_file: str) -> list[dict[str, Any]]:
    dimension_ids = payload["id"]
    dimensions = payload["dimension"]
    values = payload.get("value") or []
    time_dimensions = (payload.get("role") or {}).get("time") or ["Tid"]
    time_dimension = time_dimensions[0] if time_dimensions else "Tid"
    codes_by_dimension = [ordered_codes(dimensions[dimension_id]) for dimension_id in dimension_ids]

    expected_values = 1
    for size in payload["size"]:
        expected_values *= int(size)
    if expected_values != len(values):
        raise ValueError(f"Expected {expected_values} values from dimensions, found {len(values)}")

    rows: list[dict[str, Any]] = []
    for value_index, code_tuple in enumerate(itertools.product(*codes_by_dimension)):
        dimension_codes = dict(zip(dimension_ids, code_tuple))
        dimension_labels = {
            dimension_id: (
                ((dimensions[dimension_id].get("category") or {}).get("label") or {}).get(code)
                or code
            )
            for dimension_id, code in dimension_codes.items()
        }
        metric_code = dimension_codes.get("ContentsCode")
        metric_label = dimension_labels.get("ContentsCode")
        dimension_json = json.dumps(dimension_codes, ensure_ascii=False, sort_keys=True)
        rows.append(
            {
                "table_id": table_id,
                "source_file": source_file,
                "period": dimension_codes.get(time_dimension),
                "metric_code": metric_code,
                "metric_label": metric_label,
                "value": values[value_index],
                "unit": metric_unit(payload, metric_code),
                "dimension_codes": dimension_json,
                "dimension_labels": json.dumps(dimension_labels, ensure_ascii=False, sort_keys=True),
                "dimension_key": hashlib.sha256(dimension_json.encode("utf-8")).hexdigest(),
                "raw_dimension": "{}",
            }
        )
    return rows


def import_metadata(conn: Any, table_id: str, metadata: dict[str, Any], selected_years: list[str]) -> None:
    with conn.cursor() as cur:
        cur.execute(
            """
            insert into public.ssb_table_metadata (
              table_id, title, source, source_url, latest_period, metadata, imported_at
            )
            values (%s, %s, %s, %s, %s, %s::jsonb, now())
            on conflict (table_id) do update set
              title = excluded.title,
              source = excluded.source,
              source_url = excluded.source_url,
              latest_period = greatest(public.ssb_table_metadata.latest_period, excluded.latest_period),
              metadata = excluded.metadata,
              imported_at = now()
            """,
            (
                table_id,
                metadata.get("title") or f"SSB table {table_id}",
                "Statistisk sentralbyrå",
                f"{SSB_API_BASE}/{table_id}",
                max(selected_years),
                json.dumps(metadata, ensure_ascii=False),
            ),
        )
    conn.commit()


def import_observations(conn: Any, rows: list[dict[str, Any]]) -> None:
    statement = """
        insert into public.ssb_observations (
          table_id, source_file, period, metric_code, metric_label, value, unit,
          dimension_codes, dimension_labels, dimension_key, raw_dimension, imported_at
        )
        values (
          %(table_id)s, %(source_file)s, %(period)s, %(metric_code)s,
          %(metric_label)s, %(value)s, %(unit)s, %(dimension_codes)s::jsonb,
          %(dimension_labels)s::jsonb, %(dimension_key)s, %(raw_dimension)s::jsonb, now()
        )
        on conflict (table_id, dimension_key) do update set
          source_file = excluded.source_file,
          period = excluded.period,
          metric_code = excluded.metric_code,
          metric_label = excluded.metric_label,
          value = excluded.value,
          unit = excluded.unit,
          dimension_codes = excluded.dimension_codes,
          dimension_labels = excluded.dimension_labels,
          raw_dimension = excluded.raw_dimension,
          imported_at = now()
    """
    with conn.cursor() as cur:
        for batch in chunks(rows):
            cur.executemany(statement, batch)
    conn.commit()


def update_external_source(conn: Any, table_id: str, years: list[str], row_count: int) -> None:
    with conn.cursor() as cur:
        cur.execute(
            """
            update public.external_data_sources
            set imported_at = now(),
                version = %s::text,
                metadata = metadata || jsonb_build_object(
                  'import_status', 'imported',
                  'latest_year', %s::text,
                  'last_import', jsonb_build_object(
                    'table_id', %s::text,
                    'years', %s::jsonb,
                    'observation_count', %s::integer,
                    'imported_at', now()
                  )
                )
            where source_key = 'ssb_salary_tables'
            """,
            (
                max(years),
                max(years),
                table_id,
                json.dumps(years),
                row_count,
            ),
        )
    conn.commit()


def refresh_market_capacity(conn: Any) -> None:
    with conn.cursor() as cur:
        cur.execute("select to_regclass('public.mv_styrk_market_capacity')")
        if cur.fetchone()[0] is not None:
            cur.execute("refresh materialized view public.mv_styrk_market_capacity")
    conn.commit()


def main() -> int:
    args = parse_args()
    metadata = request_json(f"{SSB_API_BASE}/{args.table_id}")
    metadata["id"] = args.table_id
    if args.all_years:
        years = [value for value in variable_values(metadata, "Tid") if value.isdigit()]
    else:
        years = [args.year or latest_year(metadata)]
    query = build_query(metadata, years)
    payload = request_json(f"{SSB_API_BASE}/{args.table_id}", query)
    source_file = f"ssb_api_{args.table_id}_{'_'.join(years)}.jsonstat"
    rows = flatten_dataset(args.table_id, payload, source_file)
    print(f"SSB table {args.table_id}: {metadata.get('title')}")
    print(f"Years: {', '.join(years)}")
    print(f"Observations: {len(rows)}")

    if args.dry_run:
        return 0

    load_dotenv(dotenv_path=".env")
    database_url = os.getenv("DATABASE_URL")
    if not database_url:
        print("DATABASE_URL is required. Put it in .env or export it.", file=sys.stderr)
        return 2

    import psycopg

    with psycopg.connect(database_url) as conn:
        import_metadata(conn, args.table_id, metadata, years)
        import_observations(conn, rows)
        update_external_source(conn, args.table_id, years, len(rows))
        refresh_market_capacity(conn)

    print("SSB salary table imported.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

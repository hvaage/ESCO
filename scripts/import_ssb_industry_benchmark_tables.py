#!/usr/bin/env python3
"""Import selected SSB industry benchmark tables for company analytics.

The importer stores observations in the shared public.ssb_* tables that already
back NAV/SSB market data. Default runs import only the latest available year;
use --all-years deliberately for historical backfills.
"""

from __future__ import annotations

import argparse
import hashlib
import itertools
import json
import os
import sys
from dataclasses import dataclass
from typing import Any, Callable, Iterable
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from dotenv import load_dotenv


SSB_API_BASE = "https://data.ssb.no/api/v0/no/table"
CHUNK_SIZE = 2000
WRITE_CHUNK_SIZE = 10000
SOURCE_KEY = "ssb_industry_benchmark_tables"
DEFAULT_TABLE_IDS = [
    "NokkelASAlle",
    "RegnResultASAlle",
    "RegnBalansASAlle",
    "Foretak03",
    "Foretak05",
    "Foretak18",
    "Fordem10",
]


@dataclass(frozen=True)
class TableConfig:
    description: str
    dimension_selector: Callable[[dict[str, Any], list[str]], dict[str, list[str]]]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--table-id",
        action="append",
        choices=DEFAULT_TABLE_IDS,
        help="SSB table to import. May be repeated. Defaults to all phase-1 tables.",
    )
    parser.add_argument(
        "--year",
        help="Year to import. Defaults to latest year available in SSB metadata.",
    )
    parser.add_argument(
        "--all-years",
        action="store_true",
        help="Import every available year for selected tables.",
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
    headers = {"User-Agent": "suverra-ssb-industry-import/1.0"}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = Request(url, data=data, headers=headers)
    try:
        with urlopen(request, timeout=120) as response:
            return json.loads(response.read().decode("utf-8"))
    except HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"SSB API error {exc.code}: {body[:700]}") from exc


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


def all_values(metadata: dict[str, Any], code: str) -> list[str]:
    return variable_values(metadata, code)


def selected_values(metadata: dict[str, Any], code: str, preferred: list[str]) -> list[str]:
    available = set(variable_values(metadata, code))
    return [value for value in preferred if value in available]


def require_selected(metadata: dict[str, Any], code: str, preferred: list[str]) -> list[str]:
    values = selected_values(metadata, code, preferred)
    if not values:
        raise ValueError(f"No configured values for {code} found in SSB metadata. Wanted {preferred}")
    return values


def selected_regions(metadata: dict[str, Any]) -> list[str]:
    values = variable_values(metadata, "Region")
    return [
        value
        for value in values
        if value == "0N" or (len(value) == 2 and value.isdigit())
    ]


def select_accounting_table(metadata: dict[str, Any], years: list[str]) -> dict[str, list[str]]:
    return {
        "NACE2007": all_values(metadata, "NACE2007"),
        "ContentsCode": all_values(metadata, "ContentsCode"),
        "Tid": years,
    }


def select_foretak03(metadata: dict[str, Any], years: list[str]) -> dict[str, list[str]]:
    return {
        "NACE2007": all_values(metadata, "NACE2007"),
        "ForetakVer": require_selected(metadata, "ForetakVer", ["akt", "reg"]),
        "Storleik": all_values(metadata, "Storleik"),
        "ContentsCode": all_values(metadata, "ContentsCode"),
        "Tid": years,
    }


def select_foretak05(metadata: dict[str, Any], years: list[str]) -> dict[str, list[str]]:
    return {
        "NACE2007": all_values(metadata, "NACE2007"),
        "ForetakVer": require_selected(metadata, "ForetakVer", ["akt"]),
        "OrgFormer": require_selected(metadata, "OrgFormer", ["0", "AS", "ASA", "AS+ASA"]),
        "Sektor": require_selected(metadata, "Sektor", ["ALLE", "0"]),
        "Storleik": all_values(metadata, "Storleik"),
        "ContentsCode": all_values(metadata, "ContentsCode"),
        "Tid": years,
    }


def select_foretak18(metadata: dict[str, Any], years: list[str]) -> dict[str, list[str]]:
    return {
        "Region": selected_regions(metadata),
        "NACE2007": all_values(metadata, "NACE2007"),
        "OrgFormer": require_selected(metadata, "OrgFormer", ["0", "AS+ASA", "AS", "ASA"]),
        "ForetakVer": require_selected(metadata, "ForetakVer", ["akt"]),
        "Storleik": all_values(metadata, "Storleik"),
        "ContentsCode": all_values(metadata, "ContentsCode"),
        "Tid": years,
    }


def select_fordem10(metadata: dict[str, Any], years: list[str]) -> dict[str, list[str]]:
    return {
        "ForetakType": all_values(metadata, "ForetakType"),
        "StorleikStartAar": all_values(metadata, "StorleikStartAar"),
        "Vekst2": all_values(metadata, "Vekst2"),
        "NACE2007": all_values(metadata, "NACE2007"),
        "ContentsCode": all_values(metadata, "ContentsCode"),
        "Tid": years,
    }


TABLE_CONFIGS: dict[str, TableConfig] = {
    "NokkelASAlle": TableConfig(
        "Industry key ratios for non-financial limited companies",
        select_accounting_table,
    ),
    "RegnResultASAlle": TableConfig(
        "Industry result-statement posts for limited companies",
        select_accounting_table,
    ),
    "RegnBalansASAlle": TableConfig(
        "Industry balance-sheet posts for limited companies",
        select_accounting_table,
    ),
    "Foretak03": TableConfig(
        "Enterprises by industry, version and size",
        select_foretak03,
    ),
    "Foretak05": TableConfig(
        "Enterprises by industry, organisation form, sector and size",
        select_foretak05,
    ),
    "Foretak18": TableConfig(
        "Enterprises by region, industry, organisation form and size",
        select_foretak18,
    ),
    "Fordem10": TableConfig(
        "High-growth enterprises and gazelles by industry and growth type",
        select_fordem10,
    ),
}


def build_query(table_id: str, metadata: dict[str, Any], years: list[str]) -> dict[str, Any]:
    dimensions = TABLE_CONFIGS[table_id].dimension_selector(metadata, years)
    query = []
    for item in metadata.get("variables") or []:
        code = item["code"]
        if code not in dimensions:
            raise ValueError(f"No selector configured for dimension {code!r} in table {table_id}")
        values = dimensions[code]
        if not values:
            raise ValueError(f"Selector for dimension {code!r} in table {table_id} returned no values")
        query.append({"code": code, "selection": {"filter": "item", "values": values}})
    return {"query": query, "response": {"format": "JSON-stat2"}}


def selected_years(metadata: dict[str, Any], args: argparse.Namespace) -> list[str]:
    if args.all_years:
        return [value for value in variable_values(metadata, "Tid") if value.isdigit()]
    return [args.year or latest_year(metadata)]


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


def import_metadata(conn: Any, table_id: str, metadata: dict[str, Any], years: list[str]) -> None:
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
                "Statistisk sentralbyra",
                f"{SSB_API_BASE}/{table_id}",
                max(years),
                json.dumps(metadata, ensure_ascii=False),
            ),
        )
    conn.commit()


def import_observations(conn: Any, rows: list[dict[str, Any]]) -> None:
    for batch in chunks(rows, WRITE_CHUNK_SIZE):
        with conn.cursor() as cur:
            cur.execute(
                """
                create temporary table tmp_ssb_observations (
                  table_id text not null,
                  source_file text not null,
                  period text,
                  metric_code text,
                  metric_label text,
                  value numeric,
                  unit text,
                  dimension_codes jsonb not null,
                  dimension_labels jsonb not null,
                  dimension_key text not null,
                  raw_dimension jsonb not null
                ) on commit drop
                """
            )
            with cur.copy(
                """
                copy tmp_ssb_observations (
                  table_id, source_file, period, metric_code, metric_label, value, unit,
                  dimension_codes, dimension_labels, dimension_key, raw_dimension
                ) from stdin
                """
            ) as copy:
                for row in batch:
                    copy.write_row(
                        (
                            row["table_id"],
                            row["source_file"],
                            row["period"],
                            row["metric_code"],
                            row["metric_label"],
                            row["value"],
                            row["unit"],
                            row["dimension_codes"],
                            row["dimension_labels"],
                            row["dimension_key"],
                            row["raw_dimension"],
                        )
                    )

            cur.execute(
                """
            insert into public.ssb_observations (
              table_id, source_file, period, metric_code, metric_label, value, unit,
              dimension_codes, dimension_labels, dimension_key, raw_dimension, imported_at
            )
            select
              table_id, source_file, period, metric_code, metric_label, value, unit,
              dimension_codes, dimension_labels, dimension_key, raw_dimension, now()
            from tmp_ssb_observations
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
            )
        conn.commit()


def upsert_external_source(conn: Any, table_id: str, years: list[str], row_count: int) -> None:
    with conn.cursor() as cur:
        cur.execute(
            """
            insert into public.external_data_sources (
              source_key, provider, title, source_url, version, license, imported_at, metadata
            )
            values (
              %s,
              'SSB',
              'SSB industry benchmark tables for company analytics',
              'https://www.ssb.no/',
              %s,
              'Norwegian Licence for Open Government Data (NLOD)',
              now(),
              jsonb_build_object(
                'import_status', 'imported',
                'update_frequency', 'monthly check; tables are mostly annual',
                'tables', %s::jsonb,
                'latest_year', %s::text,
                'last_import', jsonb_build_object(
                  'table_id', %s::text,
                  'years', %s::jsonb,
                  'observation_count', %s::integer,
                  'imported_at', now()
                )
              )
            )
            on conflict (source_key) do update set
              provider = excluded.provider,
              title = excluded.title,
              source_url = excluded.source_url,
              version = greatest(public.external_data_sources.version, excluded.version),
              license = excluded.license,
              imported_at = now(),
              metadata = jsonb_set(
                public.external_data_sources.metadata || excluded.metadata,
                '{latest_year}',
                to_jsonb(greatest(
                  coalesce(nullif(public.external_data_sources.metadata->>'latest_year', ''), '0'),
                  coalesce(nullif(excluded.metadata->>'latest_year', ''), '0')
                )),
                true
              )
            """,
            (
                SOURCE_KEY,
                max(years),
                json.dumps(DEFAULT_TABLE_IDS),
                max(years),
                table_id,
                json.dumps(years),
                row_count,
            ),
        )
    conn.commit()


def import_table(table_id: str, args: argparse.Namespace, conn: Any | None) -> int:
    metadata = request_json(f"{SSB_API_BASE}/{table_id}")
    metadata["id"] = table_id
    years = selected_years(metadata, args)
    query = build_query(table_id, metadata, years)
    payload = request_json(f"{SSB_API_BASE}/{table_id}", query)
    source_file = f"ssb_api_{table_id}_{'_'.join(years)}.jsonstat"
    rows = flatten_dataset(table_id, payload, source_file)

    print(f"SSB table {table_id}: {metadata.get('title')}", flush=True)
    print(f"Years: {', '.join(years)}", flush=True)
    print(f"Observations: {len(rows)}", flush=True)

    if conn is not None:
        import_metadata(conn, table_id, metadata, years)
        import_observations(conn, rows)
        upsert_external_source(conn, table_id, years, len(rows))

    return len(rows)


def main() -> int:
    args = parse_args()
    table_ids = args.table_id or DEFAULT_TABLE_IDS

    conn = None
    if not args.dry_run:
        load_dotenv(dotenv_path=".env")
        database_url = os.getenv("DATABASE_URL")
        if not database_url:
            print("DATABASE_URL is required. Put it in .env or export it.", file=sys.stderr)
            return 2

        import psycopg

        conn = psycopg.connect(database_url)

    total_rows = 0
    try:
        for table_id in table_ids:
            total_rows += import_table(table_id, args, conn)
    finally:
        if conn is not None:
            conn.close()

    verb = "validated" if args.dry_run else "imported"
    print(f"SSB industry benchmark tables {verb}: {len(table_ids)} tables, {total_rows} observations.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

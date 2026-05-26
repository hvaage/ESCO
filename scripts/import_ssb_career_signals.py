#!/usr/bin/env python3
"""Import SSB JSON-stat2 tables used by the public career compass."""

from __future__ import annotations

import argparse
import hashlib
import itertools
import json
import os
import re
import sys
from pathlib import Path
from typing import Any, Iterable

from dotenv import load_dotenv


DEFAULT_SOURCE_DIR = Path("data/raw/ssb")
CHUNK_SIZE = 2000


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--source-dir",
        type=Path,
        default=DEFAULT_SOURCE_DIR,
        help="Directory containing SSB JSON-stat2 dataset files and metadata.",
    )
    parser.add_argument(
        "--reset-ssb",
        action="store_true",
        help="Delete existing SSB observations and table metadata before import.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Read and validate files without writing to Postgres.",
    )
    return parser.parse_args()


def chunks(rows: list[dict[str, Any]], size: int = CHUNK_SIZE) -> Iterable[list[dict[str, Any]]]:
    for index in range(0, len(rows), size):
        yield rows[index : index + size]


def load_json(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        parsed = json.load(handle)
    if not isinstance(parsed, dict):
        raise ValueError(f"{path} is not a JSON object")
    return parsed


def is_dataset(payload: dict[str, Any]) -> bool:
    return all(key in payload for key in ("id", "size", "dimension", "value"))


def table_id_from_path(path: Path) -> str:
    match = re.match(r"^(\d+)_", path.name)
    if not match:
        raise ValueError(f"Could not infer SSB table id from {path.name}")
    return match.group(1)


def dataset_files(source_dir: Path) -> list[Path]:
    files: list[Path] = []
    for path in sorted(source_dir.glob("*.json")):
        if any(marker in path.name for marker in ("metadata", "sample")):
            continue
        try:
            payload = load_json(path)
        except json.JSONDecodeError:
            continue
        if is_dataset(payload):
            files.append(path)
    return files


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
    contents = (payload.get("dimension") or {}).get("ContentsCode") or {}
    unit = ((contents.get("category") or {}).get("unit") or {}).get(metric_code) or {}
    return unit.get("base")


def table_metadata(source_dir: Path, table_id: str, payload: dict[str, Any]) -> dict[str, Any]:
    metadata_payload: dict[str, Any] = {}
    for suffix in ("basic_metadata", "metadata"):
        path = source_dir / f"{table_id}_{suffix}.json"
        if path.exists():
            metadata_payload = load_json(path)
            break

    title = (
        metadata_payload.get("title")
        or metadata_payload.get("label")
        or payload.get("label")
        or f"SSB table {table_id}"
    )
    source = metadata_payload.get("source") or payload.get("source") or "Statistisk sentralbyrå"
    url = metadata_payload.get("source_url") or metadata_payload.get("url")
    periods = []
    time_dimension = ((payload.get("role") or {}).get("time") or ["Tid"])[0]
    time_meta = (payload.get("dimension") or {}).get(time_dimension) or {}
    for code in ordered_codes(time_meta):
        if re.match(r"^[0-9]{4}$", code):
            periods.append(code)

    return {
        "table_id": table_id,
        "title": title,
        "source": source,
        "source_url": url,
        "latest_period": max(periods) if periods else None,
        "metadata": json.dumps(metadata_payload or payload, ensure_ascii=False),
    }


def flatten_dataset(path: Path, payload: dict[str, Any]) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    source_dir = path.parent
    table_id = table_id_from_path(path)
    metadata = table_metadata(source_dir, table_id, payload)
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
        raise ValueError(
            f"{path.name}: expected {expected_values} values from dimensions, found {len(values)}"
        )

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
                "source_file": path.name,
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
    return metadata, rows


def reset_ssb(conn: psycopg.Connection) -> None:
    with conn.cursor() as cur:
        cur.execute(
            """
            truncate table
              public.ssb_observations,
              public.ssb_table_metadata
            restart identity cascade
            """
        )
    conn.commit()


def import_metadata(conn: psycopg.Connection, metadata_rows: list[dict[str, Any]]) -> None:
    with conn.cursor() as cur:
        cur.executemany(
            """
            insert into public.ssb_table_metadata (
              table_id, title, source, source_url, latest_period, metadata, imported_at
            )
            values (
              %(table_id)s, %(title)s, %(source)s, %(source_url)s,
              %(latest_period)s, %(metadata)s::jsonb, now()
            )
            on conflict (table_id) do update set
              title = excluded.title,
              source = excluded.source,
              source_url = excluded.source_url,
              latest_period = excluded.latest_period,
              metadata = excluded.metadata,
              imported_at = now()
            """,
            metadata_rows,
        )
    conn.commit()


def import_observations(conn: psycopg.Connection, rows: list[dict[str, Any]]) -> None:
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


def update_import_metadata(conn: psycopg.Connection) -> None:
    with conn.cursor() as cur:
        cur.execute(
            """
            select
              m.table_id,
              m.latest_period,
              count(o.id)::integer as observation_count,
              min(o.period_year) as first_year,
              max(o.period_year) as latest_year
            from public.ssb_table_metadata m
            left join public.ssb_observations o on o.table_id = m.table_id
            group by m.table_id, m.latest_period
            order by m.table_id
            """
        )
        table_stats = [
            {
                "table_id": table_id,
                "latest_period": latest_period,
                "observation_count": observation_count,
                "first_year": first_year,
                "latest_year": latest_year,
            }
            for table_id, latest_period, observation_count, first_year, latest_year in cur.fetchall()
        ]
        latest_years = [row["latest_year"] for row in table_stats if row["latest_year"] is not None]
        version = str(max(latest_years)) if latest_years else None
        cur.execute("select count(*)::integer from public.ssb_observations")
        observation_count = cur.fetchone()[0]
        cur.execute(
            """
            update public.external_data_sources
            set imported_at = now(),
                version = coalesce(%s::text, version),
                metadata = metadata
                  || jsonb_build_object(
                    'status', 'imported',
                    'tables', %s::jsonb,
                    'observation_count', %s::integer,
                    'table_stats', %s::jsonb,
                    'historical_policy',
                      'SSB observations are upserted by table_id and dimension_key so repeated annual exports update existing periods and add new periods without duplicating older observations.'
                  )
            where source_key = 'ssb_labor_market_tables'
            """,
            (
                version,
                json.dumps([row["table_id"] for row in table_stats]),
                observation_count,
                json.dumps(table_stats, ensure_ascii=False),
            ),
        )
    conn.commit()


def main() -> int:
    args = parse_args()
    source_dir = args.source_dir.expanduser()
    if not source_dir.exists():
        print(f"SSB source directory does not exist: {source_dir}", file=sys.stderr)
        return 2

    files = dataset_files(source_dir)
    if not files:
        print(f"No JSON-stat2 dataset files found in {source_dir}", file=sys.stderr)
        return 2

    all_metadata: dict[str, dict[str, Any]] = {}
    all_rows: list[dict[str, Any]] = []
    print(f"Reading {len(files)} SSB dataset files from {source_dir}")
    for path in files:
        payload = load_json(path)
        metadata, rows = flatten_dataset(path, payload)
        all_metadata[metadata["table_id"]] = metadata
        all_rows.extend(rows)
        print(f"{metadata['table_id']} {path.name}: {len(rows)} observations")

    print(f"Total SSB observations: {len(all_rows)}")
    if args.dry_run:
        return 0

    load_dotenv()
    database_url = os.getenv("DATABASE_URL")
    if not database_url:
        print("DATABASE_URL is required. Put it in .env or export it.", file=sys.stderr)
        return 2

    import psycopg

    with psycopg.connect(database_url) as conn:
        if args.reset_ssb:
            reset_ssb(conn)
        import_metadata(conn, list(all_metadata.values()))
        import_observations(conn, all_rows)
        update_import_metadata(conn)

    print("SSB career signals imported.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

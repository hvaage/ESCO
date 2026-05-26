#!/usr/bin/env python3
"""Import the generated ESCO v1.2.1 + STYRK/EURES CSV package into Supabase."""

from __future__ import annotations

import argparse
import csv
import json
import os
import sys
from pathlib import Path
from typing import Any, Iterable

import psycopg
from dotenv import load_dotenv


DEFAULT_DATA_DIR = Path("data/esco_import_v1_2_1")
CHUNK_SIZE = 1000


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-dir", type=Path, default=DEFAULT_DATA_DIR)
    parser.add_argument(
        "--reset-reference-data",
        action="store_true",
        help="Truncate ESCO/STYRK reference tables before importing.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Read and validate CSV files without writing to Postgres.",
    )
    return parser.parse_args()


def read_csv(data_dir: Path, name: str) -> list[dict[str, str]]:
    path = data_dir / f"{name}.csv"
    if not path.exists():
        raise FileNotFoundError(path)
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def chunks(rows: list[dict[str, Any]], size: int = CHUNK_SIZE) -> Iterable[list[dict[str, Any]]]:
    for index in range(0, len(rows), size):
        yield rows[index : index + size]


def as_json(value: str) -> dict[str, Any]:
    if not value:
        return {}
    parsed = json.loads(value)
    return parsed if isinstance(parsed, dict) else {"value": parsed}


def print_counts(dataset: dict[str, list[dict[str, str]]]) -> None:
    for name, rows in dataset.items():
        print(f"{name}: {len(rows)}")


def validate(dataset: dict[str, list[dict[str, str]]]) -> None:
    occupations = {row["uri"] for row in dataset["esco_occupations"]}
    skills = {row["uri"] for row in dataset["esco_skills"]}
    styrk_codes = {row["code"] for row in dataset["styrk08"]}

    missing_relation_occupations = sum(
        row["occupation_uri"] not in occupations for row in dataset["esco_occupation_skills"]
    )
    missing_relation_skills = sum(row["skill_uri"] not in skills for row in dataset["esco_occupation_skills"])
    missing_mapping_occupations = sum(
        row["occupation_uri"] not in occupations for row in dataset["esco_styrk_mappings"]
    )
    missing_mapping_styrk = sum(row["styrk_code"] not in styrk_codes for row in dataset["esco_styrk_mappings"])
    missing_alias_occupations = sum(
        row["occupation_uri"] not in occupations for row in dataset["esco_occupation_aliases"]
    )

    problems = {
        "missing_relation_occupations": missing_relation_occupations,
        "missing_relation_skills": missing_relation_skills,
        "missing_mapping_occupations": missing_mapping_occupations,
        "missing_mapping_styrk": missing_mapping_styrk,
        "missing_alias_occupations": missing_alias_occupations,
    }
    print(json.dumps(problems, indent=2))
    if any(problems.values()):
        raise ValueError("CSV package has broken references; refusing import.")


def reset_reference_data(conn: psycopg.Connection) -> None:
    with conn.cursor() as cur:
        cur.execute(
            """
            update public.job_skill_requirements
            set skill_uri = null
            where skill_uri is not null;

            update public.candidate_skill_claims
            set skill_uri = null
            where skill_uri is not null;

            update public.candidate_job_skill_gaps
            set skill_uri = null
            where skill_uri is not null;

            truncate table
              public.esco_occupation_aliases,
              public.esco_styrk_mappings,
              public.esco_occupation_skills,
              public.esco_labels,
              public.esco_data_versions
            restart identity;

            delete from public.esco_entities
            where entity_type in ('occupation', 'skill');

            truncate table public.styrk08 restart identity
            """
        )
    conn.commit()


def import_versions(conn: psycopg.Connection, rows: list[dict[str, str]]) -> None:
    with conn.cursor() as cur:
        cur.executemany(
            """
            insert into public.esco_data_versions (
              id, source, version, language, downloaded_at, metadata
            )
            values (
              %(id)s, %(source)s, %(version)s, %(language)s,
              %(downloaded_at)s, %(metadata)s::jsonb
            )
            on conflict (id) do update set
              source = excluded.source,
              version = excluded.version,
              language = excluded.language,
              downloaded_at = excluded.downloaded_at,
              metadata = excluded.metadata
            """,
            rows,
        )
    conn.commit()


def import_styrk(conn: psycopg.Connection, rows: list[dict[str, str]]) -> None:
    ordered = sorted(rows, key=lambda row: (int(row["level"]), row["code"]))
    with conn.cursor() as cur:
        cur.execute("set constraints all deferred")
        cur.executemany(
            """
            insert into public.styrk08 (code, parent_code, level, name, notes)
            values (%(code)s, nullif(%(parent_code)s, ''), %(level)s, %(name)s, nullif(%(notes)s, ''))
            on conflict (code) do update set
              parent_code = excluded.parent_code,
              level = excluded.level,
              name = excluded.name,
              notes = excluded.notes
            """,
            ordered,
        )
    conn.commit()


def occupation_entity(row: dict[str, str]) -> dict[str, Any]:
    raw = as_json(row["raw_data"])
    metadata = raw | {
        "esco_version": row["esco_version"],
        "isco_code": row["isco_code"],
        "broader_occupation_uri": row["broader_occupation_uri"],
        "broader_isco_uri": row["broader_isco_uri"],
        "reference_language": row["reference_language"],
    }
    return {
        "uri": row["uri"],
        "entity_type": "occupation",
        "code": row["code"] or None,
        "title": row["preferred_label_no"] or row["preferred_label_en"] or row["uri"],
        "title_no": row["preferred_label_no"] or None,
        "title_en": row["preferred_label_en"] or None,
        "description_no": row["description_no"] or None,
        "description_en": None,
        "skill_type": None,
        "status": row["status"] or None,
        "metadata": json.dumps(metadata, ensure_ascii=False),
    }


def skill_entity(row: dict[str, str]) -> dict[str, Any]:
    raw = as_json(row["raw_data"])
    metadata = raw | {
        "esco_version": row["esco_version"],
        "reuse_level": row["reuse_level"],
        "broader_skill_uri": row["broader_skill_uri"],
        "broader_skill_code": row["broader_skill_code"],
    }
    return {
        "uri": row["uri"],
        "entity_type": "skill",
        "code": row["broader_skill_code"] or None,
        "title": row["preferred_label_no"] or row["preferred_label_en"] or row["uri"],
        "title_no": row["preferred_label_no"] or None,
        "title_en": row["preferred_label_en"] or None,
        "description_no": row["description_no"] or None,
        "description_en": None,
        "skill_type": row["skill_type"] or None,
        "status": row["status"] or None,
        "metadata": json.dumps(metadata, ensure_ascii=False),
    }


def import_entities(conn: psycopg.Connection, rows: list[dict[str, Any]]) -> None:
    statement = """
        insert into public.esco_entities (
          uri, entity_type, code, title, title_no, title_en, description_no,
          description_en, skill_type, status, metadata, fetched_at
        )
        values (
          %(uri)s, %(entity_type)s, %(code)s, %(title)s, %(title_no)s,
          %(title_en)s, %(description_no)s, %(description_en)s, %(skill_type)s,
          %(status)s, %(metadata)s::jsonb, now()
        )
        on conflict (uri) do update set
          entity_type = excluded.entity_type,
          code = excluded.code,
          title = excluded.title,
          title_no = excluded.title_no,
          title_en = excluded.title_en,
          description_no = excluded.description_no,
          description_en = excluded.description_en,
          skill_type = excluded.skill_type,
          status = excluded.status,
          metadata = excluded.metadata,
          fetched_at = now()
    """
    with conn.cursor() as cur:
        for batch in chunks(rows):
            cur.executemany(statement, batch)
    conn.commit()


def label_rows(dataset: dict[str, list[dict[str, str]]]) -> list[dict[str, str]]:
    labels: dict[tuple[str, str, str, str], dict[str, str]] = {}

    def add(uri: str, language: str, label_type: str, label: str) -> None:
        label = label.strip()
        if not label:
            return
        labels[(uri, language, label_type, label)] = {
            "entity_uri": uri,
            "language": language,
            "label_type": label_type,
            "label": label,
        }

    for row in dataset["esco_occupations"]:
        add(row["uri"], "no", "preferred", row["preferred_label_no"])
        add(row["uri"], "en", "preferred", row["preferred_label_en"])
        for label in as_json(row["raw_data"]).get("alternativeLabelNo", []) or []:
            add(row["uri"], "no", "alternative", str(label))

    for row in dataset["esco_skills"]:
        add(row["uri"], "no", "preferred", row["preferred_label_no"])
        add(row["uri"], "en", "preferred", row["preferred_label_en"])
        for label in as_json(row["raw_data"]).get("alternativeLabelNo", []) or []:
            add(row["uri"], "no", "alternative", str(label))

    for row in dataset["esco_occupation_aliases"]:
        label_type = "preferred" if row["alias_type"] == "esco_preferred" else "alternative"
        add(row["occupation_uri"], row["language"] or "no", label_type, row["alias"])

    return list(labels.values())


def import_labels(conn: psycopg.Connection, rows: list[dict[str, str]]) -> None:
    with conn.cursor() as cur:
        for batch in chunks(rows):
            cur.executemany(
                """
                insert into public.esco_labels (entity_uri, language, label_type, label)
                values (%(entity_uri)s, %(language)s, %(label_type)s, %(label)s)
                on conflict do nothing
                """,
                batch,
            )
    conn.commit()


def import_occupation_skills(conn: psycopg.Connection, rows: list[dict[str, str]]) -> None:
    with conn.cursor() as cur:
        for batch in chunks(rows):
            cur.executemany(
                """
                insert into public.esco_occupation_skills (
                  occupation_uri, skill_uri, relation_type, skill_type, source_version
                )
                values (
                  %(occupation_uri)s, %(skill_uri)s, %(relation_type)s,
                  nullif(%(skill_type)s, ''), %(source_version)s
                )
                on conflict (occupation_uri, skill_uri, relation_type) do update set
                  skill_type = excluded.skill_type,
                  source_version = excluded.source_version
                """,
                batch,
            )
    conn.commit()


def import_mappings(conn: psycopg.Connection, rows: list[dict[str, str]]) -> None:
    with conn.cursor() as cur:
        for batch in chunks(rows):
            cur.executemany(
                """
                insert into public.esco_styrk_mappings (
                  occupation_uri, styrk_code, mapping_relation, source,
                  source_esco_version, source_styrk_version, confidence,
                  editorial_note
                )
                values (
                  %(occupation_uri)s, %(styrk_code)s, %(mapping_relation)s,
                  %(source)s, %(source_esco_version)s, %(source_styrk_version)s,
                  %(confidence)s, nullif(%(editorial_note)s, '')
                )
                on conflict (occupation_uri, styrk_code, mapping_relation, source)
                do update set
                  source_esco_version = excluded.source_esco_version,
                  source_styrk_version = excluded.source_styrk_version,
                  confidence = excluded.confidence,
                  editorial_note = excluded.editorial_note
                """,
                batch,
            )
    conn.commit()


def import_aliases(conn: psycopg.Connection, rows: list[dict[str, str]]) -> None:
    with conn.cursor() as cur:
        for batch in chunks(rows):
            cur.executemany(
                """
                insert into public.esco_occupation_aliases (
                  occupation_uri, alias, alias_normalized, language, alias_type,
                  source, source_relation, weight
                )
                values (
                  %(occupation_uri)s, %(alias)s, %(alias_normalized)s,
                  %(language)s, %(alias_type)s, %(source)s,
                  nullif(%(source_relation)s, ''), %(weight)s
                )
                on conflict (occupation_uri, alias_normalized, alias_type, source)
                do update set
                  alias = excluded.alias,
                  language = excluded.language,
                  source_relation = excluded.source_relation,
                  weight = excluded.weight
                """,
                batch,
            )
    conn.commit()


def import_dataset(conn: psycopg.Connection, dataset: dict[str, list[dict[str, str]]]) -> None:
    import_versions(conn, dataset["esco_data_versions"])
    import_styrk(conn, dataset["styrk08"])

    entities = [occupation_entity(row) for row in dataset["esco_occupations"]]
    entities.extend(skill_entity(row) for row in dataset["esco_skills"])
    import_entities(conn, entities)
    import_labels(conn, label_rows(dataset))
    import_occupation_skills(conn, dataset["esco_occupation_skills"])
    import_mappings(conn, dataset["esco_styrk_mappings"])
    import_aliases(conn, dataset["esco_occupation_aliases"])


def main() -> int:
    args = parse_args()
    load_dotenv()

    dataset_names = [
        "esco_data_versions",
        "styrk08",
        "esco_occupations",
        "esco_skills",
        "esco_occupation_skills",
        "esco_styrk_mappings",
        "esco_occupation_aliases",
    ]
    dataset = {name: read_csv(args.data_dir, name) for name in dataset_names}
    print_counts(dataset)
    validate(dataset)

    if args.dry_run:
        print("Dry run passed; no database writes performed.")
        return 0

    database_url = os.getenv("DATABASE_URL")
    if not database_url:
        print("DATABASE_URL is required. Put it in .env or export it.", file=sys.stderr)
        return 2

    with psycopg.connect(database_url) as conn:
        if args.reset_reference_data:
            reset_reference_data(conn)
        import_dataset(conn, dataset)

    print("Import completed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

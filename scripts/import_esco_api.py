#!/usr/bin/env python3
"""Import ESCO occupations, skills and occupation-skill relations into Postgres.

This importer uses the public ESCO Web Services API. For production usage, prefer
running it as a scheduled/manual sync job and keep the data in Supabase rather
than calling ESCO live for every user interaction.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any, Iterable

import psycopg
from dotenv import load_dotenv


ESCO_API_BASE = "https://ec.europa.eu/esco/api"


@dataclass
class ImportStats:
    occupations: int = 0
    skills: int = 0
    labels: int = 0
    relations: int = 0
    occupation_resources: int = 0


def fetch_json(path_or_url: str, params: dict[str, Any] | None = None, sleep: float = 0.0) -> dict[str, Any]:
    if path_or_url.startswith("http"):
        url = path_or_url
    else:
        query = urllib.parse.urlencode({k: v for k, v in (params or {}).items() if v is not None})
        url = f"{ESCO_API_BASE}{path_or_url}"
        if query:
            url = f"{url}?{query}"

    req = urllib.request.Request(url, headers={"User-Agent": "karrierenmin-esco-import/0.1"})
    with urllib.request.urlopen(req, timeout=60) as response:
        data = json.loads(response.read().decode("utf-8"))
    if sleep:
        time.sleep(sleep)
    return data


def paged_search(entity_type: str, language: str, limit: int, sleep: float) -> Iterable[dict[str, Any]]:
    next_url: str | None = None
    while True:
        if next_url:
            page = fetch_json(next_url, sleep=sleep)
        else:
            page = fetch_json(
                "/search",
                {
                    "type": entity_type,
                    "language": language,
                    "limit": limit,
                    "offset": 0,
                    "full": "false",
                    "viewObsolete": "false",
                },
                sleep=sleep,
            )

        for item in page.get("_embedded", {}).get("results", []):
            yield item

        next_link = page.get("_links", {}).get("next", {}).get("href")
        if not next_link:
            break
        next_url = next_link


def literal(description: Any, language: str) -> str | None:
    if isinstance(description, dict):
        if language in description and isinstance(description[language], dict):
            return description[language].get("literal")
        if "en" in description and isinstance(description["en"], dict):
            return description["en"].get("literal")
    return None


def label_value(value: Any, language: str) -> str | None:
    if isinstance(value, dict):
        return value.get(language) or value.get("en")
    if isinstance(value, str):
        return value
    return None


def iter_preferred_labels(item: dict[str, Any]) -> Iterable[tuple[str, str]]:
    labels = item.get("preferredLabel") or {}
    if isinstance(labels, dict):
        for lang, value in labels.items():
            if isinstance(value, str) and value.strip():
                yield lang, value.strip()


def iter_alternative_labels(item: dict[str, Any]) -> Iterable[tuple[str, str]]:
    labels = item.get("alternativeLabel") or {}
    if isinstance(labels, dict):
        for lang, values in labels.items():
            if isinstance(values, str):
                values = [values]
            if isinstance(values, list):
                for value in values:
                    if isinstance(value, str) and value.strip():
                        yield lang, value.strip()


def upsert_entity(cur: psycopg.Cursor, item: dict[str, Any], entity_type: str, language: str) -> None:
    preferred = item.get("preferredLabel") or {}
    title_no = preferred.get("no") if isinstance(preferred, dict) else None
    title_en = preferred.get("en") if isinstance(preferred, dict) else None
    title = label_value(preferred, language) or item.get("title") or title_no or title_en or item["uri"]

    cur.execute(
        """
        insert into public.esco_entities (
          uri, entity_type, code, title, title_no, title_en, description_no,
          description_en, skill_type, status, metadata, fetched_at
        )
        values (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s::jsonb, now())
        on conflict (uri) do update set
          entity_type = excluded.entity_type,
          code = coalesce(excluded.code, public.esco_entities.code),
          title = excluded.title,
          title_no = coalesce(excluded.title_no, public.esco_entities.title_no),
          title_en = coalesce(excluded.title_en, public.esco_entities.title_en),
          description_no = coalesce(excluded.description_no, public.esco_entities.description_no),
          description_en = coalesce(excluded.description_en, public.esco_entities.description_en),
          skill_type = coalesce(excluded.skill_type, public.esco_entities.skill_type),
          status = coalesce(excluded.status, public.esco_entities.status),
          metadata = public.esco_entities.metadata || excluded.metadata,
          fetched_at = now()
        """,
        (
            item["uri"],
            entity_type,
            item.get("code"),
            title,
            title_no,
            title_en,
            literal(item.get("description"), "no"),
            literal(item.get("description"), "en"),
            item.get("skillType"),
            item.get("status"),
            json.dumps(
                {
                    "className": item.get("className"),
                    "classId": item.get("classId"),
                    "isInScheme": item.get("isInScheme"),
                    "broaderIscoGroup": item.get("broaderIscoGroup"),
                    "referenceLanguage": item.get("referenceLanguage"),
                }
            ),
        ),
    )


def insert_label(cur: psycopg.Cursor, uri: str, language: str, label_type: str, label: str) -> None:
    cur.execute(
        """
        insert into public.esco_labels (entity_uri, language, label_type, label)
        values (%s, %s, %s, %s)
        on conflict do nothing
        """,
        (uri, language, label_type, label),
    )


def upsert_labels(cur: psycopg.Cursor, item: dict[str, Any]) -> int:
    count = 0
    uri = item["uri"]
    for lang, label in iter_preferred_labels(item):
        insert_label(cur, uri, lang, "preferred", label)
        count += 1
    for lang, label in iter_alternative_labels(item):
        insert_label(cur, uri, lang, "alternative", label)
        count += 1
    return count


def upsert_relation(
    cur: psycopg.Cursor,
    occupation_uri: str,
    skill_link: dict[str, Any],
    relation_type: str,
) -> None:
    skill_uri = skill_link["uri"]
    skill_title = skill_link.get("title") or skill_uri
    cur.execute(
        """
        insert into public.esco_entities (uri, entity_type, title, skill_type, metadata)
        values (%s, 'skill', %s, %s, %s::jsonb)
        on conflict (uri) do update set
          title = coalesce(public.esco_entities.title, excluded.title),
          skill_type = coalesce(public.esco_entities.skill_type, excluded.skill_type),
          metadata = public.esco_entities.metadata || excluded.metadata
        """,
        (
            skill_uri,
            skill_title,
            skill_link.get("skillType"),
            json.dumps({"from_occupation_relation": True}),
        ),
    )
    cur.execute(
        """
        insert into public.esco_occupation_skills (
          occupation_uri, skill_uri, relation_type, skill_type
        )
        values (%s, %s, %s, %s)
        on conflict do nothing
        """,
        (occupation_uri, skill_uri, relation_type, skill_link.get("skillType")),
    )


def import_search_entities(
    conn: psycopg.Connection,
    entity_type: str,
    language: str,
    page_limit: int,
    max_items: int | None,
    sleep: float,
) -> tuple[list[str], int, int]:
    uris: list[str] = []
    entity_count = 0
    label_count = 0
    with conn.cursor() as cur:
        for item in paged_search(entity_type, language, page_limit, sleep):
            upsert_entity(cur, item, entity_type, language)
            label_count += upsert_labels(cur, item)
            uris.append(item["uri"])
            entity_count += 1
            if entity_count % 500 == 0:
                conn.commit()
                print(f"Imported {entity_count} {entity_type}s...", flush=True)
            if max_items and entity_count >= max_items:
                break
    conn.commit()
    return uris, entity_count, label_count


def import_occupation_relations(
    conn: psycopg.Connection,
    occupation_uris: list[str],
    language: str,
    max_items: int | None,
    sleep: float,
) -> tuple[int, int]:
    imported = 0
    relations = 0
    with conn.cursor() as cur:
        for uri in occupation_uris[: max_items or None]:
            resource = fetch_json(
                "/resource/occupation",
                {"uri": uri, "language": language},
                sleep=sleep,
            )
            upsert_entity(cur, resource, "occupation", language)
            upsert_labels(cur, resource)
            for relation_type, link_name in (
                ("essential", "hasEssentialSkill"),
                ("optional", "hasOptionalSkill"),
            ):
                for skill_link in resource.get("_links", {}).get(link_name, []) or []:
                    upsert_relation(cur, resource["uri"], skill_link, relation_type)
                    relations += 1
            imported += 1
            if imported % 100 == 0:
                conn.commit()
                print(f"Fetched {imported} occupation resources, {relations} relations...", flush=True)
    conn.commit()
    return imported, relations


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--language", default=os.getenv("ESCO_LANGUAGE", "no"))
    parser.add_argument("--page-limit", type=int, default=500)
    parser.add_argument("--sleep", type=float, default=0.05)
    parser.add_argument("--limit-occupations", type=int)
    parser.add_argument("--limit-skills", type=int)
    parser.add_argument("--skip-relations", action="store_true")
    args = parser.parse_args()

    load_dotenv()
    database_url = os.getenv("DATABASE_URL")
    if not database_url:
        print("DATABASE_URL is required. Put it in .env or export it.", file=sys.stderr)
        return 2

    stats = ImportStats()
    try:
        with psycopg.connect(database_url) as conn:
            occupation_uris, stats.occupations, occupation_labels = import_search_entities(
                conn, "occupation", args.language, args.page_limit, args.limit_occupations, args.sleep
            )
            skill_uris, stats.skills, skill_labels = import_search_entities(
                conn, "skill", args.language, args.page_limit, args.limit_skills, args.sleep
            )
            stats.labels = occupation_labels + skill_labels
            if not args.skip_relations:
                stats.occupation_resources, stats.relations = import_occupation_relations(
                    conn, occupation_uris, args.language, args.limit_occupations, args.sleep
                )
    except psycopg.OperationalError as exc:
        print(f"Could not connect to Postgres: {exc}", file=sys.stderr)
        if "db.wcaqfupjatnjwbgatzjv.supabase.co" in database_url:
            print(
                "Hint: the direct Supabase database host may be IPv6-only. "
                "Use the pooler connection string from supabase/.temp/pooler-url "
                "or the Supabase dashboard, and include your password.",
                file=sys.stderr,
            )
        return 2

    print(json.dumps(stats.__dict__, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

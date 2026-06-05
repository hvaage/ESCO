#!/usr/bin/env python3
"""Import NAV labour-market Excel attachments into Supabase."""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import os
import re
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin, unquote
from urllib.request import Request, urlopen
from xml.etree import ElementTree as ET
from zipfile import ZipFile

from dotenv import load_dotenv


UNEMPLOYMENT_PAGE = "https://www.nav.no/no/nav-og-samfunn/statistikk/arbeidssokere-og-stillinger-statistikk/helt-ledige"
VACANCIES_PAGE = "https://www.nav.no/no/nav-og-samfunn/statistikk/arbeidssokere-og-stillinger-statistikk/ledige-stillinger"
BUSINESS_SURVEY_PAGE = "https://www.nav.no/no/nav-og-samfunn/kunnskap/analyser-fra-nav/arbeid-og-velferd/arbeid-og-velferd/bedriftsundersokelsen"

MONTHS = {
    "januar": 1,
    "februar": 2,
    "mars": 3,
    "april": 4,
    "mai": 5,
    "juni": 6,
    "juli": 7,
    "august": 8,
    "september": 9,
    "oktober": 10,
    "november": 11,
    "desember": 12,
}

COUNTY_CODES = {
    "oslo": "03",
    "rogaland": "11",
    "møre og romsdal": "15",
    "nordland": "18",
    "østfold": "31",
    "akershus": "32",
    "buskerud": "33",
    "innlandet": "34",
    "vestfold": "39",
    "telemark": "40",
    "agder": "42",
    "vestland": "46",
    "trøndelag": "50",
    "troms": "55",
    "finnmark": "56",
}

NAV_AGGREGATE_PREFIX_RULES = {
    "sykepleiere og jordmødre": "222",
}

XLSX_NS = {
    "a": "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
    "r": "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
}
RELS_NS = {"rel": "http://schemas.openxmlformats.org/package/2006/relationships"}
CHUNK_SIZE = 2000
FETCH_ATTEMPTS = 6
FETCH_INITIAL_BACKOFF_SECONDS = 3.0
FETCH_MAX_BACKOFF_SECONDS = 45.0
TRANSIENT_HTTP_STATUSES = {429, 500, 502, 503, 504}


@dataclass(frozen=True)
class Attachment:
    dataset_key: str
    source_key: str
    page_url: str
    url: str
    label: str
    file_name: str
    content: bytes
    sha256: str
    file_year: int | None
    file_month: int | None


@dataclass(frozen=True)
class MappingResult:
    nav_label_norm: str
    styrk_code: str | None
    styrk_prefix: str | None
    mapping_level: str
    confidence: float
    notes: str | None = None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--dataset",
        choices=("all", "unemployment", "vacancies", "business-survey"),
        default="all",
    )
    parser.add_argument(
        "--cache-dir",
        type=Path,
        default=Path("data/raw/nav"),
        help="Directory used for downloaded NAV attachments.",
    )
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def chunks(rows: list[dict[str, Any]], size: int = CHUNK_SIZE) -> Iterable[list[dict[str, Any]]]:
    for index in range(0, len(rows), size):
        yield rows[index : index + size]


def fetch_bytes(url: str) -> bytes:
    last_error: Exception | None = None

    for attempt in range(1, FETCH_ATTEMPTS + 1):
        request = Request(url, headers={"User-Agent": "karrierenmin-data-import/1.0"})
        try:
            with urlopen(request, timeout=60) as response:
                return response.read()
        except HTTPError as exc:
            if exc.code not in TRANSIENT_HTTP_STATUSES or attempt == FETCH_ATTEMPTS:
                raise
            last_error = exc
        except (URLError, TimeoutError, ConnectionResetError) as exc:
            if attempt == FETCH_ATTEMPTS:
                raise
            last_error = exc

        sleep_seconds = min(
            FETCH_MAX_BACKOFF_SECONDS,
            FETCH_INITIAL_BACKOFF_SECONDS * (2 ** (attempt - 1)),
        )
        print(
            f"Transient NAV download error for {url} "
            f"(attempt {attempt}/{FETCH_ATTEMPTS}): {last_error}. "
            f"Retrying in {sleep_seconds:.0f}s...",
            file=sys.stderr,
        )
        time.sleep(sleep_seconds)

    raise RuntimeError(f"Could not download {url}: {last_error}")


def fetch_text(url: str) -> str:
    return fetch_bytes(url).decode("utf-8", errors="replace")


def normalize_label(value: str | None) -> str:
    if not value:
        return ""
    text = value.strip().lower()
    text = text.replace("–", "-").replace("—", "-")
    text = re.sub(r"\([^)]*\)", " ", text)
    text = text.replace("m.v.", "mv").replace("m.m.", "mm")
    text = re.sub(r"[,;:/]", " ", text)
    text = re.sub(r"\s+", " ", text)
    return text.strip()


def clean_label(value: Any) -> str:
    text = str(value or "").strip()
    text = re.sub(r"\s+", " ", text)
    return text


def parse_number(value: Any) -> tuple[float | None, bool]:
    if value is None:
        return None, False
    if isinstance(value, (int, float)):
        return float(value), False
    text = str(value).strip()
    if not text:
        return None, False
    if text == "*":
        return None, True
    text = text.replace("\u00a0", "").replace(" ", "").replace(",", ".")
    try:
        return float(text), False
    except ValueError:
        return None, False


def observation_key(payload: dict[str, Any]) -> str:
    stable = json.dumps(payload, ensure_ascii=False, sort_keys=True, default=str)
    return hashlib.sha256(stable.encode("utf-8")).hexdigest()


def find_attachments(page_url: str) -> list[tuple[str, str]]:
    page = fetch_text(page_url)
    anchors: list[tuple[str, str]] = []
    for match in re.finditer(r"<a[^>]+href=\"([^\"]+)\"[^>]*>(.*?)</a>", page, re.I | re.S):
        href, label_html = match.groups()
        label = html.unescape(re.sub(r"<[^>]+>", "", label_html)).strip()
        if not label:
            continue
        anchors.append((urljoin(page_url, href), label))
    return anchors


def choose_attachment(dataset: str) -> tuple[str, str, str, str]:
    if dataset == "unemployment":
        page_url = UNEMPLOYMENT_PAGE
        source_key = "nav_unemployment_monthly"

        def wanted(label: str) -> bool:
            low = label.lower()
            return "helt ledige" in low and "yrke" in low and "xls" in low and "årsgjennomsnitt" not in low

    elif dataset == "vacancies":
        page_url = VACANCIES_PAGE
        source_key = "nav_vacancies_monthly"

        def wanted(label: str) -> bool:
            low = label.lower()
            return "tilgang ledige stillinger" in low and "yrke" in low and "xls" in low and "årsgjennomsnitt" not in low

    elif dataset == "business-survey":
        page_url = BUSINESS_SURVEY_PAGE
        source_key = "nav_business_survey"

        def wanted(label: str) -> bool:
            low = label.lower()
            return "figurer og tabeller" in low

    else:
        raise ValueError(dataset)

    matches = [(url, label) for url, label in find_attachments(page_url) if wanted(label)]
    if not matches:
        raise RuntimeError(f"Could not find NAV attachment for {dataset} at {page_url}")
    url, label = matches[0]
    return page_url, source_key, url, label


def file_name_from_url(url: str) -> str:
    name = unquote(url.rsplit("/", 1)[-1])
    return name or "nav_attachment.xlsx"


def file_period(file_name: str, label: str) -> tuple[int | None, int | None]:
    joined = f"{file_name} {label}"
    match = re.search(r"(20[0-9]{2})[._-]?([0-9]{2})", joined)
    if match:
        year = int(match.group(1))
        month = int(match.group(2))
        if 1 <= month <= 12:
            return year, month
    years = [int(value) for value in re.findall(r"20[0-9]{2}", joined)]
    if years:
        return max(years), None
    short_year = re.search(r"(?:Tabell|Figur|V\d)\s*[- ]\s*([0-9]{2})\b", label)
    if short_year:
        return 2000 + int(short_year.group(1)), None
    return None, None


def download_attachment(dataset: str, cache_dir: Path) -> Attachment:
    dataset_key = {
        "unemployment": "unemployment_monthly",
        "vacancies": "vacancies_monthly",
        "business-survey": "business_survey",
    }[dataset]
    page_url, source_key, url, label = choose_attachment(dataset)
    content = fetch_bytes(url)
    digest = hashlib.sha256(content).hexdigest()
    name = file_name_from_url(url)
    year, month = file_period(name, label)
    cache_dir.mkdir(parents=True, exist_ok=True)
    (cache_dir / name).write_bytes(content)
    return Attachment(
        dataset_key=dataset_key,
        source_key=source_key,
        page_url=page_url,
        url=url,
        label=label,
        file_name=name,
        content=content,
        sha256=digest,
        file_year=year,
        file_month=month,
    )


def column_index(cell_ref: str) -> int:
    letters = re.match(r"([A-Z]+)", cell_ref or "")
    if not letters:
        return 0
    value = 0
    for char in letters.group(1):
        value = value * 26 + ord(char) - 64
    return value - 1


def shared_strings(zip_file: ZipFile) -> list[str]:
    if "xl/sharedStrings.xml" not in zip_file.namelist():
        return []
    root = ET.fromstring(zip_file.read("xl/sharedStrings.xml"))
    return [
        "".join(t.text or "" for t in item.findall(".//a:t", XLSX_NS))
        for item in root.findall("a:si", XLSX_NS)
    ]


def workbook_sheet_targets(zip_file: ZipFile) -> list[tuple[str, str]]:
    workbook = ET.fromstring(zip_file.read("xl/workbook.xml"))
    relationships = ET.fromstring(zip_file.read("xl/_rels/workbook.xml.rels"))
    relation_targets = {
        rel.attrib["Id"]: rel.attrib["Target"]
        for rel in relationships.findall("rel:Relationship", RELS_NS)
    }
    sheets: list[tuple[str, str]] = []
    for sheet in workbook.findall("a:sheets/a:sheet", XLSX_NS):
        rel_id = sheet.attrib["{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id"]
        target = relation_targets[rel_id]
        if not target.startswith("xl/"):
            target = "xl/" + target
        sheets.append((sheet.attrib["name"], target))
    return sheets


def cell_value(cell: ET.Element, strings: list[str]) -> Any:
    value = cell.find("a:v", XLSX_NS)
    if value is None:
        inline = cell.find("a:is", XLSX_NS)
        if inline is not None:
            return "".join(t.text or "" for t in inline.findall(".//a:t", XLSX_NS))
        return ""
    raw = value.text or ""
    if cell.attrib.get("t") == "s":
        return strings[int(raw)] if raw.isdigit() and int(raw) < len(strings) else raw
    try:
        if "." in raw or "E" in raw or "e" in raw:
            return float(raw)
        return int(raw)
    except ValueError:
        return raw


def read_xlsx(content: bytes) -> dict[str, list[list[Any]]]:
    temp_path = Path("/tmp/nav_import_workbook.xlsx")
    temp_path.write_bytes(content)
    workbook: dict[str, list[list[Any]]] = {}
    with ZipFile(temp_path) as zip_file:
        strings = shared_strings(zip_file)
        for sheet_name, target in workbook_sheet_targets(zip_file):
            root = ET.fromstring(zip_file.read(target))
            rows: list[list[Any]] = []
            for row in root.findall("a:sheetData/a:row", XLSX_NS):
                values: dict[int, Any] = {}
                for cell in row.findall("a:c", XLSX_NS):
                    values[column_index(cell.attrib.get("r", ""))] = cell_value(cell, strings)
                if values:
                    max_index = max(values)
                    rows.append([values.get(index, "") for index in range(max_index + 1)])
                else:
                    rows.append([])
            workbook[sheet_name] = rows
    temp_path.unlink(missing_ok=True)
    return workbook


def load_styrk_lookup(conn: Any) -> tuple[dict[str, tuple[str, int]], dict[str, tuple[str, int]]]:
    with conn.cursor() as cur:
        cur.execute("select code, level, name from public.styrk08")
        by_code: dict[str, tuple[str, int]] = {}
        by_label: dict[str, tuple[str, int]] = {}
        for code, level, name in cur.fetchall():
            by_code[str(code)] = (str(name), int(level))
            norm = normalize_label(str(name))
            by_label.setdefault(norm, (str(code), int(level)))
    return by_code, by_label


def resolve_mapping(
    label: str,
    nav_code: str | None,
    by_code: dict[str, tuple[str, int]],
    by_label: dict[str, tuple[str, int]],
) -> MappingResult:
    norm = normalize_label(label)
    code = clean_label(nav_code) if nav_code else None
    if code and code in by_code:
        _, level = by_code[code]
        if level == 4:
            return MappingResult(norm, code, None, "exact_styrk4", 0.9800, "NAV code matched STYRK-08 code")
        return MappingResult(norm, None, code, "styrk_prefix", 0.8500, "NAV code matched STYRK prefix")
    if norm in by_label:
        styrk_code, level = by_label[norm]
        if level == 4:
            return MappingResult(norm, styrk_code, None, "exact_styrk4", 0.8800, "NAV label matched STYRK-08 title")
        return MappingResult(norm, None, styrk_code, "styrk_prefix", 0.7400, "NAV label matched STYRK group title")
    if norm in NAV_AGGREGATE_PREFIX_RULES:
        prefix = NAV_AGGREGATE_PREFIX_RULES[norm]
        return MappingResult(norm, None, prefix, "styrk_prefix", 0.7000, "Manual NAV aggregate label matched STYRK prefix")
    return MappingResult(norm, None, None, "unmapped", 0.3000, "No confident STYRK match")


def month_header(row: list[Any]) -> list[tuple[int, int]]:
    columns: list[tuple[int, int]] = []
    for index, value in enumerate(row):
        month = MONTHS.get(normalize_label(str(value)))
        if month:
            columns.append((index, month))
    return columns


def region_from_label(label: str | None) -> tuple[str | None, str | None]:
    norm = normalize_label(label)
    if norm in COUNTY_CODES:
        return COUNTY_CODES[norm], clean_label(label)
    return None, None


def insert_source_file(conn: Any, attachment: Attachment) -> int:
    with conn.cursor() as cur:
        cur.execute(
            """
            insert into public.nav_source_files (
              source_key, dataset_key, source_page_url, attachment_url, file_name,
              file_period, file_year, file_month, sha256, bytes, metadata, imported_at
            )
            values (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s::jsonb, now())
            on conflict (dataset_key, sha256) do update set
              source_key = excluded.source_key,
              source_page_url = excluded.source_page_url,
              attachment_url = excluded.attachment_url,
              file_name = excluded.file_name,
              file_period = excluded.file_period,
              file_year = excluded.file_year,
              file_month = excluded.file_month,
              bytes = excluded.bytes,
              metadata = excluded.metadata,
              imported_at = now()
            returning id
            """,
            (
                attachment.source_key,
                attachment.dataset_key,
                attachment.page_url,
                attachment.url,
                attachment.file_name,
                f"{attachment.file_year}-{attachment.file_month:02d}" if attachment.file_year and attachment.file_month else (str(attachment.file_year) if attachment.file_year else None),
                attachment.file_year,
                attachment.file_month,
                attachment.sha256,
                len(attachment.content),
                json.dumps({"link_label": attachment.label}, ensure_ascii=False),
            ),
        )
        source_file_id = int(cur.fetchone()[0])
    conn.commit()
    return source_file_id


def import_mappings(conn: Any, mappings: list[dict[str, Any]]) -> None:
    if not mappings:
        return
    statement = """
        insert into public.nav_occupation_mappings (
          nav_label, nav_label_norm, nav_code, styrk_code, styrk_prefix,
          mapping_level, confidence, source, notes, metadata
        )
        values (
          %(nav_label)s, %(nav_label_norm)s, %(nav_code)s, %(styrk_code)s,
          %(styrk_prefix)s, %(mapping_level)s, %(confidence)s, 'import',
          %(notes)s, %(metadata)s::jsonb
        )
        on conflict (nav_label_norm, nav_code) do update set
          nav_label = excluded.nav_label,
          styrk_code = excluded.styrk_code,
          styrk_prefix = excluded.styrk_prefix,
          mapping_level = excluded.mapping_level,
          confidence = greatest(public.nav_occupation_mappings.confidence, excluded.confidence),
          notes = excluded.notes,
          metadata = public.nav_occupation_mappings.metadata || excluded.metadata,
          updated_at = now()
    """
    with conn.cursor() as cur:
        for batch in chunks(mappings):
            cur.executemany(statement, batch)
    conn.commit()


def import_monthly_stats(conn: Any, rows: list[dict[str, Any]]) -> None:
    if not rows:
        return
    statement = """
        insert into public.nav_monthly_occupation_stats (
          observation_key, source_file_id, dataset_key, metric_code, metric_label,
          period, period_year, period_month, nav_occupation_label,
          nav_occupation_code, nav_occupation_group_label, styrk_code, styrk_prefix,
          region_code, region_label, dimension_type, dimension_label, value,
          suppressed, metadata, imported_at
        )
        values (
          %(observation_key)s, %(source_file_id)s, %(dataset_key)s, %(metric_code)s,
          %(metric_label)s, %(period)s, %(period_year)s, %(period_month)s,
          %(nav_occupation_label)s, %(nav_occupation_code)s, %(nav_occupation_group_label)s,
          %(styrk_code)s, %(styrk_prefix)s, %(region_code)s, %(region_label)s,
          %(dimension_type)s, %(dimension_label)s, %(value)s, %(suppressed)s,
          %(metadata)s::jsonb, now()
        )
        on conflict (observation_key) do update set
          source_file_id = excluded.source_file_id,
          styrk_code = excluded.styrk_code,
          styrk_prefix = excluded.styrk_prefix,
          nav_occupation_group_label = excluded.nav_occupation_group_label,
          region_code = excluded.region_code,
          region_label = excluded.region_label,
          dimension_type = excluded.dimension_type,
          dimension_label = excluded.dimension_label,
          value = excluded.value,
          suppressed = excluded.suppressed,
          metadata = excluded.metadata,
          imported_at = now()
    """
    with conn.cursor() as cur:
        for batch in chunks(rows):
            cur.executemany(statement, batch)
    conn.commit()


def import_shortage_rows(conn: Any, rows: list[dict[str, Any]]) -> None:
    if not rows:
        return
    statement = """
        insert into public.nav_labour_shortage_survey (
          observation_key, source_file_id, year, dimension_type, label, parent_label,
          styrk_code, styrk_prefix, nace_code, region_code, region_label,
          education_level, education_field, shortage_count, ci_lower, ci_upper,
          tightness_indicator, serious_recruitment_problem_percent, value,
          metric_code, metric_label, metadata, imported_at
        )
        values (
          %(observation_key)s, %(source_file_id)s, %(year)s, %(dimension_type)s,
          %(label)s, %(parent_label)s, %(styrk_code)s, %(styrk_prefix)s,
          %(nace_code)s, %(region_code)s, %(region_label)s, %(education_level)s,
          %(education_field)s, %(shortage_count)s, %(ci_lower)s, %(ci_upper)s,
          %(tightness_indicator)s, %(serious_recruitment_problem_percent)s,
          %(value)s, %(metric_code)s, %(metric_label)s, %(metadata)s::jsonb, now()
        )
        on conflict (observation_key) do update set
          source_file_id = excluded.source_file_id,
          styrk_code = excluded.styrk_code,
          styrk_prefix = excluded.styrk_prefix,
          region_code = excluded.region_code,
          region_label = excluded.region_label,
          education_level = excluded.education_level,
          education_field = excluded.education_field,
          shortage_count = excluded.shortage_count,
          ci_lower = excluded.ci_lower,
          ci_upper = excluded.ci_upper,
          tightness_indicator = excluded.tightness_indicator,
          serious_recruitment_problem_percent = excluded.serious_recruitment_problem_percent,
          value = excluded.value,
          metadata = excluded.metadata,
          imported_at = now()
    """
    with conn.cursor() as cur:
        for batch in chunks(rows):
            cur.executemany(statement, batch)
    conn.commit()


def parse_monthly_sheet(
    rows: list[list[Any]],
    *,
    source_file_id: int,
    dataset_key: str,
    metric_code: str,
    metric_label: str,
    sheet_name: str,
    period_year: int,
    by_code: dict[str, tuple[str, int]],
    by_label: dict[str, tuple[str, int]],
    source_priority: int,
    dimension_type: str | None = None,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    observations: list[dict[str, Any]] = []
    mappings: list[dict[str, Any]] = []
    current_section: str | None = None
    active_months: list[tuple[int, int]] = []

    for row in rows:
        row_values = [clean_label(value) for value in row]
        non_empty = [(index, value) for index, value in enumerate(row_values) if value]
        if not non_empty:
            continue
        months = month_header(row_values)
        if len(months) >= 2:
            active_months = months
            continue
        if not active_months:
            current_section = non_empty[0][1]
            continue

        month_values = [
            (column_index, month, parse_number(row[column_index] if column_index < len(row) else ""))
            for column_index, month in active_months
        ]
        if not any(value is not None or suppressed for _, _, (value, suppressed) in month_values):
            if len(non_empty) == 1:
                current_section = non_empty[0][1]
            continue

        first_month_col = min(column for column, _ in active_months)
        pre_cells = [(index, value) for index, value in non_empty if index < first_month_col]
        if not pre_cells:
            continue
        nav_code: str | None = None
        label: str
        if len(pre_cells) >= 2 and re.fullmatch(r"[0-9]{4}", pre_cells[0][1]):
            nav_code = pre_cells[0][1]
            label = pre_cells[1][1]
        else:
            label = pre_cells[-1][1]
        if not label or normalize_label(label).startswith("i alt ") and len(label) <= 8:
            continue

        mapping = resolve_mapping(label, nav_code, by_code, by_label)
        mappings.append(
            {
                "nav_label": label,
                "nav_label_norm": mapping.nav_label_norm,
                "nav_code": nav_code,
                "styrk_code": mapping.styrk_code,
                "styrk_prefix": mapping.styrk_prefix,
                "mapping_level": mapping.mapping_level,
                "confidence": mapping.confidence,
                "notes": mapping.notes,
                "metadata": json.dumps({"source_sheet": sheet_name}, ensure_ascii=False),
            }
        )
        region_code, region_label = region_from_label(current_section) if dimension_type == "county" else (None, None)

        for _, month, (value, suppressed) in month_values:
            period = f"{period_year}-{month:02d}"
            key_payload = {
                "source_file_id": source_file_id,
                "dataset_key": dataset_key,
                "metric_code": metric_code,
                "period": period,
                "sheet": sheet_name,
                "nav_code": nav_code,
                "label": label,
                "section": current_section,
                "dimension_type": dimension_type,
            }
            observations.append(
                {
                    "observation_key": observation_key(key_payload),
                    "source_file_id": source_file_id,
                    "dataset_key": dataset_key,
                    "metric_code": metric_code,
                    "metric_label": metric_label,
                    "period": period,
                    "period_year": period_year,
                    "period_month": month,
                    "nav_occupation_label": label,
                    "nav_occupation_code": nav_code,
                    "nav_occupation_group_label": current_section,
                    "styrk_code": mapping.styrk_code,
                    "styrk_prefix": mapping.styrk_prefix,
                    "region_code": region_code,
                    "region_label": region_label,
                    "dimension_type": dimension_type,
                    "dimension_label": region_label or current_section if dimension_type else None,
                    "value": value,
                    "suppressed": suppressed,
                    "metadata": json.dumps(
                        {
                            "source_sheet": sheet_name,
                            "source_priority": source_priority,
                            "mapping_level": mapping.mapping_level,
                        },
                        ensure_ascii=False,
                    ),
                }
            )
    return observations, mappings


def parse_monthly_workbook(
    workbook: dict[str, list[list[Any]]],
    attachment: Attachment,
    source_file_id: int,
    by_code: dict[str, tuple[str, int]],
    by_label: dict[str, tuple[str, int]],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    if not attachment.file_year:
        raise ValueError(f"Could not infer year from {attachment.file_name}")
    observations: list[dict[str, Any]] = []
    mappings: list[dict[str, Any]] = []

    if attachment.dataset_key == "unemployment_monthly":
        specs = [
            ("Antall. Topp 30 i perioden", "count", "Helt ledige", 100, None),
            ("Yrkesgruppe grov og fin. Antall", "count", "Helt ledige", 60, None),
            ("Yrkesgruppe. Antall", "count", "Helt ledige", 40, None),
            ("Fylke. Antall", "count", "Helt ledige", 30, "county"),
        ]
    else:
        specs = [
            ("4. Antall. Top 30 i perioden", "count", "Tilgang ledige stillinger", 100, None),
            ("1. Antall", "count", "Tilgang ledige stillinger", 60, None),
            ("3. Endring per virkedag", "yoy_change_percent", "Estimert endring per virkedag fra i fjor", 50, None),
        ]

    for sheet_name, metric_code, metric_label, priority, dimension_type in specs:
        if sheet_name not in workbook:
            continue
        rows, map_rows = parse_monthly_sheet(
            workbook[sheet_name],
            source_file_id=source_file_id,
            dataset_key=attachment.dataset_key,
            metric_code=metric_code,
            metric_label=metric_label,
            sheet_name=sheet_name,
            period_year=attachment.file_year,
            by_code=by_code,
            by_label=by_label,
            source_priority=priority,
            dimension_type=dimension_type,
        )
        observations.extend(rows)
        mappings.extend(map_rows)
    return observations, mappings


def find_header_index(row: list[Any], text_pattern: str) -> int | None:
    pattern = re.compile(text_pattern, re.I)
    for index, value in enumerate(row):
        if pattern.search(clean_label(value)):
            return index
    return None


def parse_shortage_table(
    rows: list[list[Any]],
    *,
    sheet_name: str,
    source_file_id: int,
    year: int,
    dimension_type: str,
    by_code: dict[str, tuple[str, int]],
    by_label: dict[str, tuple[str, int]],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    header_index = None
    for index, row in enumerate(rows):
        shortage_candidate = find_header_index(row, r"mangel på arbeidskraft")
        if shortage_candidate is None:
            continue
        first_cell = normalize_label(clean_label(row[0] if row else ""))
        looks_like_header = (
            shortage_candidate > 0
            or first_cell in ("", "nivå", "utdanningsnivå", "95% konf.int.")
            or find_header_index(row, r"nedre|øvre|stram|helt ledige") is not None
        )
        if looks_like_header:
            header_index = index
            break
    if header_index is None:
        return [], []
    header = rows[header_index]
    shortage_idx = find_header_index(header, r"mangel på arbeidskraft")
    lower_idx = find_header_index(header, r"nedre")
    upper_idx = find_header_index(header, r"øvre")
    tightness_idx = find_header_index(header, r"stram")
    serious_idx = find_header_index(header, r"alvorlige")
    if shortage_idx is None:
        return [], []

    observations: list[dict[str, Any]] = []
    mappings: list[dict[str, Any]] = []
    current_level: str | None = None
    for row in rows[header_index + 1 :]:
        if not any(clean_label(value) for value in row):
            continue
        label = clean_label(row[0] if row else "")
        if dimension_type == "education":
            level = clean_label(row[0] if len(row) > 0 else "") or current_level
            field = clean_label(row[1] if len(row) > 1 else "")
            if level:
                current_level = level
            label = f"{level} / {field}" if field and field != level else (level or field)
        if not label or label.lower().startswith("tabell"):
            continue
        shortage, _ = parse_number(row[shortage_idx] if shortage_idx < len(row) else "")
        if shortage is None:
            continue
        lower, _ = parse_number(row[lower_idx] if lower_idx is not None and lower_idx < len(row) else "")
        upper, _ = parse_number(row[upper_idx] if upper_idx is not None and upper_idx < len(row) else "")
        tightness, _ = parse_number(row[tightness_idx] if tightness_idx is not None and tightness_idx < len(row) else "")
        serious, _ = parse_number(row[serious_idx] if serious_idx is not None and serious_idx < len(row) else "")
        mapping = resolve_mapping(label, None, by_code, by_label) if dimension_type in ("occupation", "occupation_group") else MappingResult(normalize_label(label), None, None, "unmapped", 0.3)
        if dimension_type in ("occupation", "occupation_group"):
            mappings.append(
                {
                    "nav_label": label,
                    "nav_label_norm": mapping.nav_label_norm,
                    "nav_code": None,
                    "styrk_code": mapping.styrk_code,
                    "styrk_prefix": mapping.styrk_prefix,
                    "mapping_level": mapping.mapping_level,
                    "confidence": mapping.confidence,
                    "notes": mapping.notes,
                    "metadata": json.dumps({"source_sheet": sheet_name}, ensure_ascii=False),
                }
            )
        region_code, region_label = region_from_label(label) if dimension_type == "county" else (None, None)
        key_payload = {
            "source_file_id": source_file_id,
            "year": year,
            "sheet": sheet_name,
            "dimension_type": dimension_type,
            "label": label,
        }
        observations.append(
            {
                "observation_key": observation_key(key_payload),
                "source_file_id": source_file_id,
                "year": year,
                "dimension_type": dimension_type,
                "label": label,
                "parent_label": current_level if dimension_type == "education" else None,
                "styrk_code": mapping.styrk_code,
                "styrk_prefix": mapping.styrk_prefix,
                "nace_code": None,
                "region_code": region_code,
                "region_label": region_label,
                "education_level": current_level if dimension_type == "education" else None,
                "education_field": clean_label(row[1] if dimension_type == "education" and len(row) > 1 else ""),
                "shortage_count": shortage,
                "ci_lower": lower,
                "ci_upper": upper,
                "tightness_indicator": tightness,
                "serious_recruitment_problem_percent": serious,
                "value": shortage,
                "metric_code": "shortage_count",
                "metric_label": "Mangel på arbeidskraft",
                "metadata": json.dumps({"source_sheet": sheet_name, "mapping_level": mapping.mapping_level}, ensure_ascii=False),
            }
        )
    return observations, mappings


def parse_business_survey(
    workbook: dict[str, list[list[Any]]],
    attachment: Attachment,
    source_file_id: int,
    by_code: dict[str, tuple[str, int]],
    by_label: dict[str, tuple[str, int]],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    if not attachment.file_year:
        raise ValueError(f"Could not infer year from {attachment.file_name}")
    specs = [
        ("Tabell V2", "occupation"),
        ("Tabell 2", "occupation_group"),
        ("Tabell 1", "county"),
        ("Tabell 5", "industry"),
        ("Tabell V3", "education"),
    ]
    observations: list[dict[str, Any]] = []
    mappings: list[dict[str, Any]] = []
    for prefix, dimension_type in specs:
        matching_sheet = next((name for name in workbook if name.startswith(prefix)), None)
        if not matching_sheet:
            continue
        rows, map_rows = parse_shortage_table(
            workbook[matching_sheet],
            sheet_name=matching_sheet,
            source_file_id=source_file_id,
            year=attachment.file_year,
            dimension_type=dimension_type,
            by_code=by_code,
            by_label=by_label,
        )
        observations.extend(rows)
        mappings.extend(map_rows)
    return observations, mappings


def update_external_source(conn: Any, attachment: Attachment, row_count: int) -> None:
    with conn.cursor() as cur:
        cur.execute(
            """
            update public.external_data_sources
            set imported_at = now(),
                version = coalesce(%s::text, version),
                metadata = metadata || jsonb_build_object(
                  'import_status', 'imported',
                  'latest_period', %s::text,
                  'last_import', jsonb_build_object(
                    'file_name', %s::text,
                    'sha256', %s::text,
                    'row_count', %s::integer,
                    'imported_at', now()
                  )
                )
            where source_key = %s
            """,
            (
                f"{attachment.file_year}-{attachment.file_month:02d}" if attachment.file_year and attachment.file_month else (str(attachment.file_year) if attachment.file_year else None),
                f"{attachment.file_year}-{attachment.file_month:02d}" if attachment.file_year and attachment.file_month else (str(attachment.file_year) if attachment.file_year else None),
                attachment.file_name,
                attachment.sha256,
                row_count,
                attachment.source_key,
            ),
        )
    conn.commit()


def refresh_market_capacity(conn: Any) -> None:
    with conn.cursor() as cur:
        cur.execute("select to_regclass('public.mv_styrk_market_capacity')")
        if cur.fetchone()[0] is not None:
            cur.execute("refresh materialized view public.mv_styrk_market_capacity")
    conn.commit()


def run_dataset(conn: Any, dataset: str, cache_dir: Path, dry_run: bool) -> tuple[int, int]:
    attachment = download_attachment(dataset, cache_dir)
    workbook = read_xlsx(attachment.content)
    by_code, by_label = load_styrk_lookup(conn)
    source_file_id = 0
    if not dry_run:
        source_file_id = insert_source_file(conn, attachment)
    else:
        source_file_id = -1

    if dataset in ("unemployment", "vacancies"):
        rows, mappings = parse_monthly_workbook(workbook, attachment, source_file_id, by_code, by_label)
    else:
        rows, mappings = parse_business_survey(workbook, attachment, source_file_id, by_code, by_label)

    print(f"{dataset}: {attachment.file_name}")
    print(f"  attachment: {attachment.label}")
    print(f"  sheets: {len(workbook)}")
    print(f"  mappings: {len(mappings)}")
    print(f"  observations: {len(rows)}")

    if not dry_run:
        import_mappings(conn, mappings)
        if dataset in ("unemployment", "vacancies"):
            import_monthly_stats(conn, rows)
        else:
            import_shortage_rows(conn, rows)
        update_external_source(conn, attachment, len(rows))
    return len(mappings), len(rows)


def main() -> int:
    args = parse_args()
    load_dotenv(dotenv_path=".env")
    database_url = os.getenv("DATABASE_URL")
    if not database_url:
        print("DATABASE_URL is required. Put it in .env or export it.", file=sys.stderr)
        return 2

    import psycopg

    datasets = ["unemployment", "vacancies", "business-survey"] if args.dataset == "all" else [args.dataset]
    with psycopg.connect(database_url) as conn:
        total_rows = 0
        for dataset in datasets:
            _, row_count = run_dataset(conn, dataset, args.cache_dir.expanduser(), args.dry_run)
            total_rows += row_count
        if not args.dry_run:
            refresh_market_capacity(conn)
    print(f"NAV import complete. Rows parsed: {total_rows}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

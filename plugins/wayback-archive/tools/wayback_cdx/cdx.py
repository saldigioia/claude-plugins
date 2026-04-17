"""
Wayback CDX API interaction logic.

Uses Transport for all HTTP, so proxies/retries/rate-limits are transparent.
"""
from __future__ import annotations

import json
import logging
import re
from concurrent.futures import Future, ThreadPoolExecutor
from typing import Iterator
from urllib.parse import urlencode

from .transport import Transport, TransportError

log = logging.getLogger(__name__)

CDX_BASE = "https://web.archive.org/cdx/search/cdx"


CdxRow = tuple[str, str, str, str]  # (timestamp, original, statuscode, mimetype)


def _has_path(url: str) -> bool:
    """Return True if url contains a path component beyond the hostname."""
    # After sanitize_domain strips scheme and trailing slashes,
    # a bare domain like "twitter.com" has no slash,
    # while "twitter.com/kimkardashian" does.
    return "/" in url


def _cdx_query_params(url: str) -> dict[str, str]:
    """Build the url + matchType CDX params based on whether url has a path."""
    if _has_path(url):
        return {"url": url, "matchType": "prefix"}
    else:
        return {"url": f"{url}/*", "matchType": "domain"}


def fetch_num_pages(
    transport: Transport,
    domain: str,
    from_ts: str | None = None,
    to_ts: str | None = None,
) -> int:
    """Query CDX for total number of pages for a domain wildcard search."""
    params = {
        **_cdx_query_params(domain),
        "showNumPages": "true",
        "output": "text",
    }
    if from_ts:
        params["from"] = from_ts
    if to_ts:
        params["to"] = to_ts
    url = f"{CDX_BASE}?{urlencode(params)}"
    raw = transport.fetch(url).strip()

    if raw.isdigit():
        return int(raw)

    m = re.search(r"\d+", raw)
    if m:
        return int(m.group(0))

    raise ValueError(f"Could not parse page count from CDX response: {raw!r}")


def fetch_page(
    transport: Transport,
    domain: str,
    page: int,
    from_ts: str | None = None,
    to_ts: str | None = None,
) -> list[CdxRow]:
    """Fetch a single CDX page and return parsed rows."""
    params = {
        **_cdx_query_params(domain),
        "page": str(page),
        "fl": "timestamp,original,statuscode,mimetype",
        "output": "json",
    }
    if from_ts:
        params["from"] = from_ts
    if to_ts:
        params["to"] = to_ts
    url = f"{CDX_BASE}?{urlencode(params)}"
    text = transport.fetch(url).strip()

    if not text:
        return []

    rows: list[CdxRow] = []

    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        # Fallback: line-based parsing
        for line in text.splitlines():
            parts = line.split()
            if len(parts) >= 4 and parts[0].isdigit():
                rows.append((parts[0], parts[1], parts[2], parts[3]))
        return rows

    if not isinstance(data, list) or not data:
        return rows

    # Skip header row if present
    start = 1 if (
        isinstance(data[0], list)
        and len(data[0]) >= 2
        and data[0][:2] == ["timestamp", "original"]
    ) else 0

    for row in data[start:]:
        if not isinstance(row, list) or len(row) < 4:
            continue
        ts, original, status, mime = str(row[0]), str(row[1]), str(row[2]), str(row[3])
        if ts and original:
            rows.append((ts, original, status, mime))

    return rows


def iter_cdx_pages(
    transport: Transport,
    domain: str,
    total_pages: int,
    start_page: int = 0,
    from_ts: str | None = None,
    to_ts: str | None = None,
) -> Iterator[tuple[int, list[CdxRow]]]:
    """
    Yield (page_number, rows) for each CDX page.
    Starts from start_page for resume support.
    Raises TransportError on unrecoverable failure.
    """
    for page in range(start_page, total_pages):
        try:
            rows = fetch_page(transport, domain, page, from_ts=from_ts, to_ts=to_ts)
            yield page, rows
        except TransportError as e:
            log.error("Failed to fetch page %d after retries: %s", page, e)
            raise


def iter_cdx_pages_concurrent(
    transport: Transport,
    domain: str,
    total_pages: int,
    start_page: int = 0,
    from_ts: str | None = None,
    to_ts: str | None = None,
    max_workers: int = 3,
) -> Iterator[tuple[int, list[CdxRow]]]:
    """
    Concurrent version of iter_cdx_pages.
    Fetches up to max_workers pages in parallel via ThreadPoolExecutor,
    but yields (page_number, rows) in strict ascending order to preserve
    checkpoint invariants.
    """
    if max_workers <= 1 or total_pages - start_page <= 1:
        yield from iter_cdx_pages(transport, domain, total_pages, start_page, from_ts, to_ts)
        return

    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        pending: dict[int, Future[list[CdxRow]]] = {}
        next_to_submit = start_page
        next_to_yield = start_page

        def _fill_pending() -> None:
            nonlocal next_to_submit
            while len(pending) < max_workers and next_to_submit < total_pages:
                fut = executor.submit(
                    fetch_page, transport, domain, next_to_submit,
                    from_ts, to_ts,
                )
                pending[next_to_submit] = fut
                next_to_submit += 1

        _fill_pending()

        try:
            while next_to_yield < total_pages and next_to_yield in pending:
                try:
                    rows = pending[next_to_yield].result()
                except TransportError:
                    for page_num, fut in pending.items():
                        if page_num != next_to_yield:
                            fut.cancel()
                    raise

                del pending[next_to_yield]
                yield next_to_yield, rows
                next_to_yield += 1
                _fill_pending()
        except KeyboardInterrupt:
            for fut in pending.values():
                fut.cancel()
            raise


def sanitize_domain(domain: str) -> str:
    d = domain.strip().lower()
    d = re.sub(r"^https?://", "", d)
    d = d.strip("/")
    if not d:
        raise ValueError("Empty domain.")
    return d

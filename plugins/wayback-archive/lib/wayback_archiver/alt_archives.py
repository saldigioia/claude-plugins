"""
Alternative archive sources — archive.today and Memento Time Travel.

These serve as fallback discovery and fetch sources after the primary
Wayback Machine + CommonCrawl cascade is exhausted.
"""
from __future__ import annotations

import asyncio
import json
import logging
import re
import time
from dataclasses import dataclass, field
from typing import Optional
from urllib.parse import urlparse

import aiohttp

from .http_client import AIOHTTP_HEADERS, parse_retry_after

log = logging.getLogger(__name__)


# Per-host circuit breaker. Without this, enabling alternative_archives on a
# dead site spends ~15s × 2 archives × N products on timeouts (observed on
# pablosupply: 228 lookups × 30s ≈ 114 minutes for zero hits).
_ALT_BREAKER_MISS_THRESHOLD = 3
_ALT_BREAKER_COOLDOWN_SEC = 600.0  # 10 minutes


@dataclass
class _AltBreaker:
    """(archive_name, host) → consecutive-miss tracker with time-based cooldown.

    A lookup is a "hit" if it returned >=1 snapshot or fetched bytes. Three
    consecutive misses on the same (archive, host) tuple trip the breaker for
    10 minutes, after which the count resets and lookups resume. Hits reset
    the counter immediately.
    """
    _misses: dict[tuple[str, str], int] = field(default_factory=dict, repr=False)
    _tripped_at: dict[tuple[str, str], float] = field(default_factory=dict, repr=False)

    def should_skip(self, archive: str, host: str) -> bool:
        key = (archive, host)
        tripped = self._tripped_at.get(key)
        if tripped is None:
            return False
        if time.time() - tripped >= _ALT_BREAKER_COOLDOWN_SEC:
            self._tripped_at.pop(key, None)
            self._misses[key] = 0
            log.info("  alt_archives breaker cooldown elapsed for %s/%s", archive, host)
            return False
        return True

    def record_hit(self, archive: str, host: str) -> None:
        self._misses[(archive, host)] = 0

    def record_miss(self, archive: str, host: str) -> None:
        key = (archive, host)
        self._misses[key] = self._misses.get(key, 0) + 1
        if self._misses[key] >= _ALT_BREAKER_MISS_THRESHOLD and key not in self._tripped_at:
            self._tripped_at[key] = time.time()
            log.warning(
                "  alt_archives breaker tripped for %s/%s (%d misses) — cooldown %.0fs",
                archive, host, self._misses[key], _ALT_BREAKER_COOLDOWN_SEC,
            )


_breaker = _AltBreaker()


def _host_of(url: str) -> str:
    try:
        host = urlparse(url).hostname or ""
    except ValueError:
        return ""
    return host.lower().rstrip(".")


async def archive_today_lookup(
    session: aiohttp.ClientSession,
    url: str,
    timeout: float = 15.0,
) -> list[dict]:
    """Query archive.today's timemap for available captures of a URL.

    Returns a list of snapshot dicts with keys: url, datetime, archive_url.
    Returns empty list on failure or if no captures exist.

    API: https://archive.ph/timemap/json/{url}
    """
    host = _host_of(url)
    if host and _breaker.should_skip("archive_today", host):
        return []

    api_url = f"https://archive.ph/timemap/json/{url}"

    try:
        async with session.get(
            api_url,
            timeout=aiohttp.ClientTimeout(total=timeout),
            headers=AIOHTTP_HEADERS,
        ) as resp:
            log.debug("  archive.today %s: HTTP %d", url[:60], resp.status)

            if resp.status != 200:
                if resp.status == 429:
                    retry_after = parse_retry_after(resp.headers.get("Retry-After"))
                    if retry_after:
                        log.warning("  429 rate-limited; Retry-After=%.0fs", retry_after)
                if host:
                    _breaker.record_miss("archive_today", host)
                return []

            text = await resp.text()
            if not text.strip():
                if host:
                    _breaker.record_miss("archive_today", host)
                return []

            # Response is a JSON array of [rel, url, datetime] tuples
            # or a JSON object with memento links
            try:
                data = json.loads(text)
            except json.JSONDecodeError as e:
                log.debug("  archive.today JSON decode failed for %s: %s", url[:60], e)
                if host:
                    _breaker.record_miss("archive_today", host)
                return []

            snapshots = []
            if isinstance(data, list):
                for entry in data:
                    if isinstance(entry, dict):
                        snapshots.append({
                            "url": url,
                            "datetime": entry.get("datetime", ""),
                            "archive_url": entry.get("uri", ""),
                        })
                    elif isinstance(entry, list) and len(entry) >= 2:
                        snapshots.append({
                            "url": url,
                            "datetime": entry[2] if len(entry) > 2 else "",
                            "archive_url": entry[1],
                        })
            elif isinstance(data, dict):
                # Memento-style response
                for key in ("memento", "mementos"):
                    mementos = data.get(key, [])
                    if isinstance(mementos, list):
                        for m in mementos:
                            if isinstance(m, dict) and m.get("uri"):
                                snapshots.append({
                                    "url": url,
                                    "datetime": m.get("datetime", ""),
                                    "archive_url": m["uri"],
                                })

            log.debug("  archive.today found %d snapshots for %s", len(snapshots), url[:60])
            if host:
                if snapshots:
                    _breaker.record_hit("archive_today", host)
                else:
                    _breaker.record_miss("archive_today", host)
            return snapshots

    except (aiohttp.ClientError, TimeoutError) as e:
        log.debug("  archive.today error for %s: %s", url[:60], e)
        if host:
            _breaker.record_miss("archive_today", host)
        return []


async def memento_lookup(
    session: aiohttp.ClientSession,
    url: str,
    timeout: float = 15.0,
) -> list[dict]:
    """Query Memento Time Travel for cross-archive captures of a URL.

    Queries timetravel.mementoweb.org which aggregates results from dozens
    of web archives (national libraries, university archives, etc.).

    Returns a list of snapshot dicts with keys: url, datetime, archive_url, archive_name.
    Returns empty list on failure or if no captures exist.

    API: https://timetravel.mementoweb.org/timemap/json/{url}
    """
    host = _host_of(url)
    if host and _breaker.should_skip("memento", host):
        return []

    api_url = f"https://timetravel.mementoweb.org/timemap/json/{url}"

    try:
        async with session.get(
            api_url,
            timeout=aiohttp.ClientTimeout(total=timeout),
            headers=AIOHTTP_HEADERS,
        ) as resp:
            log.debug("  memento %s: HTTP %d", url[:60], resp.status)

            if resp.status != 200:
                if resp.status == 429:
                    retry_after = parse_retry_after(resp.headers.get("Retry-After"))
                    if retry_after:
                        log.warning("  429 rate-limited; Retry-After=%.0fs", retry_after)
                if host:
                    _breaker.record_miss("memento", host)
                return []

            text = await resp.text()
            if not text.strip():
                if host:
                    _breaker.record_miss("memento", host)
                return []

            try:
                data = json.loads(text)
            except json.JSONDecodeError as e:
                log.debug("  memento JSON decode failed for %s: %s", url[:60], e)
                if host:
                    _breaker.record_miss("memento", host)
                return []

            snapshots = []

            # Memento timemap returns a dict with "mementos" key
            mementos = data.get("mementos", {})

            # "list" contains all individual mementos
            memento_list = mementos.get("list", [])
            if isinstance(memento_list, list):
                for m in memento_list:
                    if not isinstance(m, dict):
                        continue
                    archive_url = m.get("uri", "")
                    if not archive_url:
                        continue

                    # Determine which archive this is from
                    archive_name = "unknown"
                    if "archive.org" in archive_url:
                        archive_name = "internet_archive"
                    elif "archive.ph" in archive_url or "archive.today" in archive_url:
                        archive_name = "archive_today"
                    elif "commoncrawl" in archive_url:
                        archive_name = "commoncrawl"
                    elif "perma.cc" in archive_url:
                        archive_name = "perma_cc"
                    elif "webcitation.org" in archive_url:
                        archive_name = "webcitation"
                    else:
                        dm = re.match(r"https?://([^/]+)", archive_url)
                        if dm:
                            archive_name = dm.group(1)

                    snapshots.append({
                        "url": url,
                        "datetime": m.get("datetime", ""),
                        "archive_url": archive_url,
                        "archive_name": archive_name,
                    })

            log.debug("  memento found %d snapshots for %s across %d archives",
                      len(snapshots), url[:60],
                      len(set(s["archive_name"] for s in snapshots)))
            if host:
                if snapshots:
                    _breaker.record_hit("memento", host)
                else:
                    _breaker.record_miss("memento", host)
            return snapshots

    except (aiohttp.ClientError, TimeoutError) as e:
        log.debug("  memento error for %s: %s", url[:60], e)
        if host:
            _breaker.record_miss("memento", host)
        return []


async def fetch_from_archive_today(
    session: aiohttp.ClientSession,
    archive_url: str,
    timeout: float = 30.0,
) -> Optional[bytes]:
    """Fetch content from an archive.today snapshot URL.

    Returns the raw HTML bytes or None on failure.
    """
    try:
        async with session.get(
            archive_url,
            timeout=aiohttp.ClientTimeout(total=timeout),
            headers=AIOHTTP_HEADERS,
        ) as resp:
            if resp.status != 200:
                return None
            content = await resp.read()
            if len(content) < 500:
                return None
            return content
    except (aiohttp.ClientError, TimeoutError):
        return None


async def fallback_fetch(
    session: aiohttp.ClientSession,
    original_url: str,
    enabled_archives: list[str] | None = None,
) -> Optional[bytes]:
    """Try alternative archives as a last resort after Wayback + CC fail.

    Steps:
      1. archive.today lookup → fetch best snapshot
      2. Memento lookup → fetch from best non-Wayback/CC archive

    Args:
        session: aiohttp session
        original_url: the original (non-archived) URL
        enabled_archives: list of archive names to try, e.g. ["archive_today", "memento"]
                         Defaults to both if None.

    Returns: raw HTML bytes or None
    """
    if enabled_archives is None:
        enabled_archives = ["archive_today", "memento"]

    # Step 1: archive.today
    if "archive_today" in enabled_archives:
        snapshots = await archive_today_lookup(session, original_url)
        if snapshots:
            # Try the most recent snapshot
            sorted_snaps = sorted(snapshots, key=lambda s: s.get("datetime", ""), reverse=True)
            for snap in sorted_snaps[:3]:
                content = await fetch_from_archive_today(session, snap["archive_url"])
                if content:
                    log.info("  Fetched from archive.today: %s", original_url[:60])
                    return content
                await asyncio.sleep(1.0)

    # Step 2: Memento
    if "memento" in enabled_archives:
        snapshots = await memento_lookup(session, original_url)
        if snapshots:
            # Filter out Wayback and CommonCrawl (we already tried those)
            alt_snaps = [
                s for s in snapshots
                if s["archive_name"] not in ("internet_archive", "commoncrawl")
            ]
            sorted_snaps = sorted(alt_snaps, key=lambda s: s.get("datetime", ""), reverse=True)
            for snap in sorted_snaps[:3]:
                try:
                    async with session.get(
                        snap["archive_url"],
                        timeout=aiohttp.ClientTimeout(total=30),
                        headers=AIOHTTP_HEADERS,
                    ) as resp:
                        if resp.status == 200:
                            content = await resp.read()
                            if content and len(content) > 500:
                                log.info("  Fetched from %s: %s",
                                         snap["archive_name"], original_url[:60])
                                return content
                except (aiohttp.ClientError, TimeoutError):
                    pass
                await asyncio.sleep(1.0)

    return None

"""
Shared HTTP client hygiene for wayback-archive.

Every outbound request from this plugin must:
  1. Identify the caller as an AI agent (per archive.org policy — see
     `docs/integrations-internet-archive.md` Vector 1).
  2. Honor `Retry-After` headers on 429 / 503 responses.

This module is the single source of truth for the User-Agent string. Import
`USER_AGENT` / `AIOHTTP_HEADERS` / `make_requests_session()` from here; do
not hand-roll UA strings in caller code.

Wayback Machine *replay* endpoints (`web.archive.org/web/...id_/`) need a
browser-like UA to satisfy the JS replay framework. For those sites,
compose `BROWSER_UA + " " + USER_AGENT_SUFFIX` so we stay browser-compatible
while still appearing in IA's telemetry as an AI agent — the pattern
archive.org's own `ia` skill recommends (default UA + agent suffix).
"""
from __future__ import annotations

import json
from email.utils import parsedate_to_datetime
from datetime import datetime, timezone
from pathlib import Path

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry


# ── Version discovery ────────────────────────────────────────────────────────

def _read_version() -> str:
    """Read version from plugin.json. Cheap and robust; falls back on unknown."""
    manifest = Path(__file__).resolve().parents[2] / ".claude-plugin" / "plugin.json"
    try:
        return str(json.loads(manifest.read_text()).get("version", "unknown"))
    except (OSError, json.JSONDecodeError):
        return "unknown"


__version__ = _read_version()


# ── User-Agent strings ───────────────────────────────────────────────────────

USER_AGENT_SUFFIX = (
    f"wayback-archive/{__version__} "
    "(Claude Code AI agent; +https://github.com/saldigioia/wayback-archive-plugin)"
)

# Bot-identifying UA for archive.org APIs, CommonCrawl S3, archive.today,
# Memento — endpoints that expect programmatic clients.
USER_AGENT = USER_AGENT_SUFFIX

# Browser-compatible UA for Wayback Machine replay endpoints
# (web.archive.org/web/...id_/). The JS replay framework degrades poorly for
# non-browser clients, so we keep the Mozilla string as the base and append
# our identifier as a suffix — the "default UA + agent suffix" pattern the
# Internet Archive's own `ia` skill recommends.
BROWSER_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 "
    + USER_AGENT_SUFFIX
)


# ── Ready-to-use header dicts ────────────────────────────────────────────────

DEFAULT_HEADERS = {"User-Agent": USER_AGENT}
BROWSER_HEADERS = {"User-Agent": BROWSER_UA}

# For `aiohttp.ClientSession(headers=...)` — same shape, kept as a separate
# constant so intent at the call site is obvious.
AIOHTTP_HEADERS = dict(DEFAULT_HEADERS)
AIOHTTP_BROWSER_HEADERS = dict(BROWSER_HEADERS)


# ── requests.Session factory ─────────────────────────────────────────────────

def make_requests_session(
    *,
    browser_ua: bool = False,
    total_retries: int = 3,
    backoff_factor: float = 1.0,
    status_forcelist: tuple[int, ...] = (429, 500, 502, 503, 504),
) -> requests.Session:
    """Build a `requests.Session` pre-wired with the shared UA + sensible retries.

    Use `browser_ua=True` for Wayback Machine replay endpoints; the default
    (bot UA) is correct for archive.org APIs, CommonCrawl, and most CDNs.
    """
    s = requests.Session()
    s.headers["User-Agent"] = BROWSER_UA if browser_ua else USER_AGENT
    retry = Retry(
        total=total_retries,
        backoff_factor=backoff_factor,
        status_forcelist=status_forcelist,
        allowed_methods=("HEAD", "GET", "OPTIONS"),
        respect_retry_after_header=True,
    )
    adapter = HTTPAdapter(max_retries=retry)
    s.mount("https://", adapter)
    s.mount("http://", adapter)
    return s


# ── Retry-After parsing ──────────────────────────────────────────────────────

def parse_retry_after(value: str | None) -> float | None:
    """Parse a Retry-After header value into seconds.

    Accepts both delta-seconds form ("30") and HTTP-date form
    ("Wed, 21 Oct 2026 07:28:00 GMT"). Returns None if unparseable or the
    date is in the past.
    """
    if not value:
        return None
    v = value.strip()
    try:
        seconds = float(v)
        return max(0.0, seconds)
    except ValueError:
        pass
    try:
        dt = parsedate_to_datetime(v)
    except (TypeError, ValueError):
        return None
    if dt is None:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    delta = (dt - datetime.now(timezone.utc)).total_seconds()
    return max(0.0, delta)


__all__ = [
    "USER_AGENT",
    "USER_AGENT_SUFFIX",
    "BROWSER_UA",
    "DEFAULT_HEADERS",
    "BROWSER_HEADERS",
    "AIOHTTP_HEADERS",
    "AIOHTTP_BROWSER_HEADERS",
    "make_requests_session",
    "parse_retry_after",
    "__version__",
]

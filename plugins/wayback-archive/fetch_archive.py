#!/usr/bin/env python3
"""
fetch_archive.py — Multi-strategy archived webpage fetcher.

Reads a filtered links.txt (one Wayback URL per line) and fetches each page
using a tiered cascade:

  Tier 1: oEmbed / Atom / JSON  → curl-style GET with id_ via ISP proxy
  Tier 2: HTML product pages    → CommonCrawl WARC lookup, then proxy fallback
  Tier 3: Collection / homepage → CommonCrawl WARC lookup, then proxy fallback

Proxied requests rotate across Oxylabs ISP ports 8001-8020. CommonCrawl WARC
fetches go direct (no proxy needed — S3 doesn't rate-limit).

Usage:
    # Fetch all URLs in links.txt
    python fetch_archive.py links.txt

    # Fetch with datacenter proxies instead of ISP
    python fetch_archive.py links.txt --proxy dc

    # Dry run — show what would be fetched and how
    python fetch_archive.py links.txt --dry-run

    # Resume a previous run (skips already-downloaded files)
    python fetch_archive.py links.txt --resume

    # Limit concurrency
    python fetch_archive.py links.txt --workers 3

Environment variables (optional, override hardcoded defaults):
    OXYLABS_ISP_USER, OXYLABS_ISP_PASS
    OXYLABS_DC_USER, OXYLABS_DC_PASS
"""
from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import logging
import os
import re
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional
from urllib.parse import quote

import aiohttp

# Make the shared HTTP hygiene module importable whether fetch_archive.py is
# run as a script (cwd=repo root) or imported from run_stage.py.
_HERE = Path(__file__).resolve().parent
if str(_HERE / "lib") not in sys.path:
    sys.path.insert(0, str(_HERE / "lib"))
from wayback_archiver.http_client import (
    BROWSER_UA, USER_AGENT, AIOHTTP_HEADERS, parse_retry_after,
)
from wayback_archiver.env import load_env

load_env()

# ── Logging ────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-5s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("fetch_archive")

# ── Proxy Configuration ───────────────────────────────────────────────────

@dataclass
class ProxyConfig:
    host: str
    username: str
    password: str
    port_min: int = 8001
    port_max: int = 8020
    _next_port: int = field(default=8001, repr=False)

    def next_proxy_url(self) -> str:
        """Round-robin through ports for even distribution."""
        port = self._next_port
        self._next_port = self.port_min + (
            (self._next_port - self.port_min + 1) % (self.port_max - self.port_min + 1)
        )
        user = quote(self.username, safe="")
        pw = quote(self.password, safe="")
        return f"http://{user}:{pw}@{self.host}:{port}"


# Default proxy configs — override via env vars
ISP_PROXY = ProxyConfig(
    host="isp.oxylabs.io",
    username=os.environ.get("OXYLABS_ISP_USER", "salthecowboy_Yyegj"),
    password=os.environ.get("OXYLABS_ISP_PASS", "Kif0dl2=24P~lk9"),
)

DC_PROXY = ProxyConfig(
    host="dc.pr.oxylabs.io",
    username=os.environ.get("OXYLABS_DC_USER", "salthecowboy_5MnlE"),
    password=os.environ.get("OXYLABS_DC_PASS", "EbS1WC5~adK8Tw"),
)

# ── URL Classification ────────────────────────────────────────────────────

@dataclass
class FetchTarget:
    wayback_url: str
    original_url: str
    timestamp: str
    tier: str           # "structured", "html", "collection", "homepage"
    method: str = ""    # filled during fetch: "id_", "commoncrawl", "proxy"
    filename: str = ""

    @staticmethod
    def from_wayback_url(url: str) -> FetchTarget:
        """Parse a Wayback URL into its components."""
        # https://web.archive.org/web/20220527214136/https://www.yeezygap.com/...
        m = re.match(r"https://web\.archive\.org/web/(\d+)/(https?://.+)", url)
        if not m:
            raise ValueError(f"Not a valid Wayback URL: {url}")

        timestamp, original = m.group(1), m.group(2)

        # Classify
        path = re.sub(r"https?://[^/]+", "", original).split("?")[0].lower()
        if path.endswith(".oembed") or path.endswith(".atom") or path.endswith(".json"):
            tier = "structured"
        elif "/products/" in path:
            tier = "html"
        elif "/collections/" in path:
            tier = "collection"
        else:
            tier = "homepage"

        return FetchTarget(
            wayback_url=url,
            original_url=original,
            timestamp=timestamp,
            tier=tier,
            filename=_safe_filename(original),
        )


def _safe_filename(url: str, max_length: int = 200) -> str:
    """Create a filesystem-safe filename from a URL."""
    clean = url.replace("https://", "").replace("http://", "")
    safe = re.sub(r'[<>:"/\\|?*]', "_", clean).replace("/", "_")
    if len(safe) > max_length:
        h = hashlib.md5(url.encode()).hexdigest()[:8]
        safe = f"{safe[:max_length - 9]}_{h}"
    return safe + ".html"


# ── CommonCrawl WARC Lookup ───────────────────────────────────────────────

# Recent CommonCrawl crawl IDs — query all of them for best coverage
# Update this list periodically from https://index.commoncrawl.org/collinfo.json
CC_CRAWLS = [
    "CC-MAIN-2026-09", "CC-MAIN-2025-51", "CC-MAIN-2025-43",
    "CC-MAIN-2025-34", "CC-MAIN-2025-26", "CC-MAIN-2025-18",
    "CC-MAIN-2025-08", "CC-MAIN-2024-51", "CC-MAIN-2024-42",
    "CC-MAIN-2024-33", "CC-MAIN-2024-26", "CC-MAIN-2024-18",
    "CC-MAIN-2024-10", "CC-MAIN-2023-50", "CC-MAIN-2023-40",
    "CC-MAIN-2023-23", "CC-MAIN-2023-14", "CC-MAIN-2023-06",
    "CC-MAIN-2022-49", "CC-MAIN-2022-40", "CC-MAIN-2022-33",
    "CC-MAIN-2022-27", "CC-MAIN-2022-21", "CC-MAIN-2022-05",
]

# Cache CC index lookups across targets to avoid redundant queries
_cc_cache: dict[str, Optional[dict]] = {}

# Domain-level negative cache: once a domain misses N crawls, skip CC entirely
_cc_domain_misses: dict[str, int] = {}
CC_DOMAIN_MISS_THRESHOLD = 3  # Give up on a domain after 3 consecutive crawl misses
CC_MAX_CRAWLS_PER_URL = 4     # Don't try all 24 crawls — diminishing returns


def _domain_from_url(url: str) -> str:
    m = re.match(r"https?://([^/]+)", url)
    return m.group(1).lower() if m else ""


async def cc_index_lookup(
    session: aiohttp.ClientSession,
    original_url: str,
    semaphore: asyncio.Semaphore,
) -> Optional[dict]:
    """Query CommonCrawl CDX index for WARC coordinates of a URL.

    Returns dict with {filename, offset, length} or None.
    Tries a limited number of crawl indices, returns the first hit.
    Skips entirely if the domain has already missed enough times.
    """
    cache_key = original_url.split("?")[0].lower()
    if cache_key in _cc_cache:
        return _cc_cache[cache_key]

    domain = _domain_from_url(original_url)
    if _cc_domain_misses.get(domain, 0) >= CC_DOMAIN_MISS_THRESHOLD:
        log.debug("  Skipping CC for %s (domain already missed %d times)", domain, _cc_domain_misses[domain])
        _cc_cache[cache_key] = None
        return None

    for crawl_id in CC_CRAWLS[:CC_MAX_CRAWLS_PER_URL]:
        api_url = (
            f"https://index.commoncrawl.org/{crawl_id}-index"
            f"?url={original_url}&output=json&limit=1"
        )
        async with semaphore:
            try:
                async with session.get(api_url, timeout=aiohttp.ClientTimeout(total=15)) as resp:
                    if resp.status != 200:
                        continue
                    text = await resp.text()
                    if not text.strip():
                        continue
                    # CC returns NDJSON — take the first line
                    record = json.loads(text.strip().split("\n")[0])
                    if record.get("status") == "200":
                        result = {
                            "filename": record["filename"],
                            "offset": int(record["offset"]),
                            "length": int(record["length"]),
                            "crawl": crawl_id,
                        }
                        _cc_cache[cache_key] = result
                        # Reset domain misses on success
                        _cc_domain_misses[domain] = 0
                        return result
            except (aiohttp.ClientError, asyncio.TimeoutError, json.JSONDecodeError, KeyError):
                continue
            finally:
                await asyncio.sleep(0.5)

    _cc_cache[cache_key] = None
    _cc_domain_misses[domain] = _cc_domain_misses.get(domain, 0) + 1
    log.debug("  CC miss for %s (domain miss count: %d)", original_url[:60], _cc_domain_misses[domain])
    return None


async def fetch_cc_warc(
    session: aiohttp.ClientSession,
    warc_info: dict,
) -> Optional[bytes]:
    """Fetch a single WARC record from CommonCrawl S3 via HTTP Range request.

    Returns the raw HTTP response body (HTML) or None on failure.
    """
    offset = warc_info["offset"]
    end = offset + warc_info["length"] - 1
    url = f"https://data.commoncrawl.org/{warc_info['filename']}"

    try:
        headers = {"Range": f"bytes={offset}-{end}"}
        async with session.get(url, headers=headers, timeout=aiohttp.ClientTimeout(total=30)) as resp:
            if resp.status not in (200, 206):
                return None
            raw = await resp.read()

            # Decompress gzip
            import gzip
            try:
                decompressed = gzip.decompress(raw)
            except (OSError, EOFError) as e:
                log.debug("gzip decompress failed for %s: %s", url, e)
                return None

            # WARC record = WARC headers + HTTP headers + body
            # Split on double CRLF to find the HTTP response, then again for the body
            text = decompressed.decode("utf-8", errors="replace")

            # Find the HTTP response section (after WARC headers)
            http_start = text.find("HTTP/")
            if http_start == -1:
                return None

            # Find body (after HTTP headers)
            body_start = text.find("\r\n\r\n", http_start)
            if body_start == -1:
                return None

            body = text[body_start + 4:]

            # Validate it looks like HTML
            if "<html" not in body[:2000].lower() and "<head" not in body[:2000].lower():
                # Might still be valid — some pages start with doctype
                if "<!doctype" not in body[:500].lower() and len(body) < 500:
                    return None

            return body.encode("utf-8")

    except (aiohttp.ClientError, asyncio.TimeoutError):
        return None


# ── Wayback Fetch (direct first, proxy fallback) ─────────────────────────

_WB_HEADERS = {
    # Wayback's replay framework degrades for non-browser clients, so we keep
    # the Mozilla string as base and append our AI-agent suffix (the pattern
    # the Internet Archive's own `ia` skill endorses).
    "User-Agent": BROWSER_UA,
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
}


def _id_url(wayback_url: str) -> str:
    """Insert id_ modifier for raw Wayback content."""
    return re.sub(r"(web\.archive\.org/web/\d+)(/)", r"\1id_\2", wayback_url)


async def fetch_wayback_direct(
    session: aiohttp.ClientSession,
    target: FetchTarget,
    semaphore: asyncio.Semaphore,
    max_retries: int = 3,
) -> Optional[bytes]:
    """Fetch a Wayback id_ URL directly (no proxy)."""
    id_url = _id_url(target.wayback_url)

    for attempt in range(max_retries):
        async with semaphore:
            try:
                async with session.get(
                    id_url,
                    timeout=aiohttp.ClientTimeout(total=30),
                    allow_redirects=True,
                    headers=_WB_HEADERS,
                ) as resp:
                    if resp.status == 429:
                        retry_after = parse_retry_after(resp.headers.get("Retry-After"))
                        wait = retry_after if retry_after is not None else 5.0 * (2 ** attempt)
                        src = "Retry-After" if retry_after is not None else "backoff"
                        log.warning("  429 rate-limited (direct, %s), waiting %.1fs", src, wait)
                        await asyncio.sleep(wait)
                        continue
                    if resp.status == 503:
                        # Wayback overloaded — back off
                        wait = 3.0 * (2 ** attempt)
                        log.warning("  503 overloaded (direct), waiting %.1fs", wait)
                        await asyncio.sleep(wait)
                        continue
                    if resp.status != 200:
                        log.debug("  Direct HTTP %d on attempt %d", resp.status, attempt + 1)
                        await asyncio.sleep(0.5)
                        continue

                    content = await resp.read()
                    min_size = 50 if target.tier == "structured" else 1000
                    if len(content) < min_size:
                        continue
                    return content

            except (aiohttp.ClientError, asyncio.TimeoutError) as e:
                log.debug("  Direct error attempt %d: %s", attempt + 1, e)
                await asyncio.sleep(2.0 * (attempt + 1))
                continue
    return None


async def fetch_wayback_proxied(
    session: aiohttp.ClientSession,
    target: FetchTarget,
    proxy_config: ProxyConfig,
    semaphore: asyncio.Semaphore,
    max_retries: int = 3,
) -> Optional[bytes]:
    """Fetch a Wayback id_ URL through proxy (fallback when direct fails)."""
    id_url = _id_url(target.wayback_url)

    for attempt in range(max_retries):
        proxy_url = proxy_config.next_proxy_url()
        async with semaphore:
            try:
                async with session.get(
                    id_url,
                    proxy=proxy_url,
                    timeout=aiohttp.ClientTimeout(total=45),
                    allow_redirects=True,
                    headers=_WB_HEADERS,
                ) as resp:
                    if resp.status == 429:
                        retry_after = parse_retry_after(resp.headers.get("Retry-After"))
                        wait = retry_after if retry_after is not None else 2.0 * (2 ** attempt)
                        src = "Retry-After" if retry_after is not None else "backoff"
                        log.warning("  429 rate-limited (proxy, %s), waiting %.1fs (attempt %d)", src, wait, attempt + 1)
                        await asyncio.sleep(wait)
                        continue

                    if resp.status != 200:
                        log.debug("  Proxy HTTP %d on attempt %d", resp.status, attempt + 1)
                        continue

                    content = await resp.read()
                    min_size = 50 if target.tier == "structured" else 1000
                    if len(content) < min_size:
                        continue
                    return content

            except (aiohttp.ClientError, asyncio.TimeoutError) as e:
                wait = 0.5 * (2 ** attempt)
                log.debug("  Proxy error attempt %d: %s, retrying in %.1fs", attempt + 1, e, wait)
                await asyncio.sleep(wait)
                continue

    return None


# ── Anti-Bot / Quality Validation ─────────────────────────────────────────

ANTIBOT_SIGNATURES = [
    b"Access Denied",
    b"Akamai Technologies",
    b"akamaized.net",
    b"cf-browser-verification",
    b"challenge-platform",
    b"Checking your browser",
    b"Just a moment",
    b"Enable JavaScript and cookies",
]


def validate_content(content: bytes, tier: str) -> bool:
    """Check that fetched content is real product data, not junk."""
    if not content:
        return False

    # Size gate
    if tier == "structured" and len(content) < 50:
        return False
    if tier != "structured" and len(content) < 1000:
        return False

    # Anti-bot check (HTML only)
    if tier != "structured":
        for sig in ANTIBOT_SIGNATURES:
            if sig in content[:5000]:
                return False

    # Wayback wrapper check
    if b"_wm.wombat" in content[:5000] and len(content) < 10000:
        return False

    return True


# ── Main Fetch Orchestrator ───────────────────────────────────────────────

@dataclass
class FetchResult:
    target: FetchTarget
    success: bool
    method: str
    size: int = 0
    error: str = ""


async def fetch_one(
    target: FetchTarget,
    session: aiohttp.ClientSession,
    proxy_config: ProxyConfig,
    output_dir: Path,
    direct_sem: asyncio.Semaphore,
    proxy_sem: asyncio.Semaphore,
    cc_sem: asyncio.Semaphore,
    resume: bool = False,
) -> FetchResult:
    """Fetch a single target using the tiered cascade:
    1. Direct Wayback id_ fetch (fastest, no proxy needed)
    2. CommonCrawl WARC lookup (for HTML pages)
    3. Proxy fallback (if direct is rate-limited)
    """

    dest = output_dir / target.filename
    if resume and dest.exists() and dest.stat().st_size > 0:
        return FetchResult(target, True, "cached", dest.stat().st_size)

    content: Optional[bytes] = None

    # ── Step 1: Direct Wayback fetch (all tiers) ─────────────────────
    content = await fetch_wayback_direct(session, target, direct_sem)
    if content and validate_content(content, target.tier):
        dest.write_bytes(content)
        return FetchResult(target, True, "direct_id", len(content))

    # ── Step 2: CommonCrawl WARC (HTML/collection/homepage only) ─────
    if target.tier != "structured":
        warc_info = await cc_index_lookup(session, target.original_url, cc_sem)
        if warc_info:
            content = await fetch_cc_warc(session, warc_info)
            if content and validate_content(content, target.tier):
                dest.write_bytes(content)
                return FetchResult(target, True, f"commoncrawl:{warc_info['crawl']}", len(content))

    # ── Step 3: Proxy fallback ───────────────────────────────────────
    content = await fetch_wayback_proxied(session, target, proxy_config, proxy_sem)
    if content and validate_content(content, target.tier):
        dest.write_bytes(content)
        return FetchResult(target, True, "id_proxy", len(content))

    return FetchResult(target, False, "all", 0, "all methods exhausted")


async def run(
    links_file: Path,
    output_dir: Path,
    proxy_type: str,
    workers: int,
    resume: bool,
    dry_run: bool,
):
    """Main entry point — parse links, classify, fetch."""

    urls = [l.strip() for l in links_file.read_text().splitlines() if l.strip()]
    targets = []
    for url in urls:
        try:
            targets.append(FetchTarget.from_wayback_url(url))
        except ValueError as e:
            log.warning("Skipping invalid URL: %s", e)

    # Sort: structured first (fastest, cheapest), then HTML, then collections
    tier_order = {"structured": 0, "html": 1, "collection": 2, "homepage": 3}
    targets.sort(key=lambda t: tier_order.get(t.tier, 99))

    # Stats
    by_tier = {}
    for t in targets:
        by_tier[t.tier] = by_tier.get(t.tier, 0) + 1

    log.info("Loaded %d targets from %s", len(targets), links_file)
    for tier, count in sorted(by_tier.items(), key=lambda x: tier_order.get(x[0], 99)):
        log.info("  %s: %d", tier, count)

    if dry_run:
        log.info("[DRY RUN] Would fetch %d URLs with %d workers via %s proxy", len(targets), workers, proxy_type)
        for t in targets[:10]:
            log.info("  [%s] %s", t.tier, t.original_url)
        if len(targets) > 10:
            log.info("  ... and %d more", len(targets) - 10)
        return

    output_dir.mkdir(parents=True, exist_ok=True)
    proxy_config = ISP_PROXY if proxy_type == "isp" else DC_PROXY

    # Semaphores
    direct_sem = asyncio.Semaphore(10)  # Direct Wayback — generous, no proxy cost
    proxy_sem = asyncio.Semaphore(workers)
    cc_sem = asyncio.Semaphore(4)

    results: list[FetchResult] = []
    t0 = time.time()
    total = len(targets)

    async def _worker(queue: asyncio.Queue):
        """Pull targets from queue, fetch, log progress."""
        async with aiohttp.ClientSession(
            connector=aiohttp.TCPConnector(limit_per_host=6),
            headers=AIOHTTP_HEADERS,  # bot UA; per-request BROWSER_UA override via _WB_HEADERS
        ) as session:
            while True:
                target = await queue.get()
                try:
                    result = await fetch_one(
                        target, session, proxy_config, output_dir,
                        direct_sem, proxy_sem, cc_sem, resume,
                    )
                    results.append(result)

                    status = "OK" if result.success else "FAIL"
                    size_str = f"{result.size:,}B" if result.success else result.error
                    elapsed = time.time() - t0
                    rate = len(results) / elapsed if elapsed > 0 else 0

                    log.info(
                        "[%d/%d] [%s] [%s] %s — %s  (%.1f/min)",
                        len(results), total, status, result.method,
                        result.target.original_url[:80], size_str, rate * 60,
                    )
                except Exception as e:
                    results.append(FetchResult(target, False, "error", 0, str(e)))
                    log.error("[%d/%d] [ERROR] %s — %s", len(results), total, target.original_url[:80], e)
                finally:
                    queue.task_done()

    # Feed targets through a queue with bounded workers instead of
    # launching all tasks simultaneously (which causes Wayback 429 storms)
    queue: asyncio.Queue = asyncio.Queue()
    num_workers = workers + 5  # workers controls proxy concurrency; this controls overall inflight

    worker_tasks = [asyncio.create_task(_worker(queue)) for _ in range(num_workers)]

    for t in targets:
        await queue.put(t)

    await queue.join()

    for wt in worker_tasks:
        wt.cancel()

    # ── Per-URL results JSONL ─────────────────────────────────────────
    # Sibling to fetch_stats.json. Lets run_stage.py populate the ledger
    # with one row per URL fetch without touching the async internals here.
    results_path = output_dir.parent / "fetch_results.jsonl"
    try:
        with results_path.open("w", encoding="utf-8") as f:
            for r in results:
                f.write(json.dumps({
                    "original_url": r.target.original_url,
                    "wayback_url": r.target.wayback_url,
                    "timestamp": r.target.timestamp,
                    "tier": r.target.tier,
                    "success": r.success,
                    "method": r.method,
                    "size": r.size,
                    "error": r.error or "",
                }) + "\n")
        log.info("Per-URL results written to %s", results_path)
    except OSError as e:
        log.warning("Could not write fetch_results.jsonl: %s", e)

    # ── Summary ───────────────────────────────────────────────────────
    succeeded = [r for r in results if r.success]
    failed = [r for r in results if not r.success]

    by_method = {}
    for r in succeeded:
        by_method[r.method] = by_method.get(r.method, 0) + 1

    elapsed = time.time() - t0
    total_bytes = sum(r.size for r in succeeded)

    log.info("")
    log.info("═" * 60)
    log.info("  DONE in %.1fs", elapsed)
    log.info("  Succeeded: %d / %d (%.0f%%)", len(succeeded), len(results),
             100 * len(succeeded) / len(results) if results else 0)
    log.info("  Total downloaded: %.1f MB", total_bytes / 1_000_000)
    log.info("  By method:")
    for method, count in sorted(by_method.items(), key=lambda x: -x[1]):
        log.info("    %s: %d", method, count)
    if failed:
        log.info("  Failed: %d", len(failed))
        for r in failed[:10]:
            log.info("    %s — %s", r.target.original_url[:70], r.error)
        if len(failed) > 10:
            log.info("    ... and %d more", len(failed) - 10)
    log.info("═" * 60)


# ── CLI ───────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Multi-strategy archived webpage fetcher with proxy rotation",
    )
    parser.add_argument("links", type=Path, help="Path to filtered links.txt")
    parser.add_argument("-o", "--output", type=Path, default=Path("html"),
                        help="Output directory (default: ./html)")
    parser.add_argument("--proxy", choices=["isp", "dc"], default="isp",
                        help="Proxy type: isp (residential) or dc (datacenter)")
    parser.add_argument("--workers", type=int, default=5,
                        help="Max concurrent proxy requests (default: 5)")
    parser.add_argument("--resume", action="store_true",
                        help="Skip already-downloaded files")
    parser.add_argument("--dry-run", action="store_true",
                        help="Show plan without fetching")
    args = parser.parse_args()

    if not args.links.exists():
        log.error("Links file not found: %s", args.links)
        sys.exit(1)

    asyncio.run(run(
        links_file=args.links,
        output_dir=args.output,
        proxy_type=args.proxy,
        workers=args.workers,
        resume=args.resume,
        dry_run=args.dry_run,
    ))


if __name__ == "__main__":
    main()

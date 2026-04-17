#!/usr/bin/env python3
"""
Pipeline stage runner — single CLI entry point for all stages.

Usage:
    python3 run_stage.py cdx_dump     --config configs/example.yaml [--dry-run]
    python3 run_stage.py index        --config configs/example.yaml [--dry-run]
    python3 run_stage.py filter       --config configs/example.yaml [--dry-run]
    python3 run_stage.py fetch        --config configs/example.yaml [--dry-run]
    python3 run_stage.py cdn_discover --config configs/example.yaml [--dry-run]
    python3 run_stage.py match        --config configs/example.yaml [--dry-run]
    python3 run_stage.py download     --config configs/example.yaml [--dry-run]
    python3 run_stage.py normalize    --config configs/example.yaml [--dry-run]
    python3 run_stage.py build        --config configs/example.yaml
    python3 run_stage.py all          --config configs/example.yaml [--yes]

Stage ordering: cdx_dump → index → filter → fetch → cdn_discover → match → download → normalize → build
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import re
import subprocess
import sys
import time
from pathlib import Path

import aiohttp

# Add library to path (relative — self-contained)
REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "lib"))

from wayback_archiver.site_config import load_config
from wayback_archiver.checkpoint import StageCheckpoint
from wayback_archiver.resilience import CircuitBreaker, StageTimer

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-7s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger(__name__)

# ── Repo root (for importing fetch_archive / filter_cdx / shopify_downloader) ─
sys.path.insert(0, str(REPO_ROOT))


def run_cdx_dump(config, dry_run=False, **_kw):
    """Stage 0: Run wayback_cdx_v2 to produce CDX dump files for each domain.

    Invokes wayback_domain_dump.py as a subprocess for each configured domain.
    Skips domains whose CDX files already exist and are recent (configurable).
    Uses the bundled tools/wayback_cdx by default.
    """
    # Default to bundled tool; allow config override for external installs
    cdx_tool = config._raw.get("cdx_tool", str(REPO_ROOT / "tools"))
    cdx_tool_path = Path(cdx_tool).expanduser()
    if not cdx_tool_path.exists():
        log.error("cdx_tool path does not exist: %s", cdx_tool_path)
        sys.exit(1)

    max_age_days = config._raw.get("cdx_dump_max_age_days", 7)
    proxy_mode = config._raw.get("cdx_dump_proxy_mode", "auto")
    from_ts = config._raw.get("cdx_dump_from", "")
    to_ts = config._raw.get("cdx_dump_to", "")

    for domain in config.domains:
        # Derive output path: same directory as existing cdx_files, or project_dir
        safe_domain = domain.replace(".", "_").replace("/", "_")
        cdx_path = config.project_path / f"{safe_domain}_wayback.txt"

        # Check staleness
        if cdx_path.exists():
            age_days = (time.time() - cdx_path.stat().st_mtime) / 86400
            if age_days < max_age_days:
                log.info("CDX dump is fresh (%.1f days old): %s", age_days, cdx_path)
                continue
            log.info("CDX dump is stale (%.1f days old), re-dumping: %s", age_days, cdx_path)

        cmd = [
            sys.executable, "-m", "wayback_cdx",
            "--domain", domain,
            "--output", str(cdx_path),
            "--resume",
            "--proxy-mode", proxy_mode,
        ]
        if from_ts:
            cmd += ["--from", str(from_ts)]
        if to_ts:
            cmd += ["--to", str(to_ts)]

        if dry_run:
            log.info("[DRY RUN] Would run: %s", " ".join(cmd))
            log.info("[DRY RUN]   cwd=%s", cdx_tool_path)
            continue

        log.info("Running CDX dump for %s ...", domain)
        log.info("  Command: %s", " ".join(cmd))
        log.info("  Output: %s", cdx_path)

        result = subprocess.run(cmd, cwd=str(cdx_tool_path))
        if result.returncode != 0:
            log.error("CDX dump failed for %s (exit code %d)", domain, result.returncode)
        else:
            log.info("CDX dump complete for %s", domain)

        # Register the new CDX file in the config's cdx_files if not already there
        cdx_str = str(cdx_path)
        if cdx_str not in config.cdx_files:
            config.cdx_files.append(cdx_str)
            log.info("  Registered CDX file: %s", cdx_path)


def run_index(config, dry_run=False, **_kw):
    """Stage 1: Parse CDX → product index, then run CommonCrawl discovery."""
    from wayback_archiver.cdx import parse_cdx

    products = {}
    for cdx_path in config.cdx_paths:
        log.info("Parsing CDX: %s", cdx_path)
        products = parse_cdx(
            cdx_path,
            config.url_rules,
            config.era_rules,
            config.compiled_junk,
            config.type_priority,
        )

    # Stats
    by_type = {}
    by_era = {}
    for p in products.values():
        by_type[p["url_type"]] = by_type.get(p["url_type"], 0) + 1
        by_era[p["era"]] = by_era.get(p["era"], 0) + 1

    log.info("Total unique products: %d", len(products))
    log.info("By URL type:")
    for t, c in sorted(by_type.items(), key=lambda x: -x[1]):
        log.info("  %s: %d", t, c)
    log.info("By era:")
    for e, c in sorted(by_era.items(), key=lambda x: -x[1]):
        log.info("  %s: %d", e, c)

    if dry_run:
        log.info("[DRY RUN] Would write %d entries to %s", len(products), config.index_file)
        log.info("[DRY RUN] Would also run CommonCrawl discovery for %d domains", len(config.domains))
        return

    config.index_file.write_text(json.dumps(products, indent=2, sort_keys=False))
    log.info("Written to %s", config.index_file)

    # ── Pass 2: CommonCrawl discovery ──────────────────────────────────
    log.info("")
    log.info("Running CommonCrawl discovery...")
    cc_results = asyncio.run(_cc_discovery(config))
    if cc_results:
        # Merge CC discoveries into the product index (dedup against existing)
        before_count = len(products)
        for handle, cc_info in cc_results.items():
            if handle not in products:
                products[handle] = {
                    "slug": handle,
                    "url_type": cc_info.get("url_type", "slug"),
                    "era": cc_info.get("era", "unknown"),
                    "original_url": cc_info["original_url"],
                    "wayback_url": cc_info.get("wayback_url", ""),
                    "source": "commoncrawl",
                    "cc_warc": cc_info.get("warc_coords"),
                }

        new_count = len(products) - before_count
        log.info("CC discovery added %d new handles (total: %d)", new_count, len(products))

        # Rewrite the index with merged results
        config.index_file.write_text(json.dumps(products, indent=2, sort_keys=False))

    # Save CC index separately for fetch_archive.py to use
    if cc_results:
        config.cc_index_file.write_text(json.dumps(cc_results, indent=2))
        log.info("CC index saved to %s", config.cc_index_file)


async def _cc_discovery(config) -> dict:
    """Query CommonCrawl indices for product pages across all configured domains.

    Returns a dict of {handle: {original_url, url_type, warc_coords, crawl}} for
    each discovered product URL not already in the local index.

    Uses CC_CRAWLS from fetch_archive.py to avoid duplicating the crawl list.
    Rate-limits to 1 req/s against the CC index API.
    """
    import aiohttp
    from fetch_archive import CC_CRAWLS

    # Path patterns to query — product pages, collections, and root paths
    PATH_PATTERNS = [
        "/products/*",
        "/collections/*",
        "/",
    ]

    results = {}
    total_queries = 0
    total_hits = 0

    async with aiohttp.ClientSession() as session:
        for domain in config.domains:
            log.info("  CC discovery: %s", domain)

            for pattern in PATH_PATTERNS:
                query_url_prefix = f"https://{domain}{pattern}"

                for crawl_id in CC_CRAWLS:
                    api_url = (
                        f"https://index.commoncrawl.org/{crawl_id}-index"
                        f"?url={query_url_prefix}&output=json&limit=500"
                    )

                    try:
                        async with session.get(
                            api_url,
                            timeout=aiohttp.ClientTimeout(total=30),
                        ) as resp:
                            total_queries += 1

                            if resp.status != 200:
                                log.debug("    CC %s %s: HTTP %d", crawl_id, pattern, resp.status)
                                await asyncio.sleep(1.0)
                                continue

                            text = await resp.text()
                            if not text.strip():
                                await asyncio.sleep(1.0)
                                continue

                            # CC returns NDJSON — parse each line
                            for line in text.strip().split("\n"):
                                try:
                                    record = json.loads(line)
                                except json.JSONDecodeError:
                                    continue

                                if record.get("status") != "200":
                                    continue

                                original_url = record.get("url", "")
                                handle = _extract_handle(original_url)
                                if not handle:
                                    continue

                                # Determine URL type
                                path = re.sub(r"https?://[^/]+", "", original_url).lower()
                                if path.endswith(".oembed"):
                                    url_type = "oembed"
                                elif path.endswith(".atom"):
                                    url_type = "atom_feed"
                                elif path.endswith(".json"):
                                    url_type = "json_api"
                                elif "/collections/" in path:
                                    url_type = "collection"
                                elif "/products/" in path:
                                    url_type = "slug"
                                else:
                                    url_type = "page"

                                warc_coords = {
                                    "filename": record.get("filename", ""),
                                    "offset": int(record.get("offset", 0)),
                                    "length": int(record.get("length", 0)),
                                    "crawl": crawl_id,
                                }

                                # Dedup: keep the entry with the most recent timestamp
                                existing = results.get(handle)
                                ts = record.get("timestamp", "")
                                if not existing or ts > existing.get("timestamp", ""):
                                    results[handle] = {
                                        "original_url": original_url,
                                        "url_type": url_type,
                                        "timestamp": ts,
                                        "warc_coords": warc_coords,
                                    }
                                    total_hits += 1

                    except (aiohttp.ClientError, asyncio.TimeoutError) as e:
                        log.debug("    CC error %s %s: %s", crawl_id, pattern, e)
                    finally:
                        # Rate limit: 1 req/s against CC index
                        await asyncio.sleep(1.0)

    log.info("  CC discovery: %d queries, %d unique handles found", total_queries, len(results))
    return results


def _extract_handle(url: str) -> str | None:
    """Extract a product handle from a URL for dedup purposes."""
    path = re.sub(r"https?://[^/]+", "", url).split("?")[0].rstrip("/")

    # /products/{handle}
    m = re.search(r"/products/([^/]+)", path)
    if m:
        handle = m.group(1)
        # Strip extensions
        for ext in (".json", ".atom", ".oembed", ".xml"):
            handle = handle.removesuffix(ext)
        return handle.lower()

    # /collections/{name}
    m = re.search(r"/collections/([^/]+)", path)
    if m:
        return f"collection:{m.group(1).lower()}"

    return None


def run_filter(config, dry_run=False, **_kw):
    """Stage 1.5: Filter CDX dumps → clean links.txt for fetching.

    Runs filter_cdx.py's logic on each CDX dump file from the config,
    producing a single filtered links.txt sorted by value tier.
    """
    import filter_cdx

    all_urls = []
    total_input = 0

    for cdx_path in config.cdx_paths:
        if not cdx_path.exists():
            log.warning("CDX file not found, skipping: %s", cdx_path)
            continue

        log.info("Filtering CDX: %s", cdx_path)
        lines = cdx_path.read_text().splitlines()
        total_input += len(lines)

        # Run filter_cdx logic inline — reuse its filter constants
        from collections import defaultdict
        candidates = defaultdict(list)

        for line in lines:
            parts = line.split("\t")
            if len(parts) < 5:
                parts = line.split()
            if len(parts) < 5:
                continue

            wayback_url, timestamp, original_url, status, mimetype = (
                parts[0], parts[1], parts[2], parts[3], parts[4]
            )

            if status not in filter_cdx.GOOD_STATUS:
                continue
            if mimetype.lower() in filter_cdx.BAD_MIMES:
                continue
            if filter_cdx.JUNK_PATH_RE.search(original_url):
                continue

            path_for_ext = original_url.split("?")[0]
            ext_match = filter_cdx.STATIC_EXT_RE.search(path_for_ext)
            if ext_match and ext_match.group(1).lower() not in ("json",):
                continue

            if filter_cdx.VARIANT_NOISE_RE.search(original_url):
                continue

            clean_original = filter_cdx.strip_query(original_url)
            canon = filter_cdx.canonical_path(clean_original)
            priority = filter_cdx.classify_url(canon)

            clean_wayback = f"https://web.archive.org/web/{timestamp}/{clean_original}"
            candidates[canon].append((clean_wayback, timestamp, clean_original, priority))

        for canon, entries in candidates.items():
            entries.sort(key=lambda e: (e[3], -int(e[1])))
            best = entries[0]
            all_urls.append((best[3], best[1], best[0]))

    # Sort: structured data first, then by timestamp within tier
    all_urls.sort(key=lambda x: (x[0], x[1]))

    log.info("Filter results: %d input lines → %d clean URLs (%.1f%% reduction)",
             total_input, len(all_urls),
             100 * (1 - len(all_urls) / total_input) if total_input else 0)

    if dry_run:
        log.info("[DRY RUN] Would write %d URLs to %s", len(all_urls), config.filtered_links_file)
        for _, _, url in all_urls[:10]:
            log.info("  %s", url)
        if len(all_urls) > 10:
            log.info("  ... and %d more", len(all_urls) - 10)
        return

    config.project_path.mkdir(parents=True, exist_ok=True)
    config.filtered_links_file.write_text(
        "\n".join(url for _, _, url in all_urls) + "\n"
    )
    log.info("Written to %s", config.filtered_links_file)


def run_fetch(config, dry_run=False, proxy_type="isp", workers=5, max_retries=3,
              backoff_factor=2.0, **_kw):
    """Stage 2: Fetch pages using fetch_archive.py's cascade, then extract metadata.

    Uses the three-step cascade from fetch_archive.py:
      1. Direct Wayback id_ (no proxy)
      2. CommonCrawl WARC (HTML only)
      3. ISP/DC proxy fallback

    After fetching, extracts metadata and image URLs from downloaded HTML files.
    Tracks per-method success/failure counts and writes fetch_stats.json.
    """
    from wayback_archiver.extract import extract_image_urls
    from wayback_archiver.metadata import (
        extract_shopify_metadata, extract_api_metadata, extract_publish_date,
    )

    timer = StageTimer("fetch")
    timer.start()

    cb = CircuitBreaker(max_retries=max_retries, backoff_factor=backoff_factor)

    # Warn about deprecated transport_pkg
    if config.transport_pkg:
        log.warning(
            "Config key 'transport_pkg' is deprecated. "
            "run_fetch now uses fetch_archive.py's cascade (direct → CC WARC → proxy). "
            "The transport_pkg value '%s' is ignored.", config.transport_pkg
        )

    # Determine input links file
    links_file = config.filtered_links_file
    if not links_file.exists():
        log.error("Filtered links file not found: %s — run the 'filter' stage first", links_file)
        sys.exit(1)

    # ── Phase A: Fetch pages via fetch_archive.py cascade ──────────────
    import fetch_archive

    output_dir = config.fetch_output_dir

    if dry_run:
        urls = [l.strip() for l in links_file.read_text().splitlines() if l.strip()]
        log.info("[DRY RUN] Would fetch %d URLs from %s via %s proxy with %d workers",
                 len(urls), links_file, proxy_type, workers)
        log.info("[DRY RUN] Output dir: %s", output_dir)
        log.info("[DRY RUN] Circuit breaker: max_retries=%d, backoff_factor=%.1f",
                 max_retries, backoff_factor)
        asyncio.run(fetch_archive.run(
            links_file=links_file,
            output_dir=output_dir,
            proxy_type=proxy_type,
            workers=workers,
            resume=True,
            dry_run=True,
        ))
        return

    t0 = time.time()
    log.info("Fetching pages via fetch_archive.py cascade...")
    log.info("  Links: %s", links_file)
    log.info("  Output: %s", output_dir)
    log.info("  Proxy: %s | Workers: %d", proxy_type, workers)
    log.info("  Circuit breaker: max_retries=%d, backoff_factor=%.1f",
             max_retries, backoff_factor)

    asyncio.run(fetch_archive.run(
        links_file=links_file,
        output_dir=output_dir,
        proxy_type=proxy_type,
        workers=workers,
        resume=True,
        dry_run=False,
    ))
    fetch_elapsed = time.time() - t0

    # ── Phase A.5: Fallback archives for failed URLs ───────────────────
    fallback_archives = _kw.get("fallback_archives")
    if fallback_archives:
        asyncio.run(_run_fallback_archives(
            links_file, output_dir, fallback_archives, timer,
        ))

    # ── Collect fetch stats from downloaded files ──────────────────────
    # Scan output dir to count success/failure by inspecting what's there
    html_files = sorted(output_dir.glob("*.html")) if output_dir.exists() else []
    for html_path in html_files:
        size = html_path.stat().st_size
        if size > 1000:
            # Determine method from file — we can't know the exact method,
            # but we can count it as a successful fetch
            timer.record_success("fetch_cascade")
        else:
            timer.record_failure("too_small")

    # ── Phase B: Extract metadata from downloaded HTML ─────────────────
    log.info("Extracting metadata from fetched pages...")

    ckpt = StageCheckpoint(config.checkpoint_path("fetch"), "fetch")
    ckpt.load()

    metadata = {}
    if config.metadata_file.exists():
        metadata = json.loads(config.metadata_file.read_text())

    config.links_dir.mkdir(exist_ok=True)

    # Load the product index for era/type info
    index = {}
    if config.index_file.exists():
        index = json.loads(config.index_file.read_text())

    processed = 0
    skipped = 0

    try:
        for i, html_path in enumerate(html_files, 1):
            slug = _slug_from_html_filename(html_path.name)
            if not slug:
                continue

            if ckpt.is_done(slug):
                skipped += 1
                continue

            # Circuit breaker check for the domain
            domain = _domain_from_filename(html_path.name)
            if domain and cb.should_skip(domain):
                log.debug("  Skipping %s (circuit breaker tripped for %s)", slug, domain)
                timer.record_failure("circuit_breaker_skip")
                continue

            content = html_path.read_text(errors="replace")
            if not content or len(content) < 100:
                if domain:
                    pause = cb.record_failure(domain)
                    if pause > 0:
                        log.info("  Circuit breaker pause: %.0fs for %s", pause, domain)
                timer.record_failure("empty_content")
                continue

            # Determine if this is JSON/API or HTML
            is_json = content.lstrip()[:1] in ("{", "[")

            if is_json:
                try:
                    data = json.loads(content)
                except json.JSONDecodeError:
                    m = re.search(r'\{.*"id"\s*:\s*"[A-Z].*\}', content, re.DOTALL)
                    if m:
                        try:
                            data = json.loads(m.group(0))
                        except json.JSONDecodeError:
                            log.debug("  JSON parse failed for %s", slug)
                            timer.record_failure("json_parse")
                            continue
                    else:
                        timer.record_failure("json_parse")
                        continue

                meta = extract_api_metadata(data)
                image_urls = meta.pop("image_urls", [])
                timer.record_success("api_extract")
            else:
                image_urls = extract_image_urls(content)
                meta = extract_shopify_metadata(content, slug)
                timer.record_success("html_extract")

            if domain:
                cb.record_success(domain)

            # Write image links
            links_file_out = config.links_dir / f"{slug}.txt"
            links_file_out.write_text(
                "\n".join(image_urls) + "\n" if image_urls else ""
            )

            # Get era/type from index if available
            idx_entry = index.get(slug, {})
            date_str = extract_publish_date(image_urls)

            metadata[slug] = {
                "slug": slug,
                "era": idx_entry.get("era", "unknown"),
                "url_type": idx_entry.get("url_type", "json" if is_json else "slug"),
                "url": idx_entry.get("original_url", ""),
                "date": date_str,
                "image_count": len(image_urls),
                **{k: v for k, v in meta.items() if v},
            }

            ckpt.mark_done(slug)
            processed += 1

            if processed % 20 == 0:
                config.metadata_file.write_text(json.dumps(metadata, indent=2))
                log.info("  Extracted %d / %d ...", processed, len(html_files))

    except KeyboardInterrupt:
        log.warning("Interrupted — saving progress")
    finally:
        config.metadata_file.write_text(json.dumps(metadata, indent=2))

    timer.stop()

    # Write fetch stats
    stats = {
        **timer.get_stats(),
        "circuit_breaker": cb.get_stats(),
        "fetch_wall_time_seconds": round(fetch_elapsed, 1),
        "extraction_wall_time_seconds": round(timer.elapsed - fetch_elapsed, 1),
        "metadata_entries": len(metadata),
        "new_entries": processed,
        "skipped_entries": skipped,
    }
    config.fetch_stats_file.write_text(json.dumps(stats, indent=2))
    log.info("Fetch stats written to %s", config.fetch_stats_file)

    timer.log_summary()
    log.info("  Metadata: %d entries (%d new, %d skipped)",
             len(metadata), processed, skipped)


async def _run_fallback_archives(
    links_file: Path,
    output_dir: Path,
    fallback_archives: list[str],
    timer: StageTimer,
) -> None:
    """Try alternative archives (archive.today, memento) for URLs that failed
    the primary Wayback + CC cascade.

    This is a plugin/hook that wraps fetch_archive.py without modifying it.
    It reads the links file, checks which output files are missing or too small,
    and queries alternative archives for those URLs.
    """
    from wayback_archiver.alt_archives import fallback_fetch
    import fetch_archive

    urls = [l.strip() for l in links_file.read_text().splitlines() if l.strip()]
    failed_targets = []

    for url in urls:
        try:
            target = fetch_archive.FetchTarget.from_wayback_url(url)
        except ValueError:
            continue
        dest = output_dir / target.filename
        # Consider it failed if file doesn't exist or is too small
        if not dest.exists() or dest.stat().st_size < 500:
            failed_targets.append(target)

    if not failed_targets:
        log.info("No failed URLs to retry via alternative archives")
        return

    log.info("Trying alternative archives (%s) for %d failed URLs...",
             ", ".join(fallback_archives), len(failed_targets))

    fetched = 0
    async with aiohttp.ClientSession() as session:
        for i, target in enumerate(failed_targets, 1):
            content = await fallback_fetch(
                session, target.original_url,
                enabled_archives=fallback_archives,
            )
            if content:
                dest = output_dir / target.filename
                dest.write_bytes(content)
                fetched += 1
                timer.record_success("alt_archive")
                log.info("  [%d/%d] ALT OK: %s", i, len(failed_targets), target.original_url[:60])
            else:
                timer.record_failure("alt_archive")

            # Rate limit
            await asyncio.sleep(1.0)

    log.info("Alternative archives: %d / %d recovered", fetched, len(failed_targets))


def _domain_from_filename(filename: str) -> str | None:
    """Extract domain from a fetch_archive.py output filename."""
    # Filenames look like: www.yeezygap.com_products_dove-hoodie.html
    parts = filename.split("_")
    if parts and "." in parts[0]:
        return parts[0]
    return None


def _slug_from_html_filename(filename: str) -> str | None:
    """Extract a product slug from a fetch_archive.py output filename.

    Filenames look like: www.yeezygap.com_products_dove-hoodie.html
    We need to extract: dove-hoodie
    """
    name = filename.removesuffix(".html")
    # Try to find /products/{slug} pattern
    m = re.search(r"_products_(.+?)(?:\.json|\.oembed|\.atom)?$", name)
    if m:
        slug = m.group(1)
        # Clean up further path components
        slug = slug.split("_")[0] if "/" not in slug else slug.rsplit("_", 1)[-1]
        return slug

    # Try /collections/{name}/products/{slug}
    m = re.search(r"_collections_[^_]+_products_(.+?)$", name)
    if m:
        return m.group(1)

    # Fallback: use the whole name if it looks reasonable
    if len(name) > 5 and not name.startswith("http"):
        return name

    return None


def run_cdn_discover(config, dry_run=False, **_kw):
    """Stage: Shopify CDN archaeology — discover all CDN image URLs.

    Runs shopify_downloader.py's discovery functions to find every image URL
    on Shopify's CDN for this store, including delisted/removed products.
    Merges discovered URLs into the pipeline's links/{slug}.txt files.

    No-op if shopify_cdn.enabled is not set in the config.
    """
    shopify_cfg = config._raw.get("shopify_cdn", {})
    if not shopify_cfg.get("enabled"):
        log.info("shopify_cdn not enabled — skipping CDN discovery")
        return

    # shopify_downloader.py is bundled at repo root; config can override
    downloader_path = shopify_cfg.get("downloader_path", str(REPO_ROOT / "shopify_downloader.py"))
    downloader_path = Path(downloader_path).expanduser()
    if not downloader_path.exists():
        log.error("shopify_downloader.py not found: %s", downloader_path)
        return

    # Lazy import — add parent dir to sys.path
    dl_parent = str(downloader_path.parent)
    if dl_parent not in sys.path:
        sys.path.insert(0, dl_parent)
    import shopify_downloader as sd

    # Use the first domain as the primary store URL
    store_domain = config.domains[0] if config.domains else None
    if not store_domain:
        log.error("No domains configured — cannot run CDN discovery")
        return

    base_url = f"https://{store_domain}"
    myshopify = shopify_cfg.get("myshopify_domain", "")
    myshopify_url = f"https://{myshopify}" if myshopify else None
    full_size = shopify_cfg.get("full_size", True)
    max_wayback_json = shopify_cfg.get("max_wayback_json", 200)

    log.info("Shopify CDN discovery for %s", base_url)

    # ── Layer 1: CDN prefix ───────────────────────────────────────────
    cdn_prefix = shopify_cfg.get("cdn_prefix") or None
    if not cdn_prefix:
        # Try to find it from fetched HTML
        html_dir = config.fetch_output_dir
        if html_dir.exists():
            for html_file in sorted(html_dir.glob("*.html"))[:20]:
                content = html_file.read_text(errors="replace")[:5000]
                m = sd._CDN_PREFIX_RE.search(content)
                if m:
                    cdn_prefix = f"1/{m.group(1)}"
                    log.info("  Found CDN prefix from fetched HTML: %s", cdn_prefix)
                    break

        if not cdn_prefix:
            cdn_prefix = sd.discover_cdn_prefix(base_url)

    if cdn_prefix:
        log.info("  CDN prefix: %s", cdn_prefix)
    else:
        log.warning("  Could not discover CDN prefix — CDX CDN queries will be limited")

    # ── Layer 2: Access token ─────────────────────────────────────────
    access_token = shopify_cfg.get("access_token") or None
    if not access_token:
        access_token = sd.discover_access_token(base_url, myshopify_url)
    if access_token:
        log.info("  Access token: %s...%s", access_token[:4], access_token[-4:])

    if dry_run:
        log.info("[DRY RUN] Would run Shopify CDN discovery with:")
        log.info("  Store: %s", base_url)
        log.info("  CDN prefix: %s", cdn_prefix)
        log.info("  Access token: %s", "yes" if access_token else "no")
        log.info("  Full size: %s", full_size)
        return

    all_cdn_urls: set[str] = set()
    products_discovered: list[dict] = []

    # ── Layer 3: Storefront API discovery ─────────────────────────────
    if access_token:
        try:
            api_products = sd.discover_via_storefront_api(
                base_url, access_token, myshopify_url,
            )
            if api_products:
                products_discovered.extend(api_products)
                api_urls = sd.extract_cdn_urls_from_products(api_products)
                all_cdn_urls.update(api_urls)
                log.info("  Storefront API: %d products, %d CDN URLs",
                         len(api_products), len(api_urls))
        except Exception as e:
            log.warning("  Storefront API discovery failed: %s", e)

    # ── Layer 4: Live store scraping ──────────────────────────────────
    try:
        live_products = sd.discover_products(base_url)
        if live_products:
            products_discovered.extend(live_products)
            live_urls = sd.extract_cdn_urls_from_products(live_products)
            all_cdn_urls.update(live_urls)
            log.info("  Live scrape: %d products, %d CDN URLs",
                     len(live_products), len(live_urls))
    except Exception as e:
        log.debug("  Live store scraping failed (store may be dead): %s", e)

    # ── Layer 5: Wayback CDX CDN discovery ────────────────────────────
    try:
        wayback_urls, cdx_records = sd.discover_wayback_cdn_urls(
            store_domain, cdn_prefix,
        )
        all_cdn_urls.update(wayback_urls)
        log.info("  Wayback CDX: %d CDN URLs", len(wayback_urls))
    except Exception as e:
        log.warning("  Wayback CDX discovery failed: %s", e)
        cdx_records = []

    # ── Full-size URL normalization ───────────────────────────────────
    if full_size:
        normalized = set()
        for url in all_cdn_urls:
            normalized.add(sd.strip_shopify_size_suffix(url))
        log.info("  After full-size normalization: %d → %d URLs",
                 len(all_cdn_urls), len(normalized))
        all_cdn_urls = normalized

    # ── Layer 6: Liveness check ───────────────────────────────────────
    skip_liveness = shopify_cfg.get("skip_liveness", False)
    if not skip_liveness and all_cdn_urls:
        alive_urls, dead_urls = sd.check_cdn_liveness(all_cdn_urls)
        log.info("  Liveness: %d alive, %d dead", len(alive_urls), len(dead_urls))
        downloadable_urls = alive_urls
    else:
        downloadable_urls = all_cdn_urls
        dead_urls = set()

    log.info("  Total downloadable CDN URLs: %d", len(downloadable_urls))

    # ── Merge into pipeline's links/{slug}.txt ────────────────────────
    config.links_dir.mkdir(exist_ok=True)
    metadata = {}
    if config.metadata_file.exists():
        metadata = json.loads(config.metadata_file.read_text())

    # Build a lookup: CDN filename fragment → product slug
    merged_count = 0
    unmatched_urls: list[str] = []

    for url in sorted(downloadable_urls):
        filename = sd.cdn_url_to_filename(url)

        # Try to match against known product slugs
        matched_slug = None
        # Extract the product-relevant part from the CDN filename
        # e.g. "products__dove-hoodie_800x.jpg" → "dove-hoodie"
        parts = filename.split("__")
        if len(parts) >= 2:
            # Take the last part, strip extension and size suffix
            candidate = parts[-1]
            candidate = re.sub(r'\.\w+$', '', candidate)  # strip extension
            candidate = re.sub(r'_\d+x\d*$', '', candidate)  # strip size suffix
            candidate = re.sub(r'_(?:grande|medium|small|large|compact|master|pico|icon|thumb)$', '', candidate)
            candidate = candidate.lower()

            # Direct match
            if candidate in metadata:
                matched_slug = candidate
            else:
                # Try partial match: does any slug start with or contain this candidate?
                for slug in metadata:
                    if candidate and (slug.startswith(candidate) or candidate in slug):
                        matched_slug = slug
                        break

        if matched_slug:
            links_file = config.links_dir / f"{matched_slug}.txt"
            existing = set()
            if links_file.exists():
                existing = set(links_file.read_text().splitlines())
            if url not in existing:
                with open(links_file, "a") as f:
                    f.write(url + "\n")
                merged_count += 1
        else:
            unmatched_urls.append(url)

    # Write unmatched URLs to a catch-all file
    if unmatched_urls:
        unmatched_file = config.links_dir / "_cdn_unmatched.txt"
        unmatched_file.write_text("\n".join(sorted(unmatched_urls)) + "\n")
        log.info("  Merged %d URLs into product links, %d unmatched → %s",
                 merged_count, len(unmatched_urls), unmatched_file)
    else:
        log.info("  Merged %d URLs into product links, all matched", merged_count)

    # ── Save Shopify manifest ─────────────────────────────────────────
    manifest = {
        "store_url": base_url,
        "cdn_prefix": cdn_prefix,
        "access_token_found": bool(access_token),
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "stats": {
            "total_cdn_urls": len(all_cdn_urls),
            "alive": len(downloadable_urls),
            "dead": len(dead_urls),
            "merged_to_products": merged_count,
            "unmatched": len(unmatched_urls),
            "products_from_api": len(products_discovered),
            "cdx_records": len(cdx_records),
        },
        "products": [
            {
                "title": p.get("title", ""),
                "handle": p.get("handle", ""),
                "vendor": p.get("vendor", ""),
            }
            for p in products_discovered
        ],
    }
    manifest_path = config.project_path / f"{config.name}_shopify_manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2))
    log.info("  Manifest written to %s", manifest_path)


def run_match(config, dry_run=False, **_kw):
    """Stage 3: Fuzzy match slugs to SKUs."""
    from wayback_archiver.match import match_products
    from wayback_archiver.util import find_empty_dirs, build_dir_to_slug_map

    metadata = json.loads(config.metadata_file.read_text())

    dir_map = build_dir_to_slug_map(metadata)
    empty_slugs = find_empty_dirs(config.products_dir, dir_map)

    slug_products = {s: metadata[s] for s in empty_slugs if s in metadata}
    sku_products = {s: m for s, m in metadata.items() if m.get("url_type") in ("api", "catalog_api")}

    result = match_products(slug_products, sku_products)

    log.info("Match results:")
    log.info("  Matched: %d", len(result.matched))
    log.info("  Unmatched slugs: %d", len(result.unmatched_slugs))
    log.info("  Unmatched SKUs: %d", len(result.unmatched_skus))

    if dry_run:
        for slug, sku in sorted(result.matched.items()):
            log.info("  %s -> %s", slug, sku)
        return

    for slug, sku in result.matched.items():
        if slug in metadata:
            metadata[slug]["matched_sku"] = sku

    config.metadata_file.write_text(json.dumps(metadata, indent=2))
    log.info("Metadata updated with %d matches", len(result.matched))


def run_download(config, dry_run=False, **_kw):
    """Stage 4: Download images via cascade."""
    from wayback_archiver.download import download_product_images
    from wayback_archiver.normalize import list_images
    from wayback_archiver.util import build_dirname
    import requests

    metadata = json.loads(config.metadata_file.read_text())
    ckpt = StageCheckpoint(config.checkpoint_path("download"), "download")
    ckpt.load()

    tasks = {}
    for slug, meta in metadata.items():
        if ckpt.is_done(slug):
            continue
        links_file = config.links_dir / f"{slug}.txt"
        if not links_file.exists():
            continue
        urls = [l.strip() for l in links_file.read_text().splitlines() if l.strip()]
        if urls:
            tasks[slug] = {"meta": meta, "urls": urls}

    log.info("Download: %d products (%d already done)", len(tasks), len(ckpt.completed))

    if dry_run:
        total_urls = sum(len(t["urls"]) for t in tasks.values())
        log.info("  Total URLs: %d", total_urls)
        return

    config.products_dir.mkdir(exist_ok=True)
    session = requests.Session()
    session.headers["User-Agent"] = "wayback-image-fetch/1.0 (archival research)"

    total_dl, total_fail = 0, 0
    try:
        for i, (slug, task) in enumerate(sorted(tasks.items()), 1):
            meta = task["meta"]
            urls = task["urls"]
            dir_name = build_dirname(
                meta.get("name", slug.replace("-", " ").title()),
                meta.get("date") or None,
            )
            dest_dir = config.products_dir / dir_name

            is_live = any("cdn.shopify.com" in u for u in urls)

            log.info("[%d/%d] %s (%d URLs)", i, len(tasks), slug, len(urls))
            result = download_product_images(
                slug, urls, dest_dir, session,
                cdn_tool=config.cdn_tool_path,
                is_live_cdn=is_live,
            )
            total_dl += result["downloaded"]
            total_fail += result["failed"]

            from wayback_archiver.normalize import rename_batch
            images = list_images(dest_dir)
            rename_batch(images)

            ckpt.mark_done(slug)

    except KeyboardInterrupt:
        log.warning("Interrupted — saving progress")
    finally:
        session.close()

    log.info("DONE — %d downloaded, %d failed", total_dl, total_fail)


def run_normalize(config, dry_run=False, **_kw):
    """Stage 5: Rename images + write metadata.txt."""
    from wayback_archiver.normalize import rename_batch, list_images
    from wayback_archiver.metadata import write_metadata_txt
    from wayback_archiver.util import build_dir_to_slug_map

    metadata = json.loads(config.metadata_file.read_text())
    dir_map = build_dir_to_slug_map(metadata)

    total_renamed = 0
    total_metadata = 0

    for d in sorted(config.products_dir.iterdir()):
        if not d.is_dir():
            continue
        slug = dir_map.get(d.name)
        meta = metadata.get(slug, {}) if slug else {}

        images = list_images(d)
        if images:
            if dry_run:
                log.info("  %s: %d images", d.name, len(images))
            else:
                renames = rename_batch(images)
                total_renamed += len(renames)

        if not dry_run:
            meta_with_defaults = {
                "url": meta.get("url", "Unknown"),
                "name": meta.get("name", d.name),
                "date": meta.get("date"),
                **meta,
            }
            write_metadata_txt(d / "metadata.txt", meta_with_defaults, config.credit_line)
            total_metadata += 1

    if dry_run:
        log.info("[DRY RUN] Would process %d directories", total_metadata)
    else:
        log.info("Renamed %d files, wrote %d metadata.txt files", total_renamed, total_metadata)


def run_build(config, dry_run=False, **_kw):
    """Stage 6: Build final catalog JSON."""
    from wayback_archiver.normalize import list_images
    from wayback_archiver.util import build_dir_to_slug_map

    metadata = json.loads(config.metadata_file.read_text())
    dir_map = build_dir_to_slug_map(metadata)

    catalog = []
    for slug, meta in sorted(metadata.items()):
        name = meta.get("name", slug.replace("-", " ").title())
        from wayback_archiver.util import build_dirname
        dir_name = build_dirname(name, meta.get("date") or None)
        d = config.products_dir / dir_name

        images = sorted(f.name for f in list_images(d)) if d.exists() else []

        price_str = meta.get("price")
        price = None
        if price_str:
            try:
                price = float(price_str)
            except (ValueError, TypeError):
                pass

        catalog.append({
            "slug": slug,
            "name": name,
            "era": meta.get("era"),
            "url": meta.get("url"),
            "date": meta.get("date"),
            "price": price,
            "currency": meta.get("currency"),
            "brand": meta.get("brand"),
            "category": meta.get("category"),
            "sku": meta.get("sku"),
            "color": meta.get("color"),
            "gender": meta.get("gender"),
            "images": images,
            "image_count": len(images),
        })

    config.catalog_file.write_text(json.dumps(catalog, indent=2))

    with_images = sum(1 for c in catalog if c["image_count"] > 0)
    total_images = sum(c["image_count"] for c in catalog)
    by_era = {}
    for c in catalog:
        era = c.get("era", "unknown")
        by_era[era] = by_era.get(era, 0) + 1

    log.info("Catalog: %d products", len(catalog))
    log.info("  With images: %d (%d total files)", with_images, total_images)
    log.info("  Empty: %d", len(catalog) - with_images)
    for era, count in sorted(by_era.items(), key=lambda x: -x[1]):
        log.info("  %s: %d", era, count)
    log.info("Written to %s", config.catalog_file)


STAGE_ORDER = [
    "cdx_dump", "index", "filter", "fetch", "cdn_discover",
    "match", "download", "normalize", "build",
]


def main():
    parser = argparse.ArgumentParser(description="Wayback Archive Pipeline")
    parser.add_argument("stage", choices=STAGE_ORDER + ["all"])
    parser.add_argument("--config", required=True, help="Path to site config YAML")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--yes", "-y", action="store_true",
                        help="Skip confirmation prompts (for --all mode)")
    # fetch-specific options
    parser.add_argument("--proxy", choices=["isp", "dc"], default="isp",
                        help="Proxy type for fetch stage (default: isp)")
    parser.add_argument("--workers", type=int, default=5,
                        help="Max concurrent proxy requests for fetch (default: 5)")
    parser.add_argument("--max-retries", type=int, default=3,
                        help="Max retries per URL (default: 3)")
    parser.add_argument("--backoff-factor", type=float, default=2.0,
                        help="Backoff multiplier between retries (default: 2.0)")
    parser.add_argument("--fallback-archives", nargs="*", default=None,
                        choices=["archive_today", "memento"],
                        help="Try alternative archives for failed URLs after primary cascade "
                             "(e.g., --fallback-archives archive_today memento)")
    args = parser.parse_args()

    config = load_config(Path(args.config))

    # Also check config for alternative_archives setting
    fallback_archives = args.fallback_archives
    if fallback_archives is None and config.alternative_archives.get("enabled"):
        fallback_archives = config.alternative_archives.get(
            "sources", ["archive_today", "memento"]
        )

    stages = {
        "cdx_dump": run_cdx_dump,
        "index": run_index,
        "filter": run_filter,
        "fetch": run_fetch,
        "cdn_discover": run_cdn_discover,
        "match": run_match,
        "download": run_download,
        "normalize": run_normalize,
        "build": run_build,
    }

    kwargs = dict(
        dry_run=args.dry_run,
        proxy_type=args.proxy,
        workers=args.workers,
        max_retries=args.max_retries,
        backoff_factor=args.backoff_factor,
        fallback_archives=fallback_archives,
    )

    if args.stage == "all":
        log.info("=" * 60)
        log.info("FULL PIPELINE | Site: %s | Dry-run: %s", config.display_name, args.dry_run)
        log.info("Stages: %s", " → ".join(STAGE_ORDER))
        log.info("=" * 60)

        # Confirmation gates for expensive stages
        confirm_before = {"cdx_dump", "fetch", "download"}

        for stage_name in STAGE_ORDER:
            if stage_name in confirm_before and not args.dry_run and not args.yes:
                try:
                    answer = input(f"\nAbout to run '{stage_name}'. Continue? [Y/n] ")
                except EOFError:
                    answer = "y"
                if answer.strip().lower() in ("n", "no"):
                    log.info("Skipping %s (user declined)", stage_name)
                    continue

            log.info("")
            log.info("=" * 60)
            log.info("Stage: %s", stage_name)
            log.info("=" * 60)
            stages[stage_name](config, **kwargs)

        log.info("")
        log.info("=" * 60)
        log.info("PIPELINE COMPLETE")
        log.info("=" * 60)
    else:
        log.info("=" * 60)
        log.info("Stage: %s | Site: %s | Dry-run: %s", args.stage, config.display_name, args.dry_run)
        log.info("=" * 60)

        stages[args.stage](config, **kwargs)


if __name__ == "__main__":
    main()

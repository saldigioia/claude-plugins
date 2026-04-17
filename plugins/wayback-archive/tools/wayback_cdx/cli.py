"""
CLI entry point for wayback-cdx-dump.

Preserves original interactive behavior when run without arguments.
Adds CLI flags for automated / scripted usage.
"""
from __future__ import annotations

import argparse
import logging
import os
import sys
import tempfile
import time
from pathlib import Path

from .cdx import CdxRow, fetch_num_pages, iter_cdx_pages_concurrent, sanitize_domain
from .checkpoint import CheckpointManager, default_checkpoint_path
from .config import AppConfig
from .metrics import get_metrics, reset_metrics
from .transport import TransportError, build_transport

log = logging.getLogger(__name__)


def setup_logging(verbose: bool = False) -> None:
    level = logging.DEBUG if verbose else logging.INFO
    fmt = "%(asctime)s %(levelname)-7s %(name)s  %(message)s"
    logging.basicConfig(level=level, format=fmt, stream=sys.stderr)
    # Silence noisy libraries
    logging.getLogger("urllib3").setLevel(logging.WARNING)
    logging.getLogger("requests").setLevel(logging.WARNING)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="wayback-cdx-dump",
        description="Dump all Wayback CDX captures for a domain to a TXT file.",
    )
    p.add_argument("--domain", "-d", help="Target domain (e.g. example.com)")
    p.add_argument("--output", "-o", help="Output file path")
    p.add_argument(
        "--proxy-mode",
        choices=["auto", "dc", "isp", "off"],
        default=None,
        help="Proxy mode (overrides PROXY_MODE env var)",
    )
    p.add_argument("--max-concurrency", type=int, default=None)
    p.add_argument("--rps", type=float, default=None, help="Max requests per second")
    p.add_argument(
        "--resume",
        action="store_true",
        help="Resume from checkpoint if available",
    )
    p.add_argument("--checkpoint-file", default=None, help="Custom checkpoint path")
    p.add_argument(
        "--from", dest="from_ts", default=None,
        help="Start timestamp filter (1-14 digits, e.g. 2020 or 20200101)",
    )
    p.add_argument(
        "--to", dest="to_ts", default=None,
        help="End timestamp filter (1-14 digits, e.g. 2020 or 20201231)",
    )
    p.add_argument("--verbose", "-v", action="store_true")
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="Fetch page count only, don't download",
    )
    return p


def make_dedupe_key(row: CdxRow) -> tuple[str, str, str, str]:
    return row  # (timestamp, original, statuscode, mimetype)


def format_output_line(row: CdxRow) -> str:
    ts, original, status, mime = row
    replay = f"https://web.archive.org/web/{ts}/{original}"
    return f"{replay}\t{ts}\t{original}\t{status}\t{mime}\n"


def atomic_flush(file_obj) -> None:
    """Flush + fsync for durability."""
    file_obj.flush()
    os.fsync(file_obj.fileno())


def run(args: argparse.Namespace) -> int:
    """Main execution flow."""
    setup_logging(verbose=args.verbose)
    metrics = reset_metrics()

    # --- Load config ---
    config = AppConfig.from_env()

    # CLI overrides
    if args.proxy_mode:
        # Rebuild proxy config with overridden mode
        from dataclasses import replace
        proxy = replace(config.proxy, mode=args.proxy_mode)
        config = replace(config, proxy=proxy)
    if args.rps is not None:
        from dataclasses import replace
        config = replace(config, max_rps=args.rps)
    if args.max_concurrency is not None:
        from dataclasses import replace
        config = replace(config, max_concurrency=args.max_concurrency)

    # --- Resolve domain ---
    if args.domain:
        domain = sanitize_domain(args.domain)
    else:
        try:
            domain_input = input("Enter domain (e.g., example.com): ")
            domain = sanitize_domain(domain_input)
        except (EOFError, KeyboardInterrupt):
            print("\nAborted.", file=sys.stderr)
            return 1

    # --- Resolve output path ---
    default_out = f"{domain.replace('.', '_')}_wayback.txt"
    if args.output:
        out_path = Path(args.output)
    else:
        try:
            out_input = input(f"Output TXT path [{default_out}]: ").strip()
            out_path = Path(out_input or default_out)
        except (EOFError, KeyboardInterrupt):
            out_path = Path(default_out)

    # --- Checkpoint setup ---
    ckpt_path = Path(args.checkpoint_file) if args.checkpoint_file else default_checkpoint_path(domain)
    ckpt = CheckpointManager(ckpt_path)

    # --- Build transport ---
    transport = build_transport(config)

    try:
        # --- Fetch page count ---
        from_ts = args.from_ts
        to_ts = args.to_ts

        if from_ts or to_ts:
            log.info("Time window: from=%s to=%s", from_ts or "*", to_ts or "*")

        log.info("Querying CDX page count for %s ...", domain)
        try:
            total_pages = fetch_num_pages(transport, domain, from_ts=from_ts, to_ts=to_ts)
        except (TransportError, ValueError) as e:
            log.error("Failed to get CDX page count: %s", e)
            return 1

        log.info("Domain: %s", domain)
        log.info("CDX pages: %d", total_pages)
        log.info("Output: %s", out_path)

        if args.dry_run:
            log.info("Dry run — exiting after page count")
            return 0

        if total_pages == 0:
            log.warning("No CDX pages found for %s", domain)
            out_path.parent.mkdir(parents=True, exist_ok=True)
            out_path.write_text("", encoding="utf-8")
            return 0

        # --- Resume logic ---
        start_page = 0
        rows_written = 0
        seen: set[tuple[str, str, str, str]] = set()
        write_mode = "w"

        if args.resume:
            existing = ckpt.load()
            ckpt_window_match = (
                existing
                and existing.domain == domain
                and existing.total_pages == total_pages
                and getattr(existing, "from_ts", None) == (from_ts or "")
                and getattr(existing, "to_ts", None) == (to_ts or "")
            )
            if ckpt_window_match:
                start_page = existing.next_page
                rows_written = existing.rows_written
                write_mode = "a"  # Append to existing output
                log.info(
                    "Resuming from page %d/%d (%d rows already written)",
                    start_page, total_pages, rows_written,
                )

                # Rebuild seen set from existing output (for dedupe continuity)
                if out_path.exists():
                    log.info("Rebuilding dedupe set from existing output...")
                    with out_path.open("r", encoding="utf-8") as f:
                        for line in f:
                            parts = line.rstrip("\n").split("\t")
                            if len(parts) >= 5:
                                # parts: replay_url, ts, original, status, mime
                                seen.add((parts[1], parts[2], parts[3], parts[4]))
                    log.info("Loaded %d existing keys into dedupe set", len(seen))
            else:
                if existing:
                    log.warning(
                        "Checkpoint mismatch (domain, pages, or time window changed) — starting fresh"
                    )
                ckpt.initialize(domain, total_pages, str(out_path), from_ts=from_ts or "", to_ts=to_ts or "")
        else:
            ckpt.initialize(domain, total_pages, str(out_path), from_ts=from_ts or "", to_ts=to_ts or "")

        # --- Main page loop ---
        out_path.parent.mkdir(parents=True, exist_ok=True)

        with out_path.open(write_mode, encoding="utf-8") as f:
            page_count = 0
            batch_rows = 0

            for page_num, rows in iter_cdx_pages_concurrent(
                transport, domain, total_pages, start_page,
                from_ts=from_ts, to_ts=to_ts,
                max_workers=config.max_concurrency,
            ):
                page_new = 0
                for row in rows:
                    key = make_dedupe_key(row)
                    if key in seen:
                        metrics.inc("rows_deduped")
                        continue
                    seen.add(key)
                    f.write(format_output_line(row))
                    rows_written += 1
                    page_new += 1
                    metrics.inc("rows_yielded")

                # Periodic flush every page
                f.flush()

                page_count += 1
                batch_rows += page_new
                metrics.inc("pages_completed")

                # Update checkpoint every page
                ckpt.update(
                    last_completed_page=page_num,
                    rows_written=rows_written,
                    seen_count=len(seen),
                )

                # Progress log every 10 pages
                if page_count % 10 == 0 or page_num == total_pages - 1:
                    log.info(
                        "Progress: page %d/%d  rows=%d  (+%d this batch)  seen=%d",
                        page_num + 1, total_pages, rows_written, batch_rows, len(seen),
                    )
                    atomic_flush(f)
                    batch_rows = 0

        # --- Completion ---
        ckpt.mark_complete()
        log.info("Done. Wrote %d captures to %s", rows_written, out_path)

    except TransportError as e:
        log.error("Unrecoverable transport error: %s", e)
        log.info("Progress saved to checkpoint: %s", ckpt_path)
        log.info("Re-run with --resume to continue")
        return 1
    except KeyboardInterrupt:
        log.warning("Interrupted by user. Progress saved to checkpoint: %s", ckpt_path)
        return 130
    finally:
        transport.close()
        metrics.print_summary()

    return 0


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return run(args)

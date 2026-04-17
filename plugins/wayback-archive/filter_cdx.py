#!/usr/bin/env python3
"""
CDX dump filter — implements the guardrail logic from the improvement plan.

Reads a Wayback CDX dump (tab-separated: wayback_url timestamp original_url status mimetype)
and outputs only clean, deduplicated Wayback URLs suitable for the nightline.py scraper.

Filter layers:
  1. Status code:  keep only 200
  2. MIME type:     drop JS, CSS, fonts, images, video, revisits, unknowns
  3. Junk paths:    drop robots.txt, favicon, checkouts, tracking, encoded garbage
  4. Static assets: drop .js .css .map .woff .ico .png .jpg .gif .webp .mp4 etc.
  5. Variants:      drop ?section_id=store-availability (Shopify variant checker)
  6. Query params:  strip tracking params, variant params, Shopify internal params
  7. Dedup:         one URL per unique (original_path, best_timestamp) — prefer latest 200
  8. Extension sort: structured data first (.oembed, .atom, .json), then HTML product pages,
                     then collection pages, then homepages
"""

import re
import sys
from pathlib import Path
from collections import defaultdict

INPUT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("cdx_dump.txt")

# ── Layer 1: Status whitelist ──────────────────────────────────────────────
GOOD_STATUS = {"200"}

# ── Layer 2: MIME blacklist ────────────────────────────────────────────────
BAD_MIMES = {
    "application/javascript",
    "text/javascript",
    "text/css",
    "image/png", "image/jpeg", "image/gif", "image/webp",
    "image/vnd.microsoft.icon", "image/x-icon",
    "font/woff", "font/woff2", "application/font-woff",
    "video/mp4", "audio/mpeg",
    "warc/revisit",
    "unk",
    "application/octet-stream",
}

# ── Layer 3: Junk path patterns ────────────────────────────────────────────
# Infrastructure / boilerplate — safe to drop universally
JUNK_PATH_RE = re.compile(r"""
    /robots\.txt |
    /favicon\.ico |
    /apple-touch-icon |
    /\.well-known/ |
    /manifest\.json |
    /cdn-cgi/ |
    /__cf_chl_ |
    /checkouts |
    /checkout/ |
    /cart$ |
    /account/ |
    /admin/ |
    /wpm@ |
    /sandbox/ |
    /monorail/ |
    /web-pixels |
    /gtag/ |
    /analytics |
    /_vercel/ |
    /shopifycloud/ |
    /password$ |
    /payments/ |
    /csp-report |
    /apple-app-site |
    /search(\?|$) |
    %22 |
    %3[CcEe] |
    %7[Bb] |
    %5[Bb] |
    %0[Aa] |
    undefined |
    :productId |
    \[insert
""", re.VERBOSE | re.IGNORECASE)

# ── Layer 4: Static asset extensions ───────────────────────────────────────
STATIC_EXT_RE = re.compile(
    r"\.(js|css|map|woff2?|ttf|eot|svg|png|jpe?g|gif|webp|ico|mp4|mp3|avif|bmp)(\?|$)",
    re.IGNORECASE,
)

# ── Layer 5: Shopify variant / store-availability noise ────────────────────
VARIANT_NOISE_RE = re.compile(r"/variants/\d+/?\?section_id=store-availability")

# ── Layer 6: Query param stripping ─────────────────────────────────────────
# These params add no product content — strip them to deduplicate
STRIP_PARAMS = {
    "variant", "slide", "_pos", "_sid", "_ss", "tid", "mi_u",
    "EV", "DI", "CD", "cvosrc", "kwid", "ap", "gbraid", "gclid",
    "gclsrc", "utm_source", "utm_medium", "utm_campaign", "utm_content",
    "utm_term", "ref", "mc_cid", "mc_eid",
}

def strip_query(url: str) -> str:
    """Strip tracking/noise query params. Keep the URL if all params are noise."""
    if "?" not in url:
        return url
    base, qs = url.split("?", 1)
    kept = []
    for pair in qs.split("&"):
        key = pair.split("=", 1)[0].lower()
        if key not in STRIP_PARAMS:
            kept.append(pair)
    return base if not kept else base + "?" + "&".join(kept)


def canonical_path(original_url: str) -> str:
    """Extract and normalize the path from an original URL for deduplication."""
    # Strip protocol + domain
    path = re.sub(r"https?://[^/]+", "", original_url)
    # Strip query string entirely for dedup purposes
    path = path.split("?")[0]
    # Normalize trailing slash
    path = path.rstrip("/") or "/"
    return path.lower()


def classify_url(path: str) -> int:
    """Sort priority: lower = more valuable. Structured data first."""
    if path.endswith(".oembed"):
        return 0  # oEmbed — structured JSON, curl-friendly
    if path.endswith(".atom"):
        return 1  # Atom feed — structured XML, curl-friendly
    if path.endswith(".json"):
        return 2  # JSON API — structured, curl-friendly
    if "/collections/" in path:
        return 3  # Collection pages — product grids
    if "/products/" in path:
        return 4  # Individual product pages
    return 5  # Everything else (homepages, etc.)


def main():
    lines = INPUT.read_text().splitlines()

    stats = {
        "total": len(lines),
        "rejected_status": 0,
        "rejected_mime": 0,
        "rejected_junk_path": 0,
        "rejected_static_ext": 0,
        "rejected_variant_noise": 0,
        "passed_filters": 0,
        "after_dedup": 0,
    }

    # Pass 1: Filter
    # Key: canonical_path -> list of (wayback_url, timestamp, original_url, priority)
    candidates = defaultdict(list)

    for line in lines:
        parts = line.split("\t")
        if len(parts) < 5:
            parts = line.split()
        if len(parts) < 5:
            continue

        wayback_url, timestamp, original_url, status, mimetype = parts[0], parts[1], parts[2], parts[3], parts[4]

        # Layer 1: Status
        if status not in GOOD_STATUS:
            stats["rejected_status"] += 1
            continue

        # Layer 2: MIME
        if mimetype.lower() in BAD_MIMES:
            stats["rejected_mime"] += 1
            continue

        # Layer 3: Junk paths
        if JUNK_PATH_RE.search(original_url):
            stats["rejected_junk_path"] += 1
            continue

        # Layer 4: Static asset extensions (applied to path, not to .oembed/.atom/.json)
        path_for_ext_check = original_url.split("?")[0]
        if STATIC_EXT_RE.search(path_for_ext_check):
            # But don't reject .json, .atom, .oembed — those are structured data
            ext_match = STATIC_EXT_RE.search(path_for_ext_check)
            if ext_match and ext_match.group(1).lower() not in ("json",):
                stats["rejected_static_ext"] += 1
                continue

        # Layer 5: Variant noise
        if VARIANT_NOISE_RE.search(original_url):
            stats["rejected_variant_noise"] += 1
            continue

        # Layer 6: Strip noisy query params
        clean_original = strip_query(original_url)

        # Compute canonical for dedup
        canon = canonical_path(clean_original)
        priority = classify_url(canon)

        stats["passed_filters"] += 1
        # Reconstruct a clean Wayback URL with stripped query params
        clean_wayback = f"https://web.archive.org/web/{timestamp}/{clean_original}"
        candidates[canon].append((clean_wayback, timestamp, clean_original, priority))

    # Pass 2: Deduplicate — for each canonical path, pick the best snapshot
    # Prefer: latest timestamp (most complete content), highest priority type
    final_urls = []
    for canon, entries in candidates.items():
        # Sort by priority (lower = better), then by timestamp descending (latest = best)
        entries.sort(key=lambda e: (e[3], -int(e[1])))
        best = entries[0]
        final_urls.append((best[3], best[1], best[0]))  # (priority, timestamp, wayback_url)

    # Sort output: structured data first, then by timestamp within each tier
    final_urls.sort(key=lambda x: (x[0], x[1]))

    stats["after_dedup"] = len(final_urls)

    # Print stats to stderr
    print(f"── Filter Statistics ──", file=sys.stderr)
    print(f"  Input lines:            {stats['total']:>6}", file=sys.stderr)
    print(f"  Rejected (bad status):  {stats['rejected_status']:>6}", file=sys.stderr)
    print(f"  Rejected (bad MIME):    {stats['rejected_mime']:>6}", file=sys.stderr)
    print(f"  Rejected (junk path):   {stats['rejected_junk_path']:>6}", file=sys.stderr)
    print(f"  Rejected (static ext):  {stats['rejected_static_ext']:>6}", file=sys.stderr)
    print(f"  Rejected (variant):     {stats['rejected_variant_noise']:>6}", file=sys.stderr)
    print(f"  Passed all filters:     {stats['passed_filters']:>6}", file=sys.stderr)
    print(f"  After deduplication:    {stats['after_dedup']:>6}", file=sys.stderr)
    print(f"  Reduction:              {100 * (1 - stats['after_dedup'] / stats['total']):.1f}%", file=sys.stderr)
    print(f"───────────────────────", file=sys.stderr)

    # Output: just the Wayback URLs, one per line
    for _, _, url in final_urls:
        print(url)


if __name__ == "__main__":
    main()

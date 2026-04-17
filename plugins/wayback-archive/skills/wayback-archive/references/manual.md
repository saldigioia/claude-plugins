---
name: wayback-archive
description: Recover product databases from defunct e-commerce sites via Wayback Machine, CommonCrawl, and Shopify CDN archaeology.
argument-hint: "[--config CONFIG_FILE]"
allowed-tools:
  - Bash(python3 *)
  - Bash(cd *)
  - Read
  - Write
  - Grep
  - Glob
---

# Wayback Archive Pipeline

Self-contained pipeline for recovering product databases from defunct e-commerce sites.
Supports Shopify, Swell Commerce, Fourthwall, and custom platforms via config-driven
CDN patterns. Each stage has checkpoint/resume support.

```
Phase 1: DISCOVERY       -> Find what existed (CDX dump, CommonCrawl, CDN archaeology)
Phase 2: EXTRACTION      -> Get product data (fetch pages, extract metadata)
Phase 3: ASSET DOWNLOAD  -> Get images/media (live CDN first, Wayback fallback)
```

## Three Rules

1. **Always query BOTH Wayback AND CommonCrawl.** They have independent coverage.
   CommonCrawl yields 76% success for HTML; Wayback HTML yields 2.4%.

2. **For HTML, prefer CommonCrawl WARCs.** Wayback serves HTML through a JS replay
   framework. CommonCrawl WARCs contain the raw HTTP response with no wrapper.

3. **Filter the CDX dump first.** Raw dumps are 90%+ junk. `filter_cdx.py` reduces
   them by ~94% with zero product data loss.

For detailed extraction strategy and method hierarchy, see [references/extraction-strategy.md](references/extraction-strategy.md).

## Archival Discipline (Standing Protocols)

These five protocols are invariant. Violating any one of them means the pipeline is reporting progress it has not earned. See [../../docs/IMPROVEMENT_PLAN.md](../../docs/IMPROVEMENT_PLAN.md) for full rationale, phased execution, and the ledger schema that enforces them.

1. **Entity-first.** The unit of accounting is the product entity, not the captured file. A saved feed, sitemap, or collection HTML with no downstream expansion is not progress.
2. **Discovery is recursive.** Feeds, sitemaps, collection pages, homepages, search results, and JSON endpoints are discovery surfaces — never terminal artifacts. Every parse must emit outlinks into the ledger before the surface is marked processed.
3. **New host → immediate enumeration.** Any previously unseen hostname observed in any capture triggers an automatic CDX dump and product-URL enumeration. Do not wait for a human prompt.
4. **No "done" without audit.** Before reporting completion, answer five questions numerically: unresolved entities, unexpanded surfaces, index-missing entries, unenumerated hosts, retry-queue depth. Any non-zero count blocks the "done" claim unless annotated with a `terminal_reason`.
5. **Validate before counting.** Extracted strings are candidates, not slugs. Normalize → classify → reject non-product URLs (image assets, CDN paths) → dedupe against the index → report *candidates seen* and *validated-and-new* separately.

**Source-hierarchy priority** (drain highest-value first): `json_api > sitemap > feed > collection > home > search > product`. Prior runs burned time on HTML shells while `products.json?limit=1000` dumps sat unfetched — always prefer structured endpoints.

## Quick Start

```bash
# 1. Install dependencies
pip install -r requirements.txt

# 2. Copy and customize a config
cp skills/wayback-archive/configs/example.yaml configs/mysite.yaml

# 3. Run the full pipeline (with confirmation gates)
python3 scripts/run_stage.py all --config configs/mysite.yaml

# Or dry-run first
python3 scripts/run_stage.py all --config configs/mysite.yaml --dry-run
```

## Pipeline Stages

Nine stages, executed in order. Run individually or use `all`:

```bash
python3 scripts/run_stage.py <stage> --config configs/site.yaml [--dry-run]
```

| Stage | Purpose | Key Tool |
|-------|---------|----------|
| `cdx_dump` | Dump every Wayback snapshot URL for each domain | `tools/wayback_cdx` |
| `index` | Parse CDX + CommonCrawl discovery -> product index | `lib/wayback_archiver/cdx.py` |
| `filter` | 6-layer CDX filter (94% junk reduction) | `filter_cdx.py` |
| `fetch` | Queue-based cascade: direct -> CommonCrawl WARC -> proxy | `fetch_archive.py` |
| `cdn_discover` | Shopify CDN archaeology (finds delisted product images) | `shopify_downloader.py` |
| `match` | Fuzzy slug-to-SKU matching + dedup | `lib/wayback_archiver/match.py` |
| `download` | Image cascade: live CDN -> Wayback CDX best -> exhaustive | `lib/wayback_archiver/download.py` |
| `normalize` | Rename images, generate metadata.txt per product | `lib/wayback_archiver/normalize.py` |
| `build` | Compile final catalog JSON + stats | `lib/wayback_archiver/util.py` |

### Stage options

```bash
# Fetch with datacenter proxies and 3 workers
python3 scripts/run_stage.py fetch --config configs/site.yaml --proxy dc --workers 3

# Try alternative archives for failed URLs
python3 scripts/run_stage.py fetch --config configs/site.yaml --fallback-archives archive_today memento

# Full pipeline, skip confirmation prompts
python3 scripts/run_stage.py all --config configs/site.yaml --yes
```

## New Site Setup

1. Copy `skills/wayback-archive/configs/example.yaml` and customize domains
2. Bundled `tools/wayback_cdx` handles CDX dumps automatically
3. For Shopify: set `shopify_cdn.enabled: true` in config
4. Set proxy credentials: `OXYLABS_ISP_USER` / `OXYLABS_ISP_PASS` env vars
5. Dry-run first: `python3 scripts/run_stage.py all --config configs/mysite.yaml --dry-run`

For config field reference, see [references/site-config-schema.md](references/site-config-schema.md).

## Standalone Scripts

Each script works independently without `run_stage.py`:

```bash
# CDX dump
cd tools/ && python -m wayback_cdx --domain mystore.com --output raw_cdx.txt --resume

# Filter
python filter_cdx.py raw_cdx.txt > links.txt

# Fetch
python fetch_archive.py links.txt --resume [--proxy isp|dc] [--workers 5]

# Shopify CDN discovery
python shopify_downloader.py --store mystore.com --wayback-only --manifest-only
```

For detailed script documentation, see [references/tool-reference.md](references/tool-reference.md).

## Principles

1. Two-source discovery: always query BOTH Wayback AND CommonCrawl
2. Discovery before extraction: complete Phase 1 exhaustively before Phase 2
3. CommonCrawl WARCs for HTML: raw HTTP responses beat JS replay (76% vs 2.4%)
4. JSON APIs first: `products.json` is the holy grail
5. Triage by era: classify handles by platform before choosing extraction method
6. Test live CDN before Wayback: Shopify CDNs persist years after store closure
7. Paginate past caps: CDX defaults to 500 results — always check
8. Dedup before gap-chasing: ~40% of "missing" products are noise
9. Checkpoint/resume: every stage saves progress
10. Validate after download: check magic bytes to catch error pages

## Reference Documentation

- [references/extraction-strategy.md](references/extraction-strategy.md) — Extraction hierarchy, method selection, CommonCrawl WARC patterns
- [references/pipeline-stages.md](references/pipeline-stages.md) — Detailed per-stage documentation with inputs/outputs
- [references/tool-reference.md](references/tool-reference.md) — Script docs, URL modifiers, tool selection matrix
- [references/platform-support.md](references/platform-support.md) — Shopify, Swell, Fourthwall, Adidas platform notes
- [references/site-config-schema.md](references/site-config-schema.md) — YAML config field reference
- [references/data-contracts.md](references/data-contracts.md) — JSON schemas for stage inputs/outputs
- [references/playwright-wayback.md](references/playwright-wayback.md) — Last-resort Playwright extraction pattern
- [references/lessons-learned.md](references/lessons-learned.md) — Anti-patterns and best practices
- [../../docs/IMPROVEMENT_PLAN.md](../../docs/IMPROVEMENT_PLAN.md) — Multi-phase analysis/brainstorm/edit plan enforcing the standing protocols

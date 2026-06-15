# Reprocessing plan for pre-upgrade projects

Date: 2026-04-18
Plugin version in scope: wayback-archive @ marketplace HEAD (post-REVIEW_2026-04-18)
Projects root: `~/Downloads/design_new/projects/`

## Purpose

Four projects were scraped by older plugin versions before the current round
of fixes landed. This plan applies only the **new** capabilities to each
project — it does not re-run stages that would overwrite already-good output.
Each project has a different pre-state, so the command sequences differ.

Execution order is ascending risk: pablosupply (trivial cleanup) →
yeezysupply (targeted fetch re-run) → shop_kanyewest (bootstrap + re-match) →
yeezygap (most invasive, near-rebuild).

---

## Pre-flight: one-time setup for everyone

### 1. Credentials — do this before any command below

`fetch_archive.py` (lines 98–105) still has hardcoded Oxylabs credentials as
fallbacks. Until that is patched, export your own values so the fallbacks
never fire, and so this plan does not bill someone else's Oxylabs account:

```bash
export OXYLABS_ISP_USER="<your-isp-user>"
export OXYLABS_ISP_PASS="<your-isp-pass>"
export OXYLABS_DC_USER="<your-dc-user>"
export OXYLABS_DC_PASS="<your-dc-pass>"
```

If you don't have Oxylabs access, set `OXYLABS_ISP_USER=""` — the proxy path
will fail fast and the pipeline will fall back to direct Wayback fetches.

### 2. Snapshot each project before touching it

```bash
cd ~/Downloads/design_new/projects
for p in pablosupply shop_kanyewest yeezygap yeezysupply; do
  tar -cf "${p}_prerun_$(date +%Y%m%d).tar" \
    "${p}/config.yaml" "${p}/ledger.db" "${p}/audit.json" \
    "${p}/links" "${p}/products" "${p}/html" \
    2>/dev/null || true
done
```

Tar ignores missing members — projects that lack some of these paths just
get a thinner snapshot. Keep the tars until the plan completes.

### 3. Point the runner at the plugin you're reviewing

The plan assumes commands are run from inside the plugin directory so
imports resolve to the updated code:

```bash
cd ~/Downloads/claude-plugins/plugins/wayback-archive
```

All commands below use relative paths into `~/Downloads/design_new/projects/`.

### 4. New flags / env vars used in this plan

| Flag / env | What it does | Where it came from |
|---|---|---|
| `--include-ledger` | Drains `entities` table into index before stage runs (Protocol II fix) | `run_stage.py:_promote_ledger_entities` |
| `--match-strategy aggressive` | Enables `resolve_image_to_slug` fuzzy + SKU-prefix cascade | `match.py:189` |
| `WAYBACK_SKIP_CC=1` | Skips CommonCrawl domain probe; prevents the hang observed on yeezysupply | `run_stage.py:416` |
| `scripts/clean_surfaces.py` | Removes atom / oembed / collection URLs promoted to "products" by pre-4.3 builds | `scripts/clean_surfaces.py` |
| `scripts/split_collided_dirs.py` | Fixes per-variant slug collision (the pablosupply cross-contamination) | `scripts/split_collided_dirs.py` |
| `scripts/ledger.py import_index` | Rebuilds a ledger from an existing `*_products_index.json` | `scripts/ledger.py:cmd_import_index` |
| `scripts/import_cache.py` | Ingests a local HTML/image dir as already-fetched | `scripts/import_cache.py` |

---

## Project 1 — pablosupply (low risk, ~15 min)

### Current state
- Has ledger, config, audit. Pipeline ran to completion on post-ledger code.
- `audit.json` residual_total = 12:
  - `unresolved_slugs: 2` — two NYC long-sleeve tees that the matcher couldn't attribute.
  - `unexpanded_surfaces: 10` — all `*.oembed` surfaces plus homepage / help / map / digital_wallets dialog. These aren't products; they're junk surfaces the pre-clean-surfaces build recorded.
  - `index_missing: 0`, `unenumerated_hosts: 0`, `retry_queue_depth: 0`.

### What to run

```bash
# 1. Strip the non-product surfaces from the ledger and from catalog JSON.
python3 scripts/clean_surfaces.py \
  --config ../../../design_new/projects/pablosupply/config.yaml

# 2. Resume the pipeline — lets _promote_ledger_entities re-materialize the
#    two unresolved slugs into the index, then runs match with the new
#    aggressive cascade (direct hit → __ split → SKU prefix → substring →
#    difflib 0.85).
python3 scripts/run_stage.py resume \
  --config ../../../design_new/projects/pablosupply/config.yaml \
  --include-ledger --match-strategy aggressive --auto

# 3. Re-audit.
python3 scripts/audit.py \
  --config ../../../design_new/projects/pablosupply/config.yaml
```

### Expected delta
- 10 `unexpanded_surfaces` → 0 (clean_surfaces removes them from catalog + metadata JSON, ledger reconciles).
- 2 `unresolved_slugs` → 0 or 1 (the aggressive matcher should attribute
  `we-young-and-we-alive-black-long-sleeve-t-shirt-nyc` and
  `who-your-real-friends-white-crewneck-nyc` via substring against the
  existing NYC t-shirt family).
- Downloaded image count should not decrease. If it does, roll back from the tar.

### Rollback
`tar -xf pablosupply_prerun_*.tar` from `~/Downloads/design_new/projects/`.

---

## Project 2 — yeezysupply (medium risk, ~1–2 hrs, network-bound)

### Current state
- Ledger at non-standard path `pipeline_state/ledger.db` (the runner has logic to find it).
- 470 product dirs, 3 files in `cdn_images/`, 31 hosts dumped.
- `audit.json` residual_total = 1073, broken down:
  - `index_missing: 916` — real SKUs and some slugs that were discovered in surfaces but whose fetches never landed in the index. Largely a consequence of the CommonCrawl hang aborting the fetch stage early.
  - `retry_queue_depth: 113` — almost all akamai pixel URLs (`/akam/11/pixel_*`) and sitemap XMLs. These are genuinely non-fetchable and will stay in the queue until we filter them.
  - `unresolved_slugs: 44` — real product slugs that need the new matcher.
  - `unexpanded_surfaces: 0`.

### What to run

```bash
# 1. Remove akamai pixel + sitemap.xml entries from the retry queue. They
#    will never resolve and they pollute the audit signal.
python3 scripts/ledger.py prune-retry \
  --config ../../../design_new/projects/yeezysupply/config.yaml \
  --url-regex '/akam/11/pixel_|sitemap[^/]*\.xml$'
# If ledger.py doesn't yet have `prune-retry`, use this SQLite one-liner:
sqlite3 ../../../design_new/projects/yeezysupply/pipeline_state/ledger.db \
  "DELETE FROM fetch_attempts WHERE status='retry'
   AND (url LIKE '%/akam/11/pixel_%' OR url LIKE '%/sitemap%.xml');"

# 2. Re-fetch the 916 index_missing entries, but skip CommonCrawl this round
#    — it hangs on yeezysupply's subdomain set.
WAYBACK_SKIP_CC=1 python3 scripts/run_stage.py fetch \
  --config ../../../design_new/projects/yeezysupply/config.yaml \
  --include-ledger --auto

# 3. Re-match with the aggressive cascade. The 44 unresolved slugs should
#    mostly land via SKU-prefix and substring rules.
python3 scripts/run_stage.py match \
  --config ../../../design_new/projects/yeezysupply/config.yaml \
  --include-ledger --match-strategy aggressive --auto

# 4. Download anything newly matched.
python3 scripts/run_stage.py download \
  --config ../../../design_new/projects/yeezysupply/config.yaml --auto

# 5. Normalize + build + audit.
python3 scripts/run_stage.py normalize \
  --config ../../../design_new/projects/yeezysupply/config.yaml --auto
python3 scripts/run_stage.py build \
  --config ../../../design_new/projects/yeezysupply/config.yaml --auto
python3 scripts/audit.py \
  --config ../../../design_new/projects/yeezysupply/config.yaml
```

### Expected delta
- `retry_queue_depth`: 113 → ~0 (akamai / sitemap noise filtered out).
- `index_missing`: 916 → 200–400 (not all will resolve; some SKUs really
  aren't in Wayback at all).
- `unresolved_slugs`: 44 → 5–15 (aggressive matcher handles the bulk).
- `products_with_images`: 54 → 150–250 (biggest real win — these SKUs have
  images in the pool that previously couldn't be attributed).

### Risks
- The fetch stage will open proxy sessions. Watch Oxylabs bandwidth.
- If CC_DOMAIN_BUDGET_SEC trips on a subdomain, that host is skipped this
  round; re-run with `--only-hosts` if needed.
- Do **not** run `cdx_dump` — it re-hits the whole domain set for no reason
  on a project that already has all 31 hosts dumped.

### Rollback
Restore tar. The ledger DB is the only stateful thing touched; catalog JSON
and product dirs are append-only during this sequence.

---

## Project 3 — shop_kanyewest (high yield, ~2–3 hrs)

### Current state
- **No ledger, no config.yaml, no audit.json.** This project predates the
  ledger-aware pipeline entirely.
- Has 348 HTML captures, 338 filtered links, **59 product dirs** — a ~17%
  match rate. This is the project that produced the "10% download match
  rate" pain point in the review.
- Has catalog JSON, metadata JSON, products_index JSON, commoncrawl_index
  JSON. The mining ran; the attribution stage just gave up on most of it.

### What to run

```bash
# 1. Bootstrap generates config.yaml and seeds a ledger from the domain
#    surface discovery. --reuse-existing keeps already-mined files in place.
python3 scripts/bootstrap.py \
  --input "https://shop.kanyewest.com" \
  --name shop_kanyewest \
  --project-root ../../../design_new/projects \
  --reuse-existing

# 2. Import the existing products_index.json into the fresh ledger so the
#    entities table mirrors what's already on disk.
python3 scripts/ledger.py import-index \
  --config ../../../design_new/projects/shop_kanyewest/config.yaml \
  --index ../../../design_new/projects/shop_kanyewest/shop_kanyewest_products_index.json

# 3. Import existing HTML captures as already-fetched so the fetch stage
#    doesn't re-hit Wayback for pages we already have.
python3 scripts/import_cache.py \
  --config ../../../design_new/projects/shop_kanyewest/config.yaml \
  --html-dir ../../../design_new/projects/shop_kanyewest/html

# 4. Drop any atom / collection / oembed surfaces that old mining promoted
#    into "products".
python3 scripts/clean_surfaces.py \
  --config ../../../design_new/projects/shop_kanyewest/config.yaml

# 5. Split any collided slug dirs (per-variant cross-contamination — this is
#    what we saw on pablosupply; shop_kanyewest is the same platform era).
python3 scripts/split_collided_dirs.py \
  --config ../../../design_new/projects/shop_kanyewest/config.yaml

# 6. Re-run just the attribution/download half of the pipeline. The first
#    four stages (cdx_dump → index → filter → fetch) are effectively already
#    done via the imports above.
python3 scripts/run_stage.py cdn_discover \
  --config ../../../design_new/projects/shop_kanyewest/config.yaml --auto
python3 scripts/run_stage.py match \
  --config ../../../design_new/projects/shop_kanyewest/config.yaml \
  --include-ledger --match-strategy aggressive --auto
python3 scripts/run_stage.py download \
  --config ../../../design_new/projects/shop_kanyewest/config.yaml --auto
python3 scripts/run_stage.py normalize \
  --config ../../../design_new/projects/shop_kanyewest/config.yaml --auto
python3 scripts/run_stage.py build \
  --config ../../../design_new/projects/shop_kanyewest/config.yaml --auto
python3 scripts/audit.py \
  --config ../../../design_new/projects/shop_kanyewest/config.yaml
```

### Expected delta
- Product dirs: 59 → 180–280. This is the biggest single win in the plan.
  The existing 338 links and 348 HTMLs were not the bottleneck — the matcher
  was. With SKU-prefix extraction, substring, and difflib-0.85 now in play,
  most Shopify CDN image URLs that carry `GX9662_…jpg` style codes or a
  slug-like stem will attribute.
- `regional_shops_*` files in the root are **orthogonal**; the bootstrap
  above does not touch them. If they need reprocessing, repeat this
  sequence with a second config for `regional_shops.*` — out of scope here.

### Risks
- Bootstrap writes a fresh config.yaml. The old (non-existent) config isn't
  a reference, but the bootstrap-generated template may pick different
  hosts than the old CDX dumps used. Check `config.yaml` after step 1 and
  confirm it names the hosts whose `*_wayback.txt` files already exist on
  disk; if not, add them by hand before step 2.
- `import_cache.py` uses filename-reverse to resolve URLs. Some HTMLs may
  not map back cleanly; those become unreferenced and the fetch stage will
  try to re-fetch them. Acceptable.
- cdn_discover will probe shopify CDN patterns. This is new work on a
  project that skipped it — expect 10–20 minutes of network I/O.

### Rollback
Restore tar. Additionally, delete the freshly-created `config.yaml`,
`ledger.db`, and `audit.json` — they didn't exist before.

---

## Project 4 — yeezygap (highest risk, near-rebuild, ~3–4 hrs)

### Current state
- **No ledger, no config, no audit, no `links/` dir, no `products/` dir.**
  Catalog has 8 entries. Essentially unprocessed by any ledger-aware stage.
- Has: 342 HTML files, **1813 images in `shopify_images/`** (gold —
  already downloaded but unattributed), 688 filtered URLs, 23 sitemap
  dumps, dead_wayback_urls.txt (a record of fetch failures).
- This is the project where a pre-4.3 run promoted sitemap + collection +
  atom URLs to "products". Any artifact that smells like a surface needs
  clean_surfaces before it contaminates the fresh ledger.

### What to run

```bash
# 1. Bootstrap. For yeezygap.com the platform signature detection should
#    land on Shopify; verify the generated config before continuing.
python3 scripts/bootstrap.py \
  --input "https://www.yeezygap.com" \
  --name yeezygap \
  --project-root ../../../design_new/projects \
  --reuse-existing

# 2. Sanity-check the generated config. Confirm the hosts list contains at
#    least: www.yeezygap.com, yeezygap.com, yeezygap.myshopify.com.
cat ../../../design_new/projects/yeezygap/config.yaml

# 3. Import the existing filtered URL list as the index seed.
python3 scripts/ledger.py import-index \
  --config ../../../design_new/projects/yeezygap/config.yaml \
  --urls ../../../design_new/projects/yeezygap/filtered_urls.txt

# 4. Import existing HTML as already-fetched.
python3 scripts/import_cache.py \
  --config ../../../design_new/projects/yeezygap/config.yaml \
  --html-dir ../../../design_new/projects/yeezygap/html

# 5. Import existing images as already-downloaded — this is what avoids
#    re-fetching 1813 files from Shopify CDN.
python3 scripts/import_cache.py \
  --config ../../../design_new/projects/yeezygap/config.yaml \
  --image-dir ../../../design_new/projects/yeezygap/shopify_images

# 6. Strip atom / collection / oembed surfaces that mining recorded.
python3 scripts/clean_surfaces.py \
  --config ../../../design_new/projects/yeezygap/config.yaml

# 7. Run the attribution half of the pipeline with the aggressive matcher —
#    this is where resolve_image_to_slug earns its keep, because we have
#    1813 orphan images to attribute to ~200 slugs.
python3 scripts/run_stage.py cdn_discover \
  --config ../../../design_new/projects/yeezygap/config.yaml --auto
python3 scripts/run_stage.py match \
  --config ../../../design_new/projects/yeezygap/config.yaml \
  --include-ledger --match-strategy aggressive --auto
python3 scripts/run_stage.py download \
  --config ../../../design_new/projects/yeezygap/config.yaml --auto
python3 scripts/run_stage.py normalize \
  --config ../../../design_new/projects/yeezygap/config.yaml --auto
python3 scripts/run_stage.py build \
  --config ../../../design_new/projects/yeezygap/config.yaml --auto
python3 scripts/audit.py \
  --config ../../../design_new/projects/yeezygap/config.yaml
```

### Expected delta
- Product dirs: 0 → 80–180. The filtered_urls list suggests ~200 product
  URLs exist; not all will have attributable imagery, but most should.
- Catalog entries: 8 → 80+.
- 1813 orphan images → majority attributed via filename SKU prefix,
  slug-stem, or difflib fallback; residual orphans land in cdn_images with
  no SKU edge (expected — some Shopify CDN assets are genuinely cross-used
  in recommendation widgets).

### Risks
- Bootstrap may pick the wrong platform if yeezygap's Wayback captures
  don't expose a clear Shopify fingerprint (the live domain is gone).
  If that happens, copy `config-templates/shopify.yaml` manually and set
  `platform: shopify` by hand.
- The biggest unknown is `filtered_urls.txt` quality. 688 URLs is more than
  the 200-ish the catalog suggests; some of those are likely surfaces
  (collections, pages, cart). `clean_surfaces.py` after `import-index`
  should catch them, but verify the first-stage ledger has sane entity
  counts before running match.
- If bootstrap-generated CDX dumps ends up triggering (because ledger has
  no dumped hosts), **abort and set `already_dumped: true` per host** in
  the config. The existing `*_wayback.txt` files are authoritative.

### Rollback
Restore tar. Delete newly-created `config.yaml`, `ledger.db`, `audit.json`,
`products/`, `links/`. The gold asset (`shopify_images/`) is read-only
throughout.

---

## Verification after each project

After each project's final `audit.py` run, check:

1. `audit.json.status == "clean"` **or** residuals are documented here as
   expected (e.g. akamai pixels in retry queue that cannot resolve).
2. `products_with_images` went up, not down.
3. Spot-check 3 random product dirs for the `metadata.txt` + image files.
4. No stack trace in the stage logs. The most likely failure modes:
   - `metadata.py:44` AttributeError — should be fixed; confirm the
     isinstance guards are live (`extract_api_metadata` lines 50–64).
   - `alt_archives` hang on archive.today / memento — the `_AltBreaker`
     circuit breaker should trip after 3 consecutive misses per host.

---

## Known issues to flag before you run this

1. **Hardcoded Oxylabs credentials in `fetch_archive.py:98-105`** are still
   present in the marketplace plugin. The pre-flight section above exports
   env vars that override them, but the file itself should be patched to
   remove the literal defaults before this plugin gets shared further.
2. **`scripts/ledger.py prune-retry`** subcommand may not exist yet — the
   SQLite one-liner under yeezysupply step 1 is the fallback.
3. **`scripts/import_cache.py --image-dir`** path is assumed; if the flag
   is named `--images` or `--assets`, check `import_cache.py --help` first.
4. The four projects should be run **sequentially**, not in parallel. They
   compete for the same Oxylabs proxy pool and will rate-limit each other.

---

## TL;DR

```
pablosupply     ~15 min    12 residuals → 0
yeezysupply     ~1-2 hrs   ~1000 residuals → ~250
shop_kanyewest  ~2-3 hrs   59 products → ~250
yeezygap        ~3-4 hrs   0 products → ~120
```

Total wall-clock if run back-to-back: 6–9 hours. Biggest single yield:
shop_kanyewest's matcher re-run. Biggest risk: yeezygap's bootstrap
possibly misreading platform signature; have the shopify template ready.

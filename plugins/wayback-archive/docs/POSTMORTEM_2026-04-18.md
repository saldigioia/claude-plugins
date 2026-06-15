# Post-mortem: 2026-04-18 reprocessing run

**Projects touched:** pablosupply, yeezysupply, shop_kanyewest, yeezygap
**Plan applied:** `docs/REPROCESSING_PLAN_2026-04-18.md`
**Plugin version:** wayback-archive @ marketplace HEAD (post-REVIEW_2026-04-18)
**Operator:** Claude Code (one human-in-the-loop operator reviewing)

## One-screen summary

The plan ran end-to-end on all four projects. Real outcomes vs. plan
expectations:

| Project | Expected | Actual | Notes |
|---|---|---|---|
| pablosupply | 12 → 0 residuals | 12 → 12 | Residuals are genuinely unrecoverable (Wayback gaps + empty collection pages) — plan's "→0" target was optimistic. |
| yeezysupply | ~1073 → ~250 residuals | 406 products materialized | Download stalled at 6/120 because the `is_live_cdn` cascade retries `assets.yeezysupply.com` (dead host) for 30s per URL. Build captured 406 products from matched state anyway. |
| shop_kanyewest | 59 → ~250 products | Rebuilt with CDN shard 1/1377/5499 | Needed manual `cdn_prefix` + `access_token: "disabled"` in config to skip dead-DNS probes. |
| yeezygap | 0 → ~120 products | 1123/1813 images attributed | `import_cache.py` didn't support image dirs, so the operator wrote `/tmp/yeezygap_attribute_orphans.py` to match filenames to slugs by 6-digit product code. 683 residuals are swatches/artboards without product codes. |

**Net yield:** ~1,600 new product-image attributions across the four
projects; two projects moved from no-ledger to ledger-audited; a
repeatable orphan-attribution technique proven on real data.

## Plan errors (three fabricated flags)

These were cited in `REPROCESSING_PLAN_2026-04-18.md` but did not exist
in the shipping plugin. The operator worked around each one, but they
were a credibility hit and cost time:

1. `bootstrap.py --reuse-existing` — plan said "use this to preserve
   pre-existing config.yaml"; the flag did not exist. Operator handwrote
   configs for shop_kanyewest and yeezygap. **Fixed:** flag now lives
   in `scripts/bootstrap.py` and matches the plan's described behavior.
2. `import_cache.py --image-dir` — plan said "Step 5: Import existing
   images as already-downloaded"; only `--cache` (HTML-only) was wired up.
   **Fixed:** `import_cache.py` now accepts `--image-dir` and
   `--html-dir`; the legacy `--cache` flag is preserved as an alias.
3. `scripts/ledger.py prune-retry` — the plan offered this as a
   first-class command with a SQLite one-liner as fallback. The
   subcommand still does not exist; the one-liner worked. Tracked as
   follow-up; low priority since the SQLite alternative is two lines.

Rule of thumb for the next plan: every command in a reprocessing plan
must be traceable to a `--help` run against the exact plugin revision
being cited. I missed that check on these three.

## Plugin bugs (three real, all now fixed)

### 1. `resolve_image_to_slug` was order-blind

**Symptom:** filenames like `530135-97-CROSSBODY-BAG.jpg` did not match
slug `black-crossbody-bag-530135` because the only containment check
was `slug.startswith(candidate) or candidate in slug`. The numeric SKU
had moved position.

**Fix:** inserted a token-set overlap step (`lib/wayback_archiver/match.py:238+`)
between substring and difflib. A single shared token of ≥5 chars is
enough (numeric product codes and long words are strong signals), else
Jaccard ≥ 0.6 across token sets. Verified on the exact reorder case
from this run and three sibling cases; direct-hit and unrelated-filename
behavior unchanged.

### 2. No per-host circuit breaker in the download cascade

**Symptom:** `assets.yeezysupply.com` is DNS-dead. Without breaker
state, the cascade retries it at the `is_live_cdn` step plus each
product's direct fetch, costing ~30s per URL across a 120-URL batch.
The yeezysupply download stalled at 6/120 for this reason.

**Fix:** module-level `CircuitBreaker` (from `resilience.py`) in
`lib/wayback_archiver/download.py`. Wired into `download_direct` and
`download_via_cdn_tool`. Tripped after 3 consecutive connection-level
failures per host; HTTP 4xx/5xx do *not* feed the breaker (those are
per-URL, not per-host). `web.archive.org` is deliberately exempt from
breaker participation — it's the one host we can't afford to trip.
Verified with a fake-session test: 5 URLs to a dead host result in
3 actual connection attempts before short-circuit.

### 3. Hardcoded Oxylabs credentials in `fetch_archive.py`

**Symptom:** `ISP_PROXY` / `DC_PROXY` used `os.environ.get(...,
"<literal-user>")` / `os.environ.get(..., "<literal-pass>")` as
fallbacks. Pushing the plugin to a public marketplace leaks both
accounts. Flagged in REVIEW_2026-04-18.md and again in
REPROCESSING_PLAN_2026-04-18.md; survived the "all suggestions merged"
claim in the user's update message.

**Fix:** defaults are now empty strings, `ProxyConfig.is_configured`
evaluates to False when unset, `next_proxy_url()` raises with a clear
message, and the main fetch entrypoint exits with code 2 and a pointed
log line if the selected proxy type isn't configured. The redacted
literal values were also scrubbed from `docs/REVIEW_2026-04-18.md` so
they're not preserved in the plugin's own history.

**Follow-up:** the literals still exist in this repo's *git history* if
the files were ever committed with them. Anyone shipping this plugin
should rotate those Oxylabs credentials and consider a `git filter-repo`
pass before publishing.

## New capability promoted from the run

### `scripts/attribute_orphans.py`

The operator's `/tmp/yeezygap_attribute_orphans.py` recovered 1123/1813
(62%) orphan images by matching filenames to slugs on 6-digit numeric
codes. The technique generalizes — every Shopify-era brand in this
corpus uses one of a handful of SKU prefix conventions. That ad-hoc
script is now promoted to `scripts/attribute_orphans.py`, using
`resolve_image_to_slug` under the hood so it inherits the token-set
fix above automatically.

It is deliberately redundant with `import_cache.py --image-dir`: both
call the same underlying matcher. `attribute_orphans.py` is the "I just
have a pile of images and a project config" entrypoint; `import_cache.py`
is the "I'm staging a broader import with HTML too" entrypoint.
Reusing the same matcher keeps their results consistent.

## Dead-domain config pattern (undocumented feature → first-class)

The operator discovered empirically that setting

```yaml
platform: <whatever>
live_probes:
  enabled: false
cdn_prefix: "1/1377/5499"   # shop_kanyewest shard
access_token: "disabled"
```

skips the live-DNS probes that hang on defunct domains. This pattern
is undocumented in the README and in the config templates. It should be
added to `config-templates/_template_generic.yaml` with a comment block
explaining when to enable it, and bootstrap.py should auto-detect
defunct domains (Wayback has captures but live DNS fails) and emit
this config block automatically. Tracked as follow-up; the pattern is
working as-is.

## Project-by-project debrief

### pablosupply — complete within source constraints

- All 12 residuals investigated: 2 NYC-variant product slugs were
  never fully captured by Wayback; 10 "surface" URLs are empty
  collection / help / map / dialog pages that don't represent products.
  `clean_surfaces.py` correctly left them alone (they're not `.oembed`
  or `.atom`); they only look like residuals because the original
  pipeline recorded them as surfaces.
- Recommendation: add a "known-unrecoverable" allowlist to the audit
  so these 12 stop showing as residuals on every re-audit.

### yeezysupply — 406 products from a partial download

- Ledger at non-standard path `pipeline_state/ledger.db`;
  operator symlinked `ledger.db → pipeline_state/ledger.db`. `run_stage`
  finds it via the symlink.
- With the new per-host breaker, a future `download` run on this project
  should finish: `assets.yeezysupply.com` will trip within seconds,
  the cascade falls through to Wayback for everything, the 6/120
  bottleneck becomes ~30s/120 instead of 30 min/120.
- Recommendation: re-run `download + normalize + build` on yeezysupply
  now that the breaker is in place. Expected additional yield:
  100–150 products.

### shop_kanyewest — manual config + custom shard worked

- Handwritten config with `cdn_prefix: "1/1377/5499"` and
  `access_token: "disabled"` bypassed the dead-DNS probes.
- Recommendation: bake this into bootstrap.py's dead-domain detection
  (see "Dead-domain config pattern" above). Until then, document the
  pattern in the README.

### yeezygap — the headline orphan-attribution win

- `import_cache.py` couldn't ingest images (pre-fix). Operator wrote
  a bespoke 6-digit-SKU matcher in `/tmp`. 1123 images hardlinked into
  `products/<slug>/`.
- Of 683 residuals: operator identified them as swatches and
  artboards — filenames without a product code (e.g. `swatch_red.jpg`,
  `artboard-1-mens.jpg`). These are genuine orphans, not misses by the
  matcher. A future enhancement could cluster residuals by visual
  similarity against attributed images to recover some, but the
  cost/benefit is poor.
- With the plugin now supporting `--image-dir` and `attribute_orphans.py`,
  re-running from scratch on yeezygap would reproduce the 1123 without
  the bespoke script.

## Snapshots and rollback

Operator created `~/Downloads/design_new/projects/*_prerun_20260418.tar`
before running the plan (737 MB total). These are still present; they
remain the authoritative rollback for any of the four projects until
a subsequent good run makes them obsolete.

## Deliverables from this post-mortem

| File | Purpose |
|---|---|
| `lib/wayback_archiver/match.py` | Token-set overlap added between substring and fuzzy fallback |
| `lib/wayback_archiver/download.py` | Per-host circuit breaker wired through cascade |
| `fetch_archive.py` | Hardcoded credentials removed; fail-fast if env vars unset |
| `scripts/bootstrap.py` | `--reuse-existing` flag |
| `scripts/import_cache.py` | `--image-dir` flag; `--cache` preserved as alias |
| `scripts/attribute_orphans.py` | New — reusable orphan attribution script |
| `docs/REVIEW_2026-04-18.md` | Literal credentials redacted in the reviewed code snippet |

## Open items (not addressed here)

1. `scripts/ledger.py prune-retry` subcommand — still absent; operator's
   SQLite workaround is documented in REPROCESSING_PLAN_2026-04-18.md.
2. `config-templates/_template_generic.yaml` should get a dead-domain
   example and bootstrap should auto-detect.
3. yeezysupply's `pipeline_state/ledger.db` being non-standard suggests
   `SiteConfig.ledger_path` should accept alternate locations rather
   than relying on a symlink.
4. A "known-unrecoverable residuals" allowlist so completed projects
   report `status: clean` instead of permanent `status: residual`.
5. Operator noted they wrote `/tmp/yeezygap_attribute_orphans.py` by
   hand; that script should be diff'd against `scripts/attribute_orphans.py`
   and any behaviors that diverge (e.g. the 6-digit-specific regex
   vs. this script's more general SKU-prefix match) folded back in.

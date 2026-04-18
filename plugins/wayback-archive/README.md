# wayback-archive

Claude Code plugin for recovering complete product databases (catalog data + images) from defunct e-commerce websites using the Wayback Machine, CommonCrawl, and Shopify CDN archaeology.

Supports Shopify, Swell Commerce, Fourthwall, and custom platforms via config-driven CDN patterns.

## Installation

Add the marketplace and install:

```
/plugin marketplace add saldigioia/claude-plugins
/plugin install wayback-archive@rare-data-club
```

Then install Python dependencies:

```bash
pip install -r ~/.claude/plugins/cache/rare-data-club/wayback-archive/1.2.0/requirements.txt
```

### Local development

```bash
claude --plugin-dir ./wayback-archive
```

## Turn-key usage

The skill takes a URL and handles everything else:

```
/wayback-archive:wayback-archive https://kanyewest.com
```

What happens on the back end:

1. **Bootstrap** (`scripts/bootstrap.py`) — parses the URL, enumerates captured subdomains via Wayback CDX, probes the live site (and Wayback fallback) for platform signatures (Shopify / Swell / Fourthwall / Adidas), detects `.myshopify.com` aliases, writes `projects/<name>/config.yaml` from the matching template, and seeds a SQLite ledger with every host.
2. **Pre-flight** — validates Python version, deps, CDX tool, Oxylabs credentials (if configured), archive.org reachability, disk space. Halts fast on blocking errors.
3. **Nine-stage pipeline** — `cdx_dump → index → filter → fetch → cdn_discover → match → download → normalize → build`. Progress streams to `projects/<name>/.progress.jsonl`.
4. **Audit** — Protocol IV five-integer check (`unresolved_slugs`, `unexpanded_surfaces`, `index_missing`, `unenumerated_hosts`, `retry_queue_depth`). Exit code 0 iff all zero. Writes `projects/<name>/audit.json`.

If residuals remain, re-run only the stage that would shrink the largest bucket:

```bash
python3 scripts/run_stage.py resume --config projects/<name>/config.yaml --auto
```

## Manual usage

For targeted work or when the skill's default flow isn't right:

```bash
# 1. Scaffold a project from a URL (writes config.yaml + seeds ledger)
python3 scripts/bootstrap.py --input "https://mystore.com"

# 2. Optional: pre-flight (deps, creds, reachability, disk)
python3 scripts/preflight.py --config projects/mystore/config.yaml

# 3. Full pipeline
python3 scripts/run_stage.py all --config projects/mystore/config.yaml --auto

# 4. Post-hoc audit
python3 scripts/audit.py --config projects/mystore/config.yaml

# 5. Resume a partial run (picks largest residual bucket)
python3 scripts/run_stage.py resume --config projects/mystore/config.yaml --auto
```

## Prerequisites

- Python 3.10+
- `pip install -r wayback-archive/requirements.txt`
- Proxy credentials (optional, for large-scale CDX dumps): copy `wayback-archive/tools/.env.example` to `wayback-archive/tools/.env` and fill in `OXY_ISP_USER` / `OXY_ISP_PASS`. The dotenv file auto-loads — no `export` needed.

## Where projects land

Recovered catalogs live at `<projects-root>/<name>/`. Precedence for the root:

1. `--project-root <path>` on `bootstrap.py`
2. `$WAYBACK_ARCHIVE_ROOT` environment variable
3. `~/wayback-archive/` (default)

**Intentionally outside the plugin install dir.** When the plugin is installed via `/plugin install`, its files live at `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/` and get replaced on every version update — placing projects there means a plugin update silently wipes every recovered catalog. The user home default persists across plugin installs.

## Pipeline

```
cdx_dump -> index -> filter -> fetch -> cdn_discover -> match -> download -> normalize -> build
```

Nine stages from domain name to complete product catalog. Run individually, bundled via `all`, or targeted via `resume`. See the [skill documentation](wayback-archive/skills/wayback-archive/SKILL.md) for details.

## The ledger (Protocol IV)

Each project has a SQLite ledger at `projects/<name>/ledger.db` with four tables: `discovery_surfaces`, `entities`, `hosts`, `fetch_attempts`. Populated by bootstrap (hosts) and each pipeline stage (entities on index, host-dumped stamps on cdx_dump completion). When the ledger is present, `audit.py` reports exact counts for the five Protocol IV integers; when absent, it falls back to a disk-scan approximation. Run the ledger CLI directly:

```bash
python3 scripts/ledger.py status --config projects/<name>/config.yaml
python3 scripts/ledger.py audit --config projects/<name>/config.yaml   # CI-gradable exit code
```

## Structure

```
wayback-archive/
├── .claude-plugin/
│   ├── plugin.json              # Plugin manifest
│   └── marketplace.json         # Marketplace catalog
├── skills/wayback-archive/      # Skill definition + reference docs
├── scripts/                     # bootstrap, preflight, run_stage, audit, ledger
├── lib/wayback_archiver/        # Python library (ledger, http_client, env, …)
├── tools/                       # Bundled tools (wayback_cdx, cdn probe)
├── fetch_archive.py             # Multi-strategy page fetcher
├── filter_cdx.py                # CDX dump filter
├── shopify_downloader.py        # Shopify CDN archaeology
└── requirements.txt             # Python dependencies
```

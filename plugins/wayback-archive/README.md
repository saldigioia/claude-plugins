# wayback-archive

Claude Code plugin for recovering complete product databases (catalog data + images) from defunct e-commerce websites using the Wayback Machine, CommonCrawl, and Shopify CDN archaeology.

Supports Shopify, Swell Commerce, Fourthwall, and custom platforms via config-driven CDN patterns.

## Scope — and when to use `hunt` instead

This plugin rebuilds **one thing**: the product catalog of a defunct store, end to end. It is a
heavy, stateful run — Python dependencies, a SQLite ledger, nine resumable stages, tens of
minutes. That cost only pays off against a storefront with a real catalog behind it.

Reach for [`hunt`](../hunt/) instead when:

| Situation | Use |
|---|---|
| The dead site is **not a storefront** — a photographer, a magazine, a brand microsite | `hunt` — `/hunt:recon` |
| You want **one image** at its highest fidelity, or one gallery | `hunt` — `/hunt:master` |
| You don't yet know **whether the site is dead**, or where its assets survive | `hunt` — `/hunt:recon` |
| You have a `.har`, a bare CDN URL, or an unknown host | `hunt` — `/hunt:master` |
| A dead **store** whose whole catalog you want rebuilt | **this plugin** |

**Recon first is also the better road into this plugin.** `/hunt:recon` runs an authoritative
Wayback CDX census (`matchType=domain`, every subdomain, every depth, with a completeness check)
plus DNS, certificate-transparency, and reverse-IP host discovery. `bootstrap.py`'s own host
enumeration is a single bounded `limit=5000` sample by comparison. Handing recon's host list to
bootstrap is a strict upgrade, and it works today with no extra tooling:

```bash
bash ../hunt/scripts/recon.sh -o ./recon-mystore mystore.com
python3 scripts/bootstrap.py --from-recon ./recon-mystore/recon.json
```

`--from-recon` consumes `recon.json` (schema 1) and, versus deriving everything itself:

- replaces the bounded host sample with recon's full census;
- carries over the storefront platform verdict and any `.myshopify` alias;
- **drops hosts attested only by wildcard DNS** — under a wildcard zone every name resolves, so
  those are not evidence, and they would otherwise be dumped and tracked forever;
- **skips speculative common-prefix hosts when the census is complete**, since a guessed host is
  then guaranteed to dump empty and inflate the ledger's `unenumerated_hosts` for the whole run;
- surfaces recon's `spa_catch_all` and `wildcard_dns` warnings in the plan's `recon` block, so a
  fake-200 host doesn't get mistaken for a live one downstream.

A live platform probe still wins over recon's verdict when it matches — a store can migrate
platforms before it dies, and the archived record may name the earlier era.

## Installation

Add the marketplace and install:

```
/plugin marketplace add saldigioia/claude-plugins
/plugin install wayback-archive@rare-data-club
```

Then install Python dependencies. The install directory is version-stamped, so resolve the
current one rather than hardcoding a version that goes stale on every release:

```bash
pip install -r "$(ls -d ~/.claude/plugins/cache/rare-data-club/wayback-archive/*/ | sort -V | tail -1)requirements.txt"
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

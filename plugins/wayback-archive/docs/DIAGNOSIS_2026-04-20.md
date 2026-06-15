# Wayback-Archive plugin — diagnosis & fix plan (2026-04-20)

Three reported symptoms, traced to specific files and lines. Fixes are
sequenced: **paths → cache → scraping**. No edits yet.

---

## Issue 1 — Outputs land in a sandbox, not where the plugin was invoked

### Root cause

`scripts/bootstrap.py:50-66`:

```python
def _default_projects_root() -> Path:
    env = os.environ.get("WAYBACK_ARCHIVE_ROOT")
    if env:
        return Path(env).expanduser().resolve()
    return (Path.home() / "wayback-archive").resolve()
```

The default root is `~/wayback-archive/`. Under Cowork, `Path.home()`
resolves inside the ephemeral session sandbox
(`/sessions/wizardly-great-franklin/...`), not inside the folder the user
selected. That's why results vanish and "never get imported into the
project directory" — they were never written *to* the project directory
in the first place.

A second, more subtle point: `SKILL.md` tells Claude to run downstream
stages from `<config_path>` *absolute paths* in `plan.json`. That code
path is correct in principle, but when bootstrap computes the absolute
path using the sandboxed `~/wayback-archive/<name>`, the config still
points inside the sandbox even if the user later cd's into the repo.

### Fix (what I'm proposing)

Change the default-root precedence to:

1. `$WAYBACK_ARCHIVE_ROOT` (unchanged — lets CI/users override).
2. `<repo-root>/projects/` if invoked from inside the plugin repo
   (detected via `REPO_ROOT / ".claude-plugin" / "plugin.json"` sentinel).
   This is the "in the codebase where it was summoned from" behavior.
3. Fallback to `Path.home() / "wayback-archive"` only when step 2 fails
   (i.e., plugin installed into a pip-style cache, as the original
   docstring worries about).

Touchpoints:
- `scripts/bootstrap.py:_default_projects_root` — new precedence.
- `skills/wayback-archive/SKILL.md` — update the "Where projects land"
  paragraph to match.
- `.gitignore` — add `projects/` so in-repo projects don't pollute
  future commits (there's no `.gitignore` currently; I'll add one).

### Acceptance test

`python3 scripts/bootstrap.py --input "example.com" --dry-run` run from
the repo root should print `"projects_root": "<repo>/projects"` in its
plan JSON. Run from `/tmp/anywhere` (no sentinel), it falls back to
`~/wayback-archive` as today.

---

## Issue 2 — Cache/checkpoint leakage that inhibits future runs

Four distinct leaks, all hidden inside the plugin tree:

### 2a. CDX checkpoints land in `tools/`, not in the project

`tools/wayback_cdx/checkpoint.py:154-157`:

```python
def default_checkpoint_path(domain: str) -> Path:
    safe = domain.replace(".", "_").replace("/", "_")
    return Path(f".{safe}_wayback.ckpt.json")   # ← relative!
```

`scripts/run_stage.py:287-308` invokes the CDX subprocess with
`subprocess.run(cmd, cwd=str(cdx_tool_path))` where `cdx_tool_path =
REPO_ROOT / "tools"`. The relative checkpoint path therefore resolves
to `tools/.kanyewest_com_wayback.ckpt.json` — which is exactly what we
see sitting in the tree today (`.kanyewest_com_wayback.ckpt.json`,
`.shop_kanyewest_com_wayback.ckpt.json`, … five stale ckpt files from
2026-04-16). On the next run for the same domain, `--resume` loads
them, compares `(domain, total_pages, from_ts, to_ts)` against the
current window (`tools/wayback_cdx/cli.py:174-183`), and if they match,
appends to an output file **whose path may no longer exist** (because
the project dir moved when issue #1 moves).

### 2b. Mixed-Python `__pycache__`

```
./__pycache__/fetch_archive.cpython-310.pyc     ← from a 3.10 session
./__pycache__/fetch_archive.cpython-314.pyc     ← current
./__pycache__/shopify_downloader.cpython-314.pyc
./scripts/__pycache__/run_stage.cpython-314.pyc
./lib/wayback_archiver/__pycache__/            (28 entries)
```

The 3.10 bytecode is from a prior Cowork session with a different
interpreter; it's ignored by 3.14 but clutters git status. Not
correctness-breaking, just noise. Everything is stale whenever the
.py file is newer, so the Python import system handles it — this one
mostly inhibits `git clean` habits.

### 2c. Default projects root (issue 1) ≡ cache leak

Anything written to `~/wayback-archive/` during a Cowork session is
lost when the sandbox resets. On the next session, bootstrap sees no
prior project, rebuilds it from scratch, and re-hits the CDX API — so
the "inhibiting future uses" symptom is partly that wasted work piles
up instead of resuming.

### 2d. `bootstrap.py` overwrite behavior

`bootstrap.py:411-416` writes `config.yaml` and `plan.json` **by
default**, and only preserves them with `--reuse-existing`. SKILL.md
never tells Claude to pass `--reuse-existing` (search: no match in
SKILL.md). A second bootstrap call with a slightly different input
will silently clobber the project's hand-tuned config.

### Fix

Sequenced, smallest-change-first:

1. **Anchor CDX checkpoints to the project.** Change
   `run_stage.run_cdx_dump` to pass `--checkpoint-file
   <project_dir>/.cdx_ckpt/<safe_domain>.json`, creating that dir
   idempotently. Move the subprocess `cwd` off `tools/` — CDX tool
   doesn't actually need to run from there; `python3 -m wayback_cdx`
   finds the module via `sys.path`. Keep `cwd=REPO_ROOT` so all
   relative paths stay stable. This also pulls any future stray
   `.*ckpt_*.tmp` files off `tools/`.
2. **Add a `reset` subcommand** to `run_stage.py` that deletes:
   `<project>/.cdx_ckpt/`, `<project>/.checkpoint_*.json`,
   `<project>/audit.json`, optionally `<project>/html/` and
   `<project>/products/`. Doc in SKILL.md as the escape hatch.
3. **Delete the five stale `tools/.*.ckpt.json` files.** They
   reference a vanished `~/wayback-archive/` layout and can only
   mis-resume.
4. **Make bootstrap re-entrant by default.** Flip the default to
   `reuse_existing=True`, add a `--fresh` flag for the destructive
   path. Document the change in SKILL.md and README.md.
5. **Add `.gitignore`:** `__pycache__/`, `*.pyc`, `projects/`,
   `tools/.*_wayback.ckpt.json`, `tools/.env`.

### Acceptance test

- Run CDX dump for `example.com` → checkpoint lands at
  `projects/example/.cdx_ckpt/example_com.json`, not in `tools/`.
- Run `python3 scripts/run_stage.py reset --config <cfg>` → all
  state gone; next bootstrap scaffolds cleanly.
- Re-running bootstrap on an existing project preserves `config.yaml`
  edits; `--fresh` wipes them.

---

## Issue 3 — Shopify skeleton scraping gets lost

Two real bugs in `lib/wayback_archiver/surface_parser.py`, plus a
missed-surface class in `_iter_html_product_refs`.

### 3a. `_products_` substring kill is too aggressive

`surface_parser.py:62-64`:

```python
if "_products_" in lower:
    return "unknown"
```

Comment says this is meant to skip per-product atoms (`/products/<slug>.atom`),
which is fine. But the same rule discards:

- `shop.com_products_1.atom` — Shopify's paginated
  `/products.atom?page=1` endpoint. Encoded path separator is `_`, so
  `?page=1` → `_1` after the filename scheme, producing `_products_1`.
  These feeds are the **most valuable** discovery surface on any
  Shopify store after `/products.json` — each page lists ~20 products
  with slugs and CDN image URLs. We throw them away.
- `shop.com_products_<anything-with-underscores>` patterns that come
  from Wayback replay path variance.

The intent — "skip `/products/<slug>.atom` per-product feeds" — is a
path-shape check, not a substring check. Fix: require the `_products_`
pattern to be followed by a `.atom` or `.oembed` with a non-numeric
slug:

```python
# Keep paginated /products.atom (products_1, products_2, ...)
# Skip per-product /products/<slug>.atom
if re.search(r"_products_[a-z][a-z0-9-]*\.(atom|oembed)$", lower):
    return "unknown"
```

### 3b. Collection pagination misclassified as `unknown`

`surface_parser.py:71`:

```python
if re.search(r"_collections?_[^_]+$", lower):
    return "collection"
```

`[^_]+$` means **no underscores allowed** between `_collections_` and
end of string. That breaks on:

- `shop.com_collections_all_page-2`  (paginated listing)
- `shop.com_collections_men_tops`     (nested category)
- `shop.com_collections_sale_2024`    (seasonal landing)

All of these are product-listing pages Shopify routinely serves with
50–100 `<a href="/products/...">` links. Missing them is a direct
cause of "gets lost identifying additional links on product pages
that list items."

Fix: loosen to `_collections?_.+$` (anything non-empty after the
`_collections_` marker), then rely on the existing `/products/` outlink
extraction to filter false positives.

### 3c. HTML outlink extractor is lossy

`surface_parser.py:163-170` looks for `href="..."` and passes
anything containing `/products/`. Problems observed in Wayback-replay
pages:

1. **`data-href`, `data-url`, `data-product-url`**: Shopify themes
   (Dawn, Debut, Narrative, and most custom themes) lazy-link product
   tiles via data attributes, not `href`. The current regex misses all
   of them.
2. **Wayback toolbar injection**: the extractor matches *any* `href`,
   including `href="/web/20230101/..."` wrapper URLs injected by
   Wayback's own toolbar. Those parse fine downstream (the normalizer
   strips the wrapper), but they clutter logs and double-count the
   "outlinks observed" metric.
3. **Relative URLs without host**: `_normalize_product_ref` drops any
   URL where `urlparse(raw).hostname` is None — which means relative
   `/products/foo` hrefs (the common case inside a collection page)
   get thrown away. The fix: use the surface's own host
   (`surface_host`, already computed at line 276) as the base when the
   ref is host-less.

### 3d. Atom XML parser is XML-namespace-fragile

`surface_parser.py:126-149`: `ET.fromstring` on a body that Wayback
has mangled (script injection, comment prefix) raises
`ET.ParseError`, triggering the regex fallback. The regex fallback
`_ATOM_LINK_RE = re.compile(rb'<link[^>]*\bhref=["\']([^"\']+)["\']')`
matches **every** `<link>` in the document — including:

- Wayback's `<link rel="stylesheet" href="...wayback-toolbar.css">`
- Feed-level `<link rel="self" href="...atom?page=3">`
- Injected analytics beacons

Each of these ends up in `_normalize_product_ref`, which filters by
`/products/<slug>`, so mostly they're dropped. But `rel="self"` on a
paginated atom feed is `href=".../products.atom?page=3"` — that URL
contains `/products.` not `/products/`, so correctly filtered.
Workable. The real regression is that the **structured-parse path
succeeds** on bodies where the ET parser shouldn't trust the output:
Wayback wraps the atom body in HTML once in a while, and ET is lenient
enough to return garbage. Fix: strip Wayback toolbar prefix *before*
parse, and fall back to regex if the structured parse yields zero
entries (current code only falls back on ParseError).

### 3e. "Discovery is recursive" isn't actually recursive

Protocol II says surfaces emit outlinks and downstream stages
re-fetch them. That works for URLs already in the CDX dump. But when
a paginated atom feed lists a product whose `/products/<slug>` URL
was *never captured by Wayback*, the slug lands in the ledger's
`entities` table (`surface_parser.py:329-336`) but never in the
`filtered_links.txt` that `fetch` consumes. Those products end up in
the audit's `unresolved_slugs` bucket forever.

The ledger-promote path exists (`run_stage.py:225-245`
`_promote_ledger_entities`), but only `run_index`'s
`include_ledger=True` branch uses it, and the default pipeline call
doesn't pass that flag. Protocol III promises "new host → immediate
enumeration" but the Protocol II equivalent — "new slug → immediate
fetch" — isn't wired. Fix: set `include_ledger=True` in
`run_stage.run_all` whenever surface parsing has occurred.

### Fix (for issue 3, single pass)

One edit to `surface_parser.classify_filename` (3a + 3b), one to
`_iter_html_product_refs` and `_normalize_product_ref` (3c), one to
`_iter_atom_refs` (3d), and one flag flip in `run_stage.run_all`
(3e). I'll add unit tests for classify_filename — it's pure and
trivially testable, and it's the file with the highest blast radius
if regressed.

### Acceptance test

Run on a known-good Shopify corpus (yeezygap, per
`docs/POSTMORTEM_2026-04-18.md` — 0 → ~120 products recovered) and
verify:

- `audit.json.integers.unexpanded_surfaces` drops to 0 (was >0
  because paginated `_products_N.atom` surfaces weren't parsed).
- `products/` directory count rises vs. the postmortem baseline.
- No new entries in `.new_hosts.txt` for a single-host run (sanity:
  we shouldn't start hallucinating hosts).

---

## Suggested sequence

1. **Issue 1**: bootstrap default root + SKILL.md update + .gitignore.
   Small (~50 LOC), independently verifiable.
2. **Issue 2a, 2d**: checkpoint path → project dir; bootstrap default
   = reuse-existing. Also small, independently verifiable.
3. **Issue 2b, 2c, 2e (ancillary cleanup)**: delete stale ckpt files,
   add `reset` subcommand.
4. **Issue 3a-d**: surface_parser fixes with pytest coverage on
   `classify_filename`.
5. **Issue 3e**: `include_ledger=True` flag flip; verify on yeezygap
   fixtures.

Est. total: ~200 LOC changed, ~150 LOC tests added.

---

## Things I did NOT find (ruling out)

- The `ledger.db` schema and Protocol III sidecar logic (`.new_hosts.txt`)
  look fine and aren't implicated in either symptom.
- The image extractor (`lib/wayback_archiver/extract.py`) is not the
  source of the scraping problem — it consumes URLs; it doesn't
  discover them.
- `alt_archives.py` (archive.today, memento) looks well-scoped; not
  touched by this plan.
- The `import_cache.py` script is used for post-hoc orphan attribution
  (see POSTMORTEM_2026-04-18) and isn't in the default pipeline path.

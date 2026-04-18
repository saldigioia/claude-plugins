---
name: wayback-archive
description: Recover a complete product catalog (data + images) from a defunct e-commerce site via Wayback, CommonCrawl, and Shopify CDN archaeology. Use when a URL, domain, or host list points at a dead store and the full catalog should be rebuilt end-to-end.
argument-hint: "<url-or-domain> [--dry-run]"
allowed-tools:
  - Bash(python3 *)
  - Bash(cd *)
  - Bash(tail *)
  - Read
  - Write
  - Grep
  - Glob
  - WebFetch
---

# Turn-key Wayback Archive

Recover the product catalog for: **$ARGUMENTS**

## Plan (auto-generated — do not rerun bootstrap)

```!
python3 "${CLAUDE_SKILL_DIR}/../../scripts/bootstrap.py" --input "$ARGUMENTS"
```

The bootstrap script above has already:

1. Normalized the input into an apex domain and seed host list.
2. Queried Wayback CDX for `*.{apex}` to enumerate captured subdomains (sample ≤ 5000).
3. Probed the live site (and Wayback most-recent fallback) for platform signatures — Shopify, Swell, Fourthwall, Adidas.
4. Detected any `.myshopify.com` alias embedded in the HTML.
5. Rendered the matching platform template into `<projects-root>/<name>/config.yaml` and saved the plan to `<projects-root>/<name>/plan.json`.

**Where projects land.** The plan JSON has `project_dir` and `config_path` as **absolute paths** — use those verbatim when running downstream stages. Default `projects-root` is `~/wayback-archive/`; override via `$WAYBACK_ARCHIVE_ROOT` env var or `--project-root <path>` on bootstrap. Projects intentionally live outside the plugin cache so they survive plugin updates.

## Your task

Read the JSON plan above. Then do the following, in order:

### 1. Sanity check

- If `dry_run == true`, stop here — the user asked for a preview. Show them a three-line summary (`platform`, `host_count`, `config_path`) and ask what to adjust.
- If `platform == "unknown"` OR `confidence < 0.6` OR `host_count == 1`, **do not run the pipeline yet.** Surface the `notes` array to the user, ask them to either (a) confirm the generic config, (b) add missing hosts, or (c) specify the correct platform. Re-run `bootstrap.py` with the updated input if they add hosts.
- If `myshopify_domain` is non-null, confirm in your summary that it was added to the domains list.

### 2. One confirmation

Show the user a compact summary:

> Target: `<apex>` · Platform: `<platform>` (conf <confidence>) · Hosts: `<host_count>` · Config: `<config_path>`
> About to run: `cdx_dump → index → filter → fetch → cdn_discover → match → download → normalize → build`.
> Proceed? [Y/n]

Wait for confirmation. If `--dry-run` was passed in `$ARGUMENTS`, skip the prompt.

### 3. Execute the pipeline

```bash
python3 scripts/run_stage.py all --config <config_path> --auto
```

`--auto` implies `--yes`, streams compact progress events to `projects/<name>/.progress.jsonl` (one JSON line per stage start/end), and runs the audit gate at the end. The command's exit code is `0` iff the audit passes (all five integers zero) and `1` if residuals remain.

Run from the repo root. Do not flood the chat with the raw log stream. If the run is long (CDX dumps can take tens of minutes), launch it with `run_in_background: true` and poll the progress file:

```bash
tail -n 50 projects/<name>/.progress.jsonl
```

Report only stage transitions and anomalies (status != "ok", circuit-breaker trips, >30s wall time on a non-fetch stage) in one-line updates to the user — no narrative.

### 4. Read the audit (Protocol IV — gated by exit code)

`--auto` has already written `projects/<name>/audit.json` and exited with `0` (pass) or `1` (residual). Do not re-run the audit yourself unless the file is missing; if it is, run:

```bash
python3 scripts/audit.py --config <config_path>
```

Open `audit.json` and read the `integers` object. **The exit code is authoritative — never report "done" on a non-zero exit.** If residual, use `exemplars` to enumerate what's missing and either:

1. **Re-run the stage(s) that would reduce the largest bucket.** E.g., `unenumerated_hosts > 0` → re-run `cdx_dump` for the missing hosts; `retry_queue_depth > 0` → re-run `fetch` with `--proxy dc` or `--fallback-archives archive_today memento`; `index_missing > 0` → re-run `download` and check `links/<slug>.txt` for each empty exemplar.
2. **Annotate terminals.** For residuals that cannot be recovered (404 no-captures, anti-bot walls), record a `terminal_reason` and explain to the user what couldn't be recovered and why. (The ledger refactor — IMPROVEMENT_PLAN phase C3 — will persist these annotations; for now, surface them in your report.)

Repeat steps 3–4 until the audit exits zero, or every residual has a terminal_reason.

### 5. Report

Three lines, nothing more:

- Products × images recovered (`N products, M images` — read from `audit.json` `raw_counts`)
- Audit status (`pass` or `N residual items: <breakdown from integers>`)
- Path to catalog (`projects/<name>/<name>_catalog.json`)

---

## Standing protocols (inviolate — from docs/IMPROVEMENT_PLAN.md)

I.   **Entity-first.** Count products, not files. A saved feed, sitemap, or collection HTML with no downstream expansion is not progress.
II.  **Discovery is recursive.** Feeds / sitemaps / collections / JSON endpoints are *discovery surfaces*, never terminal artifacts. Every parse must emit outlinks before the surface is marked processed.
III. **New host → immediate enumeration.** Any previously unseen hostname observed in any capture triggers a CDX dump and product-URL enumeration. Do not wait for a human prompt. If you see a new host in extracted HTML, re-run `bootstrap.py` with the expanded host list or append it to the config and re-run `cdx_dump`.
IV.  **No "done" without audit.** Compute and report the five audit integers (unresolved slugs, unexpanded surfaces, index-missing entries, unenumerated hosts, retry-queue depth) before declaring completion. Any non-zero count blocks the claim unless paired with a `terminal_reason`.
V.   **Validate before counting.** Extracted strings are *candidates*, not slugs. Normalize → classify → reject non-product URLs (image assets, CDN paths) → dedupe → report *candidates seen* and *validated-and-new* separately.

## Source-hierarchy priority

Drain highest-value surfaces first: `json_api > sitemap > feed > collection > home > search > product`. `products.json?limit=1000` is the holy grail — never let HTML shells starve it.

## Fallback playbook

- **Residuals after audit.** The preferred path is the `resume` subcommand — it reads `projects/<name>/audit.json`, picks the largest non-zero bucket, and runs only the stage that would shrink it:
  ```bash
  python3 scripts/run_stage.py resume --config <cfg> --auto
  ```
  Bucket → stage mapping: `unenumerated_hosts` → `cdx_dump`, `unresolved_slugs` → `fetch`, `retry_queue_depth` → `fetch --proxy dc --fallback-archives archive_today memento`, `index_missing` → `download`. Override auto-pick with `--bucket <name>`.
- **Preflight blocked the run.** Read `projects/<name>/preflight.json`. Missing Oxylabs creds: copy `tools/.env.example` → `tools/.env` and fill in (auto-sourced, no `export` needed). Missing deps: `pip install -r requirements.txt`. Low disk: free space or change `project_dir`. Archive.org unreachable: retry or check VPN/DNS.
- **Platform misdetected.** Inspect `projects/<name>/config.yaml`, pick a different template from `skills/wayback-archive/configs/_template_*.yaml`, swap the `cdn_patterns` / `url_rules` blocks, re-run `resume` or the specific stages from `filter` onward.
- **CDX tool hangs.** Checkpoint files live at `tools/.<domain>_wayback.ckpt.json`. Resume: `cd tools && python -m wayback_cdx --domain <d> --output ../projects/<name>/<d>_wayback.txt --resume`.
- **Low fetch success (<20%).** Let `resume` pick it up via the `retry_queue_depth` bucket, or run `fetch` directly with `--proxy dc --fallback-archives archive_today memento`.
- **Anti-bot / CAPTCHA blocks.** Fall back to HAR-based recovery — see `references/playwright-wayback.md`.

## Reference docs (load only when needed — not preemptively)

- [references/manual.md](references/manual.md) — original reference manual: three-rules, triage matrix, full pipeline description.
- [references/extraction-strategy.md](references/extraction-strategy.md) — method hierarchy, CommonCrawl WARC patterns, era-based triage.
- [references/pipeline-stages.md](references/pipeline-stages.md) — per-stage inputs/outputs and verification gates.
- [references/tool-reference.md](references/tool-reference.md) — standalone script invocation.
- [references/platform-support.md](references/platform-support.md) — Shopify / Swell / Fourthwall / Adidas detection and quirks.
- [references/site-config-schema.md](references/site-config-schema.md) — YAML field reference.
- [references/data-contracts.md](references/data-contracts.md) — JSON schemas for stage inputs/outputs.
- [references/playwright-wayback.md](references/playwright-wayback.md) — HAR / Playwright last-resort extraction.
- [references/lessons-learned.md](references/lessons-learned.md) — anti-patterns and best practices.
- [../../docs/IMPROVEMENT_PLAN.md](../../docs/IMPROVEMENT_PLAN.md) — full ledger/protocols refactor plan (Movements A → B → C).

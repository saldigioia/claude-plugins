# catalog-forge

A Claude Code / Cowork plugin that operationalizes the canonical-3.1 catalog workflow: one
skill that keeps every session on-contract, a curator subagent for delegated work, a hook that
locks POS truth, and a set of commands over your **existing** `verify_all.py` and
`collection_pipeline.py`. It wraps your engines — it does not replace them, and it never makes a
judgment call.

Built from `WORKFLOW_AUTOMATION_PROPOSAL.md` (one level up). See `ADOPTION.md` for how the
pieces map to that plan and `FINDINGS.md` for what the live test run turned up.

## What's inside

```
catalog-forge/
├── .claude-plugin/
│   ├── plugin.json            # manifest (v0.2.0)
│   └── marketplace.json       # local install source
├── skills/
│   └── canonical-collections/SKILL.md   # the contract + playbook + directives, auto-loaded
├── agents/
│   └── catalog-curator.md     # the "specialization": propose-never-assert subagent for delegated work
├── hooks/
│   └── hooks.json             # PreToolUse: blocks any Write/Edit to metadata.json (POS truth lock)
├── commands/
│   ├── catalog-audit.md       # verify against the truth root (read-only)
│   ├── catalog-fetch.md       # resolve a URL to its master rendition (advisory; no download)
│   ├── catalog-review.md      # contact sheets + propose-only judgment queue
│   ├── catalog-enrich.md      # propose dates / dupes / identical files (read-only)
│   ├── catalog-sweep.md       # flag link-rot + below-master renditions (flag-only)
│   ├── catalog-finalize.md    # gate + renumber + regen canonical (writes; confirm-first)
│   ├── catalog-promote.md     # copy into the truth root (GATED, irreversible)
│   └── catalog-scaffold.md    # new product / collection skeleton
├── schema/
│   ├── config.json            # truth-root path only (the collection list lives in the truth root)
│   ├── metadata.schema.json   # sidecar schemas (POS truth is read-only; validated only)
│   ├── image_sources.schema.json
│   └── curation.schema.json
├── templates/canonical.stub.json
└── scripts/
    ├── catalog.py             # the engine: verify | scaffold | enrich | sidecars | registry | fetch | sweep
    ├── hook_guard.py          # the metadata.json lock used by hooks/hooks.json
    └── migrate_official_name.py  # one-off: collapse name_variants → official_name (two-field model)
```

## Install

catalog-forge ships as part of the **rare-data-club** marketplace. Add the marketplace once,
then install the plugin:

```
/plugin marketplace add saldigioia/claude-plugins
/plugin install catalog-forge@rare-data-club
```

(Or, for local development, point at a checkout: `/plugin marketplace add /path/to/claude-plugins`.)

Then `/catalog-audit`, `/catalog-scaffold`, etc. The `canonical-collections` skill loads
automatically whenever you work with `canonical.json` or a collection.

## Use the engine directly (no plugin needed)

```bash
PY="python3 catalog-forge/scripts/catalog.py"

# One-command verify against the truth root (auto-staging; no symlink dance)
$PY verify --root "/Users/you/Downloads/Kanye West (revised)" --collection "Kanye West" \
           --truth-root "/Volumes/PRO-G40/collections" --enforce

# Propose-only enrichment queue (writes _pipeline/_review/queue.json)
$PY enrich --root "/Users/you/Downloads/Kanye West (revised)" --what all

# Validate the POS/reseller/curation sidecars (read-only)
$PY sidecars --root "/Users/you/Downloads/Kanye West (revised)"

# Resolve a URL to its master rendition (advisory — prints the rewrite + impersonation; no download)
$PY fetch --url "https://i.ebayimg.com/images/g/abc/s-l500.jpg"

# Liveness + rendition-ceiling sweep (flag-only; --online also probes each URL). Schedulable.
$PY sweep --root "/Users/you/Downloads/Kanye West (revised)"          # offline ceiling audit
$PY sweep --truth-root "/Volumes/PRO-G40/collections" --online        # whole truth root, probe URLs

# Registry: list collections the truth root knows; plan a new registration
$PY registry list --truth-root "/Volumes/PRO-G40/collections"
$PY registry plan --name "Kanye West" --levels 2 --sub-floor-ok --empty-images-ok

# Scaffold
$PY scaffold collection --root /path/to/new-workdir --name "New Collection"
$PY scaffold product --root /path/to/workdir --name "Logo T-Shirt (Black) [Women]" --era "Some Era (2020)"

# One-off name-model migration (dry-run; --apply after adding official_name to the truth schema)
python3 catalog-forge/scripts/migrate_official_name.py --root "/Users/you/Downloads/Kanye West (revised)"
```

Requires Python 3.10+ with `Pillow`, `imagehash`, `jsonschema` (same as the truth root).

## The safety model (non-negotiable)

| Class | Examples | Behavior |
|---|---|---|
| Read-only | verify, sidecar validation, registry list, **fetch** (advisory), **sweep** (flag-only) | inspect & report; touch no product file |
| Mechanical | scaffold, renumber, hash/dim re-measure | auto-apply; reversible; back up first when writing |
| Judgment | belonging, same-product/merge, name/colour, date, low-confidence inclusion | **propose only** — written to `_pipeline/_review/queue.json`, applied only on a curator verdict |
| Irreversible | promote (copies into the truth root) | gated behind a green verify + explicit confirmation; backs up affected truth paths |

`metadata.json` is never written — and now the **PreToolUse hook enforces that structurally**:
any Write/Edit to a `metadata.json` is blocked by the harness, not just discouraged by the
skill. The truth-root verifier is the only definition of done; if a local check and the truth
verifier disagree, the truth verifier wins.

---
name: canonical-collections
description: The contract and procedure for the canonical-3.1 product-catalog archive (Kanye West / Yeezy / Adidas / APC / Nike / Louis Vuitton, etc. under a truth root like /Volumes/PRO-G40/collections). Use whenever working with canonical.json records, the 4-layer product folder (metadata/image_sources/curation/canonical), the 4-axis verifier, image sourcing/citation standards, collection finalization or promotion, or bringing a new/quirky collection up to standard. Loads the schema rules, the playbook phases, the curator's propose-don't-assert directives, and the CDN master-rendition recipes so every session stays on-blueprint.
---

# Canonical Collections — the contract and the procedure

This skill makes any session behave like the curator's archive expects, without re-reading
onboarding docs. Read it before touching a product record.

## The prime directive: propose, never assert

Identity, naming, colour, same-product/merge, pruning, and whether a low-confidence product
belongs are **the curator's decisions**. Tools may *propose with evidence*; only the curator
confirms. Mechanical, reversible operations (hashing, schema checks, reconciliation,
renumbering, backups) auto-apply. When in doubt, propose — don't assert.

Corollaries that have been violated before, so hold them firmly:
- **`metadata.json` is read-only POS truth.** Never edit it or merge reseller data into it.
  The canonical is built *from* it.
- **Never automate or bulk-apply tags/classifications/matches.** Rules are curator-approved
  *before* bulk application, never after.
- **Placement means physical folder moves**, not just a metadata edit.
- **No silent caps.** Anything dropped, skipped, or unreachable is logged
  (`image_sources.unavailable_sources[]`), never quietly discarded.
- **Product titles never repeat the collection name** ("Kanye West"); album/era names that
  are the design subject are fine ("Late Registration T-Shirt").

## The one contract: the truth-root verifier

A collection is "done" iff it passes the truth root's 4-axis `make verify`
(`tools/verify/verify_all.py` + `schema/canonical-3.1.schema.json`). That verifier — not any
local check — is the single source of acceptance. Always verify against it
(`catalog verify`, which auto-builds the staging tree). If a work-dir tool and the truth
verifier ever disagree, **the truth verifier wins.**

The 4 hard-fail axes:
1. **Citation** — every image has ≥1 of `download_url` / `page_url_archive` /
   `source_retailer` / an `_`-prefixed provenance field; top-level `citations{}` has ≥1
   populated key.
2. **Metadata** — schema-valid; required fields present; `collection` byte-equals its parent
   collection dir (grandparent for era/season collections); `slug` unique within collection.
3. **Placement** — `folder_name` byte-equals the directory; folder grammar matches the
   collection's rubric; no orphan product dirs (each must hold a `canonical.json`).
4. **Image consistency** — disk SHA-256 matches `canonical.images[].sha256`; width/height
   match; long edge ≥600 px; on-disk image count equals `len(images)`.

Sub-floor (<600 px) and empty-image exemptions exist **only** for `G.O.O.D. Music` and
`Kanye West`, and only when flagged (`sub_floor:true` / `cache_resized`).

## The 4-layer product record

```
<Collection>/<Era|Season?>/<Product>/
  metadata.json        POS truth      — read-only (FTK/FanFire SKU, price, sizes, recovered originals)
  image_sources.json   reseller layer — sources[]/source, images[], citation[], subject_note, unavailable_sources[]
  curation.json        curator log    — era, resolution, same_product_as, needs_images
  canonical.json       built record   — assembled FROM the above; the ONLY thing the verifier judges
```

On finalize/promote, POS truth folds into `canonical.upstream_metadata` (as the gold-standard
collections already do). `canonical.json` required fields: `schema_version` ("canonical-3.1"),
`slug` (kebab, collection-unique), `folder_name` (byte-equals dir), `name` (Title-Case, no
colour/SKU, never the collection name), `color`/`color_token` (null together), `collection`,
`date` (ISO or null), `sources[]`, `images[]`, `citations{}` (≥1 populated key), `provenance`
(`generated_at`, `generator`). `era`/`season` byte-equals the parent for those collections.
The schema is `additionalProperties:false` plus `^_`-prefixed audit fields. **A non-`_` field
not in the schema's `properties` will fail the metadata axis** — add it to the schema or
prefix it `_`.

**Names are exactly two fields.** `name` = the curator's display title (the folder core).
`official_name` = the POS retailer's title, present **only** when an official source is on
record; absent for reseller-only/quirky products. Superseded or prior names are history — they
live in `provenance`, never in a `name_variants` array (that array conflated the official title
with history and is retired; see `scripts/migrate_official_name.py`).

Folder grammar: `Name (Colour) [Tag][Tag]…`. Audience/gender/city/edition are **tags**
(`[Women]`, `[LA]`, `[Truth Tour 2004]`), never in the name, never in parentheses. Dialect
normalize: `Tee→T-Shirt`, `Hoody→Hoodie`, `LS→Long-Sleeve`.

## Quirky / low-confidence collections (Nike, Louis Vuitton model)

The schema is deliberately inclusive so manually-confirmed products survive without a retail
URL. A product is includable when it has a name, an era, and **either** ≥1 image with a
provenance field (a reseller `download_url` or `source_retailer` is enough — that's how Nike
/ LV pass) **or** a `subject_note` explaining why no image exists. Record a curator-blessed
no-URL product explicitly (e.g. an `_manual_confirmed` audit field) so it reads as a decision,
not a gap. Below that floor, route it to the review queue as `needs-more` — never silently in
or out.

## The procedure (phases — see the Playbook for the full step list)

0 snapshot → 1 schema & image integrity → 2 image acquisition (master rendition) →
3 source tracing → 4 visual identity & belonging *(judgment)* → 5 redundancy pruning
*(judgment)* → 6 de-duplication & merges *(judgment, never auto)* → 7 standardization &
naming *(judgment→mechanical)* → 8 sidecar completion → 9 finalize (gate + renumber + regen
canonical). Reusable Operations A–F (add substitutes / remove images / merge / replace set /
seed proposed product / format-fix) each preserve POS truth, back up first, renumber
contiguously, and re-measure from disk.

## Image acquisition: always the master rendition

Isolate the listing's own gallery (reject cross-sell), then SHA-256-dedupe before adding.
Per-CDN master recipe:

| Host | Master | Impersonation |
|---|---|---|
| `i.ebayimg.com` | `…/s-l1600.jpg` (1600 cap); isolate via VIImageType "Picture N of M" | `safari17_0` |
| `i.etsystatic.com` | `il_fullxfull.<id>` | `safari17_0` (DataDome) |
| `media-assets.grailed.com` | bare object; URL from `__NEXT_DATA__ photos[].url` | `safari17_0` |
| `u-mercari-images.mercdn.net` | bare `…/<item>_<N>.jpg` | `safari17_0` |
| `media-photos.depop.com` | `…/P0.jpg` (P0=1280 master; P1+ smaller) | `chrome120` |
| `cdn.shopify.com` | `<product>.json` → `images[].src`; `?format=png` for lossless | `safari17_0` |
| `*.cdninstagram.com` | `/p/<code>/embed/captioned/ display_url` (1080; not og:image) | `chrome120` |
| `gem.app` | JS-WAF → headless; gallery often eBay-hosted (use the eBay item) | Playwright |

`/catalog-fetch <url>` resolves the master rewrite from this table for you (advisory; it
never downloads). Long network jobs run in the curator's own terminal as resumable scripts.
Unreachable but known sources → `image_sources.unavailable_sources[]`, never dropped.

## The commands (this plugin)

- `/catalog-audit` — verify against the truth root (one command; no symlink dance).
- `/catalog-fetch` — resolve a URL to its master rendition (advisory; never downloads).
- `/catalog-review` — build the review UI + the propose-only judgment queue.
- `/catalog-enrich` — propose dates / same-product / identical-file candidates (curator confirms).
- `/catalog-sweep` — flag link-rot + below-master renditions (flag-only; schedulable).
- `/catalog-finalize` — gate + contiguous renumber + regen canonical from disk.
- `/catalog-promote` — **gated, irreversible**: stage → verify → copy into the truth root → register → make all.
- `/catalog-scaffold` — new product or collection skeleton + a playbook checklist.

Engine: `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/catalog.py" <verify|scaffold|enrich|sidecars|registry|fetch|sweep>`.
It wraps the existing `verify_all.py` and `collection_pipeline.py`; it never re-implements
the verifier and never makes a judgment call.

**Two structural guardrails ship with the plugin:**
- A **PreToolUse hook** (`hooks/hooks.json`) blocks any Write/Edit to a `metadata.json` — the
  prime directive is enforced by the harness, not just by this text. Don't work around it.
- A **`catalog-curator` subagent** (`agents/`) embodies this contract for delegated work; hand
  it audits, queue prep, scaffolds, or source tracing and it stays propose-only.

# Wayback-Archive — High-Output Improvement Plan

**Purpose.** Convert the critique of prior agent behavior (reactive, file-centric, premature-done) into a disciplined, resumable, prompt-driven improvement process. The plan is organized as three movements (Analyze → Brainstorm → Edit) containing fifteen phases, bound by five standing protocols and a single durable ledger. Each phase specifies inputs, the operation, a deliverable, a hard gate, and a runnable prompt template the agent can execute literally.

**Non-goal.** This document is not a narrative. It is a machine-executable workflow spec. Every phase is resumable; every deliverable is versioned; every gate is falsifiable.

---

## 0. Critique → Phase Coverage Matrix

Before any work begins, verify that every critique item has at least one owning phase. Nothing may exit this plan unowned.

| Critique Item                              | Primary Owner | Reinforcing Phases |
|--------------------------------------------|---------------|--------------------|
| 1. No second-pass expansion of feeds       | A3, B1        | C1                 |
| 2. File-centric, not entity-centric        | A2, B3        | C3                 |
| 3. Weak subdomain branching                | A4, B1        | C1                 |
| 4. No generalized collection/home rule     | B1            | C1                 |
| 5. No completeness checks                  | A5, B3        | C4                 |
| 6. Premature "done"                        | B3            | C4, Protocol IV    |
| 7. Brittle extraction heuristics           | B1            | C2                 |
| 8. Ad hoc intervention pattern             | B5            | C3, C5             |
| 9. Fragile operational behavior            | B4            | C3                 |
| 10. Weak source-hierarchy prioritization   | B2            | C1                 |

If any future deliverable references work not tied to a row above, either add a row or drop the work.

---

## I. Standing Protocols (apply during every phase)

These are invariants. Violating one of them invalidates whatever phase is running.

- **Protocol I — Entity-first.** Every captured URL is a means, never an end. The unit of accounting is the *product entity*, not the *file*. A saved `.atom` with no downstream expansion is not progress.
- **Protocol II — Discovery is recursive.** Feeds, sitemaps, collection pages, homepages, search result pages, and JSON endpoints are *discovery surfaces*, not artifacts. Every parse must emit outlinks into the ledger before the surface is marked processed.
- **Protocol III — New host → immediate enumeration.** Any previously unseen hostname observed in any capture triggers a CDX dump of that host and an enumeration of its product URL patterns, queued automatically. The user does not need to notice.
- **Protocol IV — No "done" without audit.** Before reporting completion, answer the five questions (§ A5) numerically. Any non-zero unresolved count blocks the "done" claim.
- **Protocol V — Validate before counting.** Extracted strings are candidates, not slugs. Normalize → classify → reject → dedupe → report *candidates seen* and *validated-and-new* separately.

---

## II. The Ledger (single source of truth for the pipeline)

All movements read from and write to one ledger. Without this, the pipeline cannot be resumable, auditable, or self-propelling.

**Schema (SQLite, alongside the existing archive DB):**

```sql
CREATE TABLE discovery_surfaces (
  url            TEXT PRIMARY KEY,
  host           TEXT NOT NULL,
  surface_class  TEXT NOT NULL,       -- feed | sitemap | collection | home | search | json_api | product | image | unknown
  fetched_at     TEXT,
  parsed_at      TEXT,                -- NULL = unexpanded
  parse_status   TEXT,                -- ok | partial | failed
  outlink_count  INTEGER DEFAULT 0
);

CREATE TABLE entities (
  slug           TEXT NOT NULL,
  host           TEXT NOT NULL,
  canonical_url  TEXT,
  resolved_at    TEXT,                -- NULL = referenced but unresolved
  first_seen_in  TEXT REFERENCES discovery_surfaces(url),
  PRIMARY KEY (slug, host)
);

CREATE TABLE hosts (
  host               TEXT PRIMARY KEY,
  cdx_dumped_at      TEXT,            -- NULL = not enumerated
  product_pattern    TEXT,            -- regex, nullable
  coverage_estimate  REAL              -- 0..1
);

CREATE TABLE fetch_attempts (
  url             TEXT NOT NULL,
  attempted_at    TEXT NOT NULL,
  status          INTEGER,
  failure_class   TEXT,               -- throttle | network | 404 | 5xx | parse | ok
  retry_after     TEXT,
  PRIMARY KEY (url, attempted_at)
);
```

**Invariant.** At any instant, *pending work* = rows where `discovery_surfaces.parsed_at IS NULL` ∪ `entities.resolved_at IS NULL` ∪ `hosts.cdx_dumped_at IS NULL` ∪ `fetch_attempts` with retriable `failure_class`. Completion audit = all four sets empty.

---

## III. Movement A — Analysis (diagnose current state)

Goal: produce a true, numeric picture of where the archive actually stands, unclouded by prior "progress reported." Output feeds Movement B.

### Phase A1 — Inventory Census
- **Inputs.** `wayback-archive/tools/*/` and `products/` trees; existing DB.
- **Operation.** Walk all capture trees. For each file, record: path, size, host-of-origin, MIME/extension, last-modified, SHA256.
- **Deliverable.** `inventory.jsonl` (one row per artifact) + summary counts by host × extension.
- **Gate.** Row count == `find … -type f | wc -l`. Any mismatch halts.
- **Prompt template.**
  > Walk the capture tree under `wayback-archive/tools`. Produce `inventory.jsonl` with fields `{path, host, ext, bytes, mtime, sha256}` for every regular file. Emit a second file `inventory.summary.json` with `count_by_host`, `count_by_ext`, and `count_by_host_ext`. Verify row count equals a plain filesystem count; report both. Do not interpret content yet.

### Phase A2 — Classification Pass
- **Inputs.** `inventory.jsonl`.
- **Operation.** Classify each artifact into `{feed, sitemap, collection, home, search, json_api, product, image, static, unknown}` using filename + first 4 KiB content sniff.
- **Deliverable.** `classified.jsonl`; histogram `{class: count}`; list of `unknown` for human review.
- **Gate.** `unknown` rate ≤ 5 % of inventory. If above, classifier is too weak — iterate before moving on.
- **Prompt template.**
  > For each row in `inventory.jsonl`, classify into one of `{feed, sitemap, collection, home, search, json_api, product, image, static, unknown}`. Use filename heuristics first, then content sniff of the first 4 KiB (don't read full files). Write `classified.jsonl`. If `unknown` exceeds 5 % of total, output the top 20 unknown filename patterns and stop — do not proceed.

### Phase A3 — Reference Graph Build
- **Inputs.** `classified.jsonl` restricted to discovery surfaces (`feed | sitemap | collection | home | search | json_api`).
- **Operation.** Parse each surface; extract all outlinks that look like product URLs or image assets; write to `entities` and `discovery_surfaces` tables; mark parsed surfaces with timestamp.
- **Deliverable.** Populated ledger; `reference_graph.jsonl` pairs `(surface_url, referenced_slug_or_asset)`.
- **Gate.** Every `discovery_surface` row has either `parsed_at IS NOT NULL` or a logged `parse_status='failed'` with reason. No silent skips.
- **Prompt template.**
  > For every row in `classified.jsonl` with `class IN ('feed','sitemap','collection','home','search','json_api')`, parse it and emit all outbound product slugs and image URLs into the ledger tables. Upsert `entities` rows (may already exist, leave `resolved_at` untouched). Stamp `discovery_surfaces.parsed_at`. On parse failure, stamp `parse_status='failed'` with a reason — never silently skip. Do NOT fetch anything in this phase.

### Phase A4 — Host Ledger
- **Inputs.** All URLs seen so far across inventory and outlinks.
- **Operation.** Build set of distinct hosts; for each, record whether a CDX dump exists locally; compute `coverage_estimate` = resolved-products / referenced-slugs.
- **Deliverable.** Populated `hosts` table; `hosts.report.md` listing each host with its status.
- **Gate.** Every host ever seen appears in the table. No host may be missing, even if it was hit only once.
- **Prompt template.**
  > Enumerate every distinct hostname observed in the inventory or the reference graph. Upsert into `hosts` with `cdx_dumped_at` set iff a CDX dump file for that host exists on disk. Compute `coverage_estimate = resolved / referenced` per host. Emit `hosts.report.md` sorted by coverage ascending — worst-covered first.

### Phase A5 — Completeness Audit (the Five Questions)
- **Inputs.** Fully populated ledger.
- **Operation.** Compute, exactly:
  1. `unresolved_slugs = count(entities WHERE resolved_at IS NULL)`
  2. `unexpanded_surfaces = count(discovery_surfaces WHERE parsed_at IS NULL)`
  3. `index_missing = count(entities WHERE resolved_at IS NOT NULL AND slug NOT IN archive_db)`
  4. `unenumerated_hosts = count(hosts WHERE cdx_dumped_at IS NULL)`
  5. `retry_queue_depth = count(fetch_attempts with retriable failure_class and no successor ok)`
- **Deliverable.** `audit.json` with the five integers and a list of exemplar rows for each.
- **Gate.** This deliverable is the baseline. Every later phase must reduce at least one of these numbers without increasing another (except transiently).
- **Prompt template.**
  > Compute the five audit integers against the ledger and write `audit.json`. Attach up to 20 exemplar rows per category. Do not interpret; just report.

---

## IV. Movement B — Brainstorm (generate options, lock decisions)

Goal: convert the observed deficits into a written, versioned set of rules the Edit movement will encode. Brainstorm is where ambiguity is resolved, not deferred.

### Phase B1 — Recursion Rules per Surface Class
- **Operation.** For each class in `{feed, sitemap, collection, home, search, json_api}`, author a rule specifying: what selector extracts outlinks, what filters apply, what follow-up class each outlink gets enqueued as.
- **Deliverable.** `rules/recursion.yml` — one stanza per class.
- **Decision points to resolve explicitly.**
  - Should `home` pages follow outbound links to *other hosts*? (Default: yes, to known-kin hosts; log unknown hosts but don't chase on this pass.)
  - Are `<link rel="next">` pagination links in-scope? (Default: yes.)
  - What's the depth limit before a surface is considered saturated? (Default: follow pagination to exhaustion; follow content links exactly one hop.)

### Phase B2 — Source Hierarchy Weights
- **Operation.** Define priority so the queue worker always drains the highest-value source first.
- **Deliverable.** `rules/priority.yml`:
  ```yaml
  weights:
    json_api: 100    # products.json?limit=1000, etc.
    sitemap:  80
    feed:     60
    collection: 40
    home:     30
    search:   20
    product:  10     # direct shells — last resort, already low info density
  ```
- **Rationale line.** For each tier, one sentence on why that tier exists and what it typically yields. Without rationale the weights drift.

### Phase B3 — Completion Criteria
- **Operation.** Define "done" at three scopes: per entity, per host, per pass.
  - *Entity done* = `resolved_at IS NOT NULL` AND (image assets present OR image class recorded as unavailable).
  - *Host done* = `unenumerated=0` AND `unexpanded_surfaces=0` AND `unresolved_entities=0` for that host.
  - *Pass done* = `audit.json` has all five integers at zero OR each remaining entry has a logged `terminal_reason` (404-no-captures, unreachable-after-retry-limit).
- **Deliverable.** `rules/done.yml`.

### Phase B4 — Failure Taxonomy & Retry Policy
- **Operation.** Enumerate failure classes; for each, specify retry policy.
  ```yaml
  throttle:    backoff=exp, base=60s, cap=30m, max_attempts=10
  network:     backoff=exp, base=5s,  cap=5m,  max_attempts=6
  http_5xx:    backoff=exp, base=30s, cap=15m, max_attempts=8
  http_404:    terminal, no retry; record as no-capture
  parse:       requeue once after 1h; terminal on second failure
  ok:          no retry
  ```
- **Deliverable.** `rules/retry.yml`. Failure classes in code must match this file exactly.

### Phase B5 — Durable State Model
- **Operation.** Review the ledger schema (§ II) and the `rules/*.yml` files; confirm the ledger can represent every state these rules produce. Specifically: can we resume mid-pass, after a crash, with no ambiguity?
- **Deliverable.** `rules/state-invariants.md` listing the invariants that must hold at every checkpoint.
- **Gate.** Dry-run a simulated crash after each phase and confirm the ledger alone tells the next process what to do.

---

## V. Movement C — Editing (make the changes)

Goal: encode Movements A and B into the repo so the protocols are executed automatically by code, not remembered by the agent.

### Phase C1 — Pipeline Refactor
- **Target files.** `wayback-archive/scripts/run_stage.py`, `wayback-archive/lib/`, possibly new `wayback-archive/scripts/recurse_discovery.py`.
- **Operation.**
  - Replace any file-centric loops with a *queue worker* driven by the ledger.
  - Every surface parser emits outlinks and upserts ledger rows; no parser is allowed to return only "done."
  - New-host detection hooks into Protocol III and enqueues CDX-dump tasks.
  - Priority queue honors `rules/priority.yml`.
- **Deliverable.** Working `run_stage.py` that, given only the ledger, runs to completion.
- **Tests.** Replay a known capture set, assert audit numbers drop monotonically.

### Phase C2 — Validation Classifier
- **Target.** New `wayback-archive/lib/classify.py`.
- **Operation.** Implement normalize → classify → reject logic (Protocol V). Unit tests for the concrete false-positive that bit us: image filenames mis-matched as product slugs.
- **Deliverable.** Passing test suite covering at least: `/products/<slug>` ✓, `/cdn/shop/files/foo.jpg` ✗, `/collections/<slug>` → classified as `collection`, `/products.json` → `json_api`, `sitemap.xml` → `sitemap`.

### Phase C3 — Unresolved-Work Ledger + CLI
- **Target.** New `wayback-archive/scripts/ledger.py` providing `init`, `upsert-surface`, `upsert-entity`, `mark-parsed`, `enqueue-retry`, `audit`.
- **Operation.** All other scripts write through this module; no ad-hoc SQL elsewhere.
- **Deliverable.** `python -m scripts.ledger audit` prints the A5 report in ≤1 s on the current archive.

### Phase C4 — Completion-Audit Command
- **Target.** `wayback-archive/scripts/status_report.py` — extend, don't replace.
- **Operation.** Add subcommand `audit` that emits the Protocol IV five-question report and exits non-zero if any integer is > 0 without a documented `terminal_reason`. Wire this into any future "is the pass done?" check.
- **Deliverable.** CI-grade exit code so "done" can never again be declared by agent narration alone.

### Phase C5 — Skill Update
- **Target.** `wayback-archive/skills/wayback-archive/` (the plugin-shipped skill).
- **Operation.** Bake the five standing protocols and the audit-before-done contract into the skill's instructions. The skill should refuse to report completion unless `status_report.py audit` exits zero.
- **Deliverable.** Updated skill file; protocols quoted verbatim at the top.

---

## VI. Execution Discipline

- **Sequence.** A1 → A2 → A3 → A4 → A5 must complete before any B phase. B1 → B5 must complete before any C phase. Within C, C3 (ledger CLI) is a prerequisite for C1 and C4.
- **Resumability.** Each phase writes its deliverable to disk and updates the ledger. Restarting mid-phase reads prior deliverables and continues — never redoes.
- **Kill-switch on scope creep.** If a phase's deliverable diverges from its spec, halt and update the spec before continuing. Do not patch silently.
- **Reporting.** End-of-phase report is two lines: (a) what the audit numbers were before vs after, (b) whether the gate passed. Nothing more. No narrative progress updates.

---

## VII. Prompt Template — Phase Entry

Use this exact framing when entering any phase in a future session. It enforces the protocols at the entry boundary.

> **Entering Phase `<ID>`** of the Wayback-Archive Improvement Plan.
>
> 1. Read `wayback-archive/docs/IMPROVEMENT_PLAN.md` § for this phase.
> 2. Read the current ledger: `python -m scripts.ledger audit` (if C3 has landed) or compute the five audit integers directly from disk.
> 3. Execute only the operation defined by this phase. Do not touch other phases.
> 4. Write the phase's deliverable to the path the plan specifies.
> 5. Re-run the audit. Report *before* and *after* integers as a two-line summary.
> 6. If the gate fails, stop and report; do not proceed to the next phase.

---

## VIII. Definition of Done (for this Plan)

The plan is complete when, and only when:

- All five `audit.json` integers are zero, OR each residual is annotated with a `terminal_reason`.
- `python -m scripts.ledger audit` exits zero on CI.
- The skill refuses to declare completion without that exit code.
- The repo contains `rules/recursion.yml`, `rules/priority.yml`, `rules/done.yml`, `rules/retry.yml`, `rules/state-invariants.md`.
- A fresh agent, given this document and the ledger, can resume work without re-prompting from the user.

The last bullet is the real test: this plan succeeds when the archive no longer depends on ad-hoc intervention.

# Integration analysis — `internet-archive-skills`

**Analyzed.** `/Users/salvatore/Downloads/internet-archive-skills` (upstream: `github.com/internetarchive/internet-archive-skills`, AGPL-3.0, v1.1.0).

**Scope of the analyzed repo.** A single-skill Claude Code plugin wrapping the `ia` CLI from the `internetarchive` PyPI package. No custom Python, no agents, no CDX/WARC code — purely a playbook for archive.org's item-upload/search/download surface.

**Files inventoried (direct reads from main thread — subagents hit sandbox walls):**

- `.claude-plugin/plugin.json` (12 lines, v1.1.0)
- `.claude-plugin/marketplace.json`
- `skills/ia/SKILL.md` (866 lines — the entire plugin body)
- `examples/usage-examples.md` (332 lines)
- `README.md` (200 lines)

## What the skill teaches Claude to do

1. **Install + auth** — `uv tool install internetarchive`, `ia configure`, IA-S3 keys, `~/.config/ia.ini` or `IA_ACCESS_KEY_ID` / `IA_SECRET_ACCESS_KEY` env.
2. **Search** — Lucene syntax against archive.org's catalog: field queries, ranges, fuzzy, full-text via `-F`, `--itemlist`.
3. **Download** — `ia download <id>` with `--glob`, `--exclude`, `--source=original|derivative|metadata`, `--on-the-fly`, `--dry-run`, `--checksum` for resumable large transfers.
4. **Upload** — `ia upload` with mediatype + metadata; spreadsheet bulk; `test_collection` validation before permanent commit.
5. **Metadata API** — `ia metadata <id> --modify` / `--append-list` / `--remove`; file-level via `--target`.
6. **Bulk ops** — GNU Parallel with `--joblog` + `--retry-failed` for resumable batches; `-j N` for concurrency; `--delay` for rate-limiting.
7. **User-Agent requirement** — all archive.org requests from AI agents **must** include a custom `--user-agent-suffix` identifying tool + version + model. This is a *policy* requirement, not a convention.

## What it does NOT contain

No CDX Server code. No Wayback Machine / `web.archive.org/web/...id_/` handling. No WARC/WACZ parsing. No CommonCrawl. No defunct-site reconstruction. No platform detection. No ledger or queue workers. It is an archive.org **item-API** client — a different surface from the Wayback Machine **crawl** surfaces this plugin uses.

## Integration vectors (ranked)

### Vector 1 — User-Agent compliance (HIGH value / trivial effort) — **Phase 2.5**

The skill's loudest warning: AI agents must identify themselves in every archive.org request. `wayback-archive` hits four archive.org-adjacent endpoints:

| Endpoint | Caller |
|---|---|
| `web.archive.org/cdx/search/cdx` | `lib/wayback_archiver/cdx.py`, `scripts/bootstrap.py`, `tools/wayback_cdx/transport.py` |
| `web.archive.org/web/...id_/` | `fetch_archive.py`, `lib/wayback_archiver/download.py` |
| `data.commoncrawl.org` | `fetch_archive.py` |
| `archive.today` / Memento (`timetravel.mementoweb.org`) | `lib/wayback_archiver/alt_archives.py` |

Only `bootstrap.py` currently sends a self-identifying UA (`wayback-archive-bootstrap/1.0`). The other callers rely on `requests` / `aiohttp` defaults. That's effectively anonymous — invisible to archive.org's quota accounting, and first in line to be blocked if policy tightens.

**Action.** Create `lib/wayback_archiver/http_client.py` with a single source-of-truth UA constant:

```python
USER_AGENT = (
    "wayback-archive/{version} "
    "(Claude Code AI agent; +https://github.com/saldigioia/wayback-archive-plugin)"
).format(version=__version__)
```

…and helper factories (`make_requests_session()`, `make_aiohttp_session()`) that all HTTP call sites must use. Also honor `Retry-After` on 429 responses where not already.

**Effort:** ~half a day. Purely additive.

### Vector 2 — `ia` as a complementary discovery source (MEDIUM / medium) — **Phase 4.5**

archive.org hosts user-uploaded items (scanned lookbooks, marketing PDFs, product photography) that may contain data the Wayback Machine never captured. For defunct-brand recovery these can be uniquely valuable — fan-preserved catalog scans, pre-release lookbooks, etc.

**Action (Phase 4.5, blocked on the ledger).** New stage `ia_discover` between `cdn_discover` and `match`, guarded by `ia_search.enabled: true`. Uses `from internetarchive import search_items` (Python lib, not subprocess — keeps dependency stack clean). Per-target query patterns in the site config. Items surfaced become `surface_class='ia_item'` rows in the Phase-3 `discovery_surfaces` ledger table — natural extension, not a bolt-on.

**Risk.** Archive.org item search is noisy for brand-name queries (fan remixes, parody uploads). Needs tight filter rules (`collection:opensource_image AND creator:...`) per target. Opt-in, off by default.

### Vector 3 — `parallel --joblog` / `--retry-failed` idiom — SKIP

The skill pitches GNU Parallel with job-logging as the bulk-op resumability pattern. We already have per-stage checkpoint JSON + the planned ledger, both strictly richer. No integration value. Worth noting only as design confirmation: even archive.org's own skill codifies "bulk ops need a resume log."

### Vector 4 — Preservation loop: publish recovered catalogs back to archive.org (META / heavy) — **Phase 5 (discussion-only)**

Logical closure: defunct-store → local reconstruction → public preservation. A completed catalog is vulnerable to the same disappearance the original store suffered unless it lands somewhere durable. `ia upload <identifier> ... --metadata="mediatype:data" --metadata="collection:..."` does exactly this.

**Why it aligns with existing protocols.** The archival-crawl protocol and completion-discipline protocol both implicitly assume recovered data persists. Local-only persistence is at odds with that assumption.

**Why Phase 5.** Requires:
- Auth setup (`IA_ACCESS_KEY_ID` or `IA_SECRET_ACCESS_KEY`) as a plugin-level concern, not per-target.
- Identifier convention — `wayback-archive-<name>-<YYYYMMDD>`?
- Metadata schema — `mediatype:data` or `mediatype:web`? collection selection?
- Rights review — some product photography is copyrighted, cannot be uploaded unilaterally.
- A `publish? [Y/n]` gate in the skill after audit passes.

Not a quick win. Recorded here so the idea is durable.

## Phase placement in the revised plan

| Phase | Status | Source |
|-------|--------|--------|
| 0. Skill surgery | shipped (658b847) | original plan |
| 1. bootstrap.py + templates | shipped (658b847) | original plan |
| 2. `--auto` + audit gate | shipped (42cba3a) | original plan |
| **2.5. Archive citizenship audit** | pending | **this analysis (Vector 1)** |
| 3. Ledger backbone | pending | IMPROVEMENT_PLAN.md C1 + C3 |
| 4. Polish | pending | original plan |
| **4.5. `ia` discovery layer** | pending | **this analysis (Vector 2)** |
| **5. Preservation loop** | future | **this analysis (Vector 4)** |

## Subagent note

Two `Explore` subagents were launched in parallel per the "strict context limitations" constraint but both hit sandbox permission walls when reading files outside the current worktree (`/Users/salvatore/Downloads/wayback-archive`). Main-thread direct reads were used instead, which is fine given the target dir's small size (6 files). If future cross-worktree analyses are needed, either (a) grant the subagent `--add-dir` access, (b) copy the target into a subdirectory first, or (c) skip subagent delegation when the target is small.

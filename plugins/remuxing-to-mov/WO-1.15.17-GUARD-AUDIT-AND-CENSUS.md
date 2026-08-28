# WO-1.15.17 — guard audit, class enumeration, and the census_rc contract

Self-contained work order. Assume no prior conversation context.

## Environment

- Plugin repo: `/Users/salvatore/Downloads/claude-plugins`, plugin at
  `plugins/remuxing-to-mov`, currently **version 1.15.16**. The user is the
  author (`saldigioia/claude-plugins`).
- **The installed copy Claude Code actually runs is
  `~/.claude/plugins/marketplaces/rare-data-club/plugins/remuxing-to-mov`.**
  After editing the repo you MUST copy changed files across, or any field run
  uses stale code. Verify with
  `diff -rq --exclude=__pycache__ --exclude=fixtures REPO CACHE`.
- Bench: from `plugins/remuxing-to-mov/skills/remuxing-to-mov`, run
  `bash tests/regression.sh`. Currently **292 passed, 0 failed**. It takes
  ~20-25 min — run it in the BACKGROUND, and do not run it concurrently with
  any large media job (see item 2's history).
- Validate: `claude plugin validate ./plugins/remuxing-to-mov --strict` and
  `claude plugin validate . --strict` (marketplace) from the repo root.
- Bench machine: macOS, ffmpeg/ffprobe 9.0.1.

## House method (follow it; it is not optional here)

Write the test FIRST. Verify it RED against the current tree, and paste the
red counts. Then make the change, verify GREEN, run the neighbouring
sub-suites, then the full suite. Add a CHANGELOG.md entry in the existing
voice (state what was measured, not what was intended), bump the version in
`.claude-plugin/plugin.json`, validate both manifests, sync to the installed
copy.

**Re-measure every factual claim in this document before acting on it.** It
was written from a prior session and is secondhand. If a claim here does not
reproduce, that discrepancy is itself a finding — record it rather than
quietly working around it.

## Background: the failure mode this work order exists to close

Versions 1.15.10-1.15.12 each fixed a real defect, and all three were the same
shape — a fact written in two places and corrected in one. 1.15.13 and
1.15.14 addressed two instances structurally ("ask the authority, do not model
it"; "one writer per fact"). 1.15.15 added `tests/regression.d/94-rot-sweep.sh`,
a tree-wide sweep that enumerates known defect classes mechanically every run.

While writing that sweep, **two of its five guards were vacuous on first
draft** and only surfaced under mutation testing:
- a pattern that also matched the COMMENT describing the idiom, so prose
  satisfied the guard;
- `grep -l` counting FILES, so a second definition inside one file was invisible.

Both would have shipped green while guarding nothing. That is the specific
risk this work order targets.

---

## Item 1 — mutation-test EVERY existing tree-wide guard

A guard nobody has seen fail is a guard nobody knows works. Test 94's guards
were mutation-verified when written; the older ones never were.

**Scope** — every assertion that greps across `scripts/*.sh` or otherwise
claims a tree-wide property. Known instances (confirm the list is complete by
searching, do not trust it):
- `94-rot-sweep.sh` — all 5 sections
- `91-flags-parsers-docs.sh` §5 — the "no `ffp … | head -1` sites remain" sweep
- `92-probe-lang-merge.sh` §4 — the audio-manifest single-writer guard
- `93-clean-paff-route.sh` §4/§5/§6 — the invariant, structure, and
  generalization pins
- `14-exit-codes.sh` — the entry-point roster derived from `scripts/*.sh`
- `41-422-empirical.sh` — the pix_fmt-refusal grep-audit
- `90-harness-honesty.sh` — the derived roster assertions
- `84-d1-d2-evidence-loss.sh` — the A4 confession-vocabulary lockstep

**Method.** For each guard: introduce the exact defect it claims to catch,
confirm the guard FAILS, restore, confirm it passes again. Automate this —
doing it by hand is how a guard gets skipped.

**Definition of done.** A table of every guard with CAUGHT / MISSED. Every
MISSED either fixed (and re-mutated to CAUGHT) or, if it genuinely cannot be
made non-vacuous, deleted with the reason recorded — a guard that cannot fail
is worse than no guard, because it is believed.

## Item 2 — audit the same guards for false-positive-proneness

A tree-wide guard that cries wolf gets disabled, and then its class is
unguarded AND believed guarded. Test 94 §3's first draft audited every
`rm -rf` and false-positived on `.lock` paths, on a quoted string assertion,
and on the test file itself; it was narrowed to pin the precise defect shape
(the shared-ground SCAN, not the delete).

For each guard, check whether its detector can match: comments, documentation
prose, quoted strings inside assertions, or the guard file itself. Prefer
narrow-and-true over broad-and-ignored. Where a detector must stay broad,
strip comments first (`sed 's/#.*//'`) and exclude self.

**Definition of done.** Every guard reports zero false positives on the tree
as it stands, and each detector's exclusions are justified in a comment.

## Item 3 — name and enumerate the classes not yet swept

The rule: enumerating a named class is mechanical, so it belongs in a test
the moment the class is named — never deferred to "the next round."

Sweep the tree, name each class found, and either add it to test 94 or record
it as investigated-and-sound. Candidates observed but NOT enumerated (verify
each; counts are approximate and from a prior session):
- **`set +e` regions (~45).** Does every one restore `set -e`? Does any leave
  errexit disarmed across a verdict or a write?
- **bare `mktemp -d` (~14 sites).** Measured: macOS `mktemp -d` ignores
  `TMPDIR`, and so does `-t`; only an explicit template honours it. Confirmed
  NOT to affect `rtm_disk_preflight` (it receives the actual `$WORK` path). The
  residual is a limitation — an operator cannot redirect scratch to another
  volume on macOS. Is that stated in `references/known-limits.md`? If not, it
  should be.
- **Cross-script condition modelling.** 1.15.13 removed one instance
  (`clean.sh` mirroring `zero-base.sh`'s refusals). Are there others — drivers
  that re-derive another script's refusal conditions rather than asking it?
  Check `auto.sh`, `mov.sh`, `diagnose.sh` in particular. Any found should get
  the `--preflight-only` treatment: the authority answers for itself.
- **Duplicated literal tables** — codec rank lists, QTFF tag allowlists,
  confession vocabularies. Where a table appears twice, it can drift; either
  centralize it or add a lockstep guard.

**Definition of done.** Each class either enumerated by a live,
mutation-verified guard, or recorded in the CHANGELOG as investigated-and-sound
with the measurement that settled it.

## Item 4 — the census_rc contract (the known duplication left standing)

**Current state, re-measure to confirm:** ~10 builders reference `census_rc`
(`dual-track.sh`, `metadata.sh`, `pairfill-paff.sh`, `rebuild-paff.sh`,
`remux.sh`, `resync.sh`, `rung4.sh`, `surgical-cut.sh`, `trim-to-idr.sh`,
`zero-base.sh`, possibly `mp4-swap.sh`). After normalizing away stage names and
variable names there are **9 genuinely different implementations** of the same
contract: rc 0 or 10 is acceptable, anything else is a census failure.

The safety-critical semantic is currently uniform — every consumer carries the
`census_rc" -ne 10` guard — and test 94 §4 pins that uniformity. So this is a
maintenance hazard, not an active defect: adding a new acceptable rc today
means finding and editing 10 sites.

**Task.** Give the contract one writer, in the spirit of 1.15.14. Likely shape:
a helper in `lib-mux.sh` (where the other `rtm_*` helpers live) that takes the
rc plus the per-builder parameters, and returns the verdict. The genuinely
per-builder parts must STAY per-builder — the stage name, the message wording,
the retention behaviour, the exit contract, and the machine rows
(`RMX_CENSUS` et al.). As in 1.15.14: share the FACT, not the presentation.
If some builders turn out to differ semantically and not just cosmetically,
that divergence is a finding — report it before flattening it.

**Definition of done.** The contract has one definition; every builder consumes
it; every builder's exit codes, machine rows and retention behaviour are
unchanged (pinned by the existing sub-suites, which must stay green); test 94
§4 is updated to pin the single writer rather than the uniformity of copies;
full suite green.

---

## Reporting

For each item, report what you MEASURED, not what you intended. State plainly
anything you could not close and why. If an item turns out to rest on a false
premise from this document, say so — that is a more useful result than a fix
built on it.

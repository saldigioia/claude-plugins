# Constitution — remuxing-to-mov

## Why this document exists

The rules of this plugin were, until now, distributed across work orders,
checkup documents, changelog entries and code comments, and cited by
shorthand: `WO 3.4`, `D5`, `A1`, `F12`, `CHECKUP-2026-08-27`. Measured on
2026-08-27, `scripts/` and `tests/` contain **hundreds** of such citations —
48 to one checkup document alone.

Every one of them resolves today. That is not the problem. The problem is
what resolving one *gets you*: it tells you **where a claim was written, not
whether it is still true.** A reader who doubts a rule has to find the
document, read it, and then take its word — and documents go stale silently.
A memory note in the authoring session asserted these very work orders were
"untracked, not committed"; they have since been committed, so the note was
true when written and false when read. That is the failure mode in one line.

So: **an amendment's authority is a measurement you can re-run, not a
document you can go find.** Every amendment below states how to test it. If
you doubt one, do not go looking for its work order — run its test.

**If a test does not reproduce, that is a finding, not a formality.** Report
it. An amendment whose test no longer passes is either a broken rule or a
broken test, and both matter more than the work you were about to do.

Provenance lines are **discardable**. They record which round found the rule,
for anyone curious about history. Nothing in this document depends on them,
and no amendment may be written so that it cannot be understood without
following one.

Run everything below from `skills/remuxing-to-mov/`.

---

## Article I — What may be done to media

### I.1 — Video is never re-encoded
**Rule.** Video is stream-copied. Every route, every rung, every fallback. A
route that cannot preserve the coded bitstream must refuse, not transcode.
**Failure it prevents.** A "lossless" archival tool silently generating a
generation loss.
**Test.** `bash tests/regression.d/41-422-empirical.sh` — and the arbiter
itself: `bash tests/regression.sh` §2/§3, where a re-timed lossless copy keeps
an identical VCL-payload hash while a real re-encode FAILs it.
*Provenance: pre-1.8, foundational.*

### I.2 — The source is never modified
**Rule.** No route writes to, renames, or deletes its input. The clinic is
report-only; corrections write a new file.
**Test.** `bash tests/regression.d/72-clean.sh` (clinic writes nothing) and
`bash tests/regression.d/68-zero-base.sh`.
*Provenance: 1.15.0 source-clinic round.*

### I.3 — Never build to a foregone refusal
**Rule.** If a source cannot be blessed by the route's own mandatory checks,
refuse at PRE-FLIGHT with nothing written. Never spend the build first.
**Failure it prevents.** A 23.68 GB build that ran to completion and then
hard-stopped, for a prize of 40 ms on a `start_time` players rebase away.
**Test.** `bash tests/regression.d/75-zero-base-paff-refusal.sh` — asserts
exit 2, nothing written, and that the refusal precedes the floor probe, the
prediction pre-pass and the whole-file scan.
*Provenance: 1.15.2 Item C.*

---

## Article II — How verdicts are reached

### II.1 — UNPROVEN is not FAILED
**Rule.** A gate that cannot evaluate its input reports REVIEW and says why.
It never converts inability-to-measure into an accusation of damage.
**Failure it prevents.** A correct 24.8 GB artifact failed at the last gate
because the checker could not read it correctly — reported as loss.
**Test.** `bash tests/regression.d/79-poc-gate-standalone.sh` (exit 10 on an
input the gate cannot judge, not exit 1) and
`bash tests/regression.d/81-empty-ne-absent-verdicts.sh`.
*Provenance: 1.15.2 Defect D relabel.*

### II.2 — An unidentified baseline cannot prove damage
**Rule.** Where a gate cannot establish which source it is entitled to
compare against, it reports the ambiguity and returns REVIEW — never an
unwaivable FAIL.
**Why it is not a weakness.** On a source with four identically-propertied
audio tracks the matcher cannot narrow the candidate set, and saying so is the
honest answer. Guards must be general; verdicts may stay conservative.
**Test.** `bash tests/regression.d/36-audio-gate.sh`.
*Provenance: QTFF audit gate (g).*

### II.3 — Verdicts state what was measured, not what was intended
**Rule.** Every REVIEW reason names its measurement and its counts. "Looks
fine" is not a verdict; `source: 16 / output: 2 / delta: -14` is.
**Test.** `bash tests/regression.d/66-verify-source.sh` and
`bash tests/regression.d/24-gate-f-budget.sh`.

---

## Article III — How evidence is collected

### III.1 — EMPTY is not ABSENT
**Rule.** No probe output feeds a verdict, a plan, or an accusation without
its exit status. Only a SUCCESSFUL empty probe may be read as "none".
**Failure it prevents.** One failed `ffprobe` shipped a silently
audio-stripped MOV as ">> DONE … verified lossless", exit 0 — measured
end-to-end, twice.
**Test.** `bash tests/regression.d/80-empty-ne-absent-audio-plan.sh` (28
assertions) and `bash tests/regression.d/81-empty-ne-absent-verdicts.sh`.
*Provenance: 1.15.4, the twin of II.1.*

### III.2 — A scanner states its jurisdiction
**Rule.** A scanner reports the scope it actually covered. An unscoped CLEAN
is a lie of omission: it reads as "I checked and found nothing" when the truth
is "I could not check".
**Failure it prevents.** `ts-health` read "video packets=1532 … CLEAN" on a
video-less source, and the driver routed a build that could only die later.
**Test.** `bash tests/regression.d/88-jurisdiction.sh` (35 assertions).
*Provenance: 1.15.7.*

### III.3 — Never read where you did not write
**Rule.** A process may look only at scratch it created. Nothing scans shared
temp ground for files matching a pattern, and nothing deletes what it does not
own. To watch a child's scratch, force it somewhere you own (the `mktemp`
PATH-shim pattern in test 84).
**Failure it prevents.** A test scanning the shared temp dir deleted the live
scratch of a running 24 GB build mid-verify, which then reported its
whole-file check INCONCLUSIVE. This is not hypothetical; it happened.
**Test.** `bash tests/regression.d/94-rot-sweep.sh` §3, tree-wide. Negative
control: point any watcher at `$TD` instead of its own scratch and §3 must go
red.
*Provenance: 1.15.12.*

---

## Article IV — How the code is structured

### IV.1 — One writer per fact
**Rule.** A fact — a query, a parse, a policy, a contract — has exactly one
definition. Consumers consume it. What legitimately differs between consumers
(error loudness, presentation, fallbacks) stays with the consumer: share the
FACT, never the presentation.
**Failure it prevents.** The audio-manifest query, parse and merge existed in
two copies; a fix was applied to one, and the other reported `und` for four
`eng` tracks across four releases.
**Test.** `bash tests/regression.d/94-rot-sweep.sh` §5 (no centralized fact
has a second definition) and `bash tests/regression.d/92-probe-lang-merge.sh`
§4.
*Provenance: 1.15.14.*

### IV.2 — Ask the authority, never model it
**Rule.** A driver must not re-derive another script's refusal conditions. It
asks that script and relays the answer. **A driver that can enumerate another
script's refusals is already wrong** — the enumeration will fall behind, and
nothing will say so.
**Failure it prevents.** The clinic printed a "ready to run" command for a
source the target refuses at pre-flight — twice, on two different axes, each
found a round late.
**Test.** `bash tests/regression.d/93-clean-paff-route.sh` §5/§6. §6 is the
proof: the multi-program axis closes correctly in a driver that contains no
multi-program code at all.
*Provenance: 1.15.13.*

### IV.3 — Duplication not yet removed must be held in lockstep
**Rule.** Where a fact is still duplicated, a guard pins the copies to the
semantic that matters, so drift fails the bench instead of shipping.
**Currently standing under this amendment.** The QuickTime-native audio table
`aac|alac|mp3|pcm_*|eac3` — four case arms (`mov.sh` twice, `remux.sh`,
`pairfill-paff.sh`), deliberately NOT centralized: `mov.sh`'s classifiers are
sourced by the `RTM_TEST` harness, and each arm reads at its point of
decision. E-AC-3's membership has drifted before — 1.15.9 F7 found the
dual-track reference page still calling it a dual-track class rounds after the
code classified it native.
**Discharged (1.15.17).** The `census_rc` contract stood here from 1.15.15 —
9 implementations across 10 builders, uniform on the semantic, pinned but not
refactored. It now has one writer (`rtm_census_failed` / `rtm_census_review`
in `lib-mux.sh`) and lives under IV.1. So does the muxer's confession
vocabulary: five byte-identical copies of which only two were pinned, now
`RTM_CONFESSION_RE`.
**Test.** `bash tests/regression.d/94-rot-sweep.sh` §8 (the table held in
step); §4 and §7 pin the two that were discharged.

---

## Article V — How the guards are guarded

### V.1 — A named class is enumerated immediately
**Rule.** The moment a defect class is named, it is swept mechanically across
the whole tree and pinned. Fixing the instance you tripped over and deferring
the sweep to "the next round" is not a method: it guarantees the next round
has a defect waiting.
**Failure it prevents.** Three consecutive releases each fixed one instance of
one class, and the third was found only because a test run happened to share a
machine with a large build.
**Test.** `bash tests/regression.d/94-rot-sweep.sh` — the standing sweep.
*Provenance: 1.15.15.*

### V.2 — Every guard is mutation-tested
**Rule.** A guard is not trusted until it has been *seen to fail*. Introduce
the exact defect it claims to catch, confirm it goes red, restore.
**Failure it prevents.** Two of the standing sweep's five guards were vacuous
when first written and passed green while guarding nothing: one pattern also
matched the COMMENT that described the idiom, so prose satisfied it; one used
`grep -l`, counting FILES, so a second definition in the same file was
invisible.
**The restore is part of the mutation, and it must be tested too.**
`git checkout` is NOT a safe restore in a working tree with uncommitted
changes: run against this repo while 1.15.14 was still uncommitted, it
reverted `lib-probe.sh` to a version predating `rtm_aud_manifest` and silently
destroyed the round. Worse, the guard then went GREEN — because the reverted
file no longer contained the construct being guarded, so the check skipped it.
A mutation test whose restore is wrong can therefore report success while
having deleted the very thing under test. Back up by copy, and verify the
restore, not just the red.

**Test.** `bash tests/mutation-audit.sh` runs the whole roster mechanically
(WO-1.15.17): for every tree-wide guard it introduces the exact defect into a
THROWAWAY COPY of the plugin and requires that guard's assertion to flip
PASS -> FAIL, then introduces a benign PROSE mention of the same idiom and
requires it to stay PASS (V.3's half, automated). The real tree is never
written to, which retires the restore hazard above by construction. Two lanes,
because a guard fails in two directions; `MA_KEEP=1` keeps every sandbox and
log for inspection.

By hand, on one guard — mutate, observe red, restore, observe green, and
confirm the file is whole:
```
cp scripts/lib-probe.sh /tmp/lib-probe.bak
sed -i '' 's/BEGIN{ n=0 }/BEGIN{ }/' scripts/lib-probe.sh
bash tests/regression.d/94-rot-sweep.sh          # expect §2 FAIL
cp /tmp/lib-probe.bak scripts/lib-probe.sh
bash tests/regression.d/94-rot-sweep.sh          # expect §2 PASS
grep -c 'rtm_aud_manifest () {' scripts/lib-probe.sh   # expect 1, not 0
```
A green after restore proves nothing on its own — check the file back.
*Provenance: 1.15.15; the restore hazard measured 2026-08-27 while verifying
this very amendment.*

### V.3 — A tree-wide guard is narrow and true, never broad and ignored
**Rule.** A guard that reports false positives gets disabled, and then its
class is unguarded **and believed guarded** — strictly worse than no guard.
Pin the precise defect shape. Strip comments before matching any pattern that
also appears in prose, and exclude the guard's own file.
**Failure it prevents.** A first-draft `rm -rf` audit false-positived on
`.lock` paths, on a quoted string inside an assertion, and on itself. It was
narrowed to pin the scan rather than the delete.
**Test.** `bash tests/regression.d/94-rot-sweep.sh` must report zero failures
on an unmodified tree; every exclusion in it carries a comment saying why.
*Provenance: 1.15.15.*

### V.4 — The bench is the standard
**Rule.** Nothing ships without the full suite green, both manifests valid,
and the changed files synced to the installed copy. A test is written FIRST
and verified RED before the fix.
**Test.**
```
bash tests/regression.sh                                   # expect: FAILED: 0
bash tests/mutation-audit.sh    # when a tree-wide guard changed (V.2)
cd ../../.. && claude plugin validate ./plugins/remuxing-to-mov --strict
                claude plugin validate . --strict
diff -rq --exclude=__pycache__ --exclude=fixtures \
  plugins/remuxing-to-mov ~/.claude/plugins/marketplaces/rare-data-club/plugins/remuxing-to-mov
```

### V.5 — A behavioral edit that reaches a bench carries a version bump
**Rule.** Any change to behavior that lands on an installed copy carries a
version bump in `.claude-plugin/plugin.json` — a hotfix, a one-liner and an
in-place field patch included. The version string is the only cheap integrity
check a handoff has ("if it still reads X, the reinstall did not take"), and a
stale one does not merely fail to help: it answers that check with a confident
lie. Tools that report the version READ IT AT RUNTIME from the manifest
(`rtm_plugin_version`, lib-exit.sh); no script carries a hardcoded copy.

**Motive (measured).** A 2026-08-28 field re-test spent its opening minutes
establishing which build it was talking to: six scripts had been patched in
place under a version that still read `1.15.18`, so the handoff's own
did-the-reinstall-take check produced a false negative, and mtimes and code
markers had to settle it instead.
**Test.**
```
bash tests/regression.d/99-route-prose-and-identity.sh   # §3, the standing guard
scripts/doctor.sh --kv | grep '^DOC_PLUGIN_VERSION='     # matches the manifest
scripts/probe.sh IN --kv | grep '^PR_PLUGIN_VERSION='    # same, from the prober
```
The guard is over version ASSIGNMENT, not over any mention of a release number:
`WO-1.15.20` and "its 1.15.2 case file" are provenance and stay legal, while
`VERSION="1.15.20"` is the stale string that answers an integrity check with a
confident lie.

---

---

## Amending this document

An amendment needs: the rule, stated so it can be understood without following
any reference; the failure it prevents, stated as something measured; and a
test that can be run to settle a doubt. If you cannot write the test, you have
a preference, not an amendment — say so and leave it out.

When an amendment is retired, say what measurement retired it.

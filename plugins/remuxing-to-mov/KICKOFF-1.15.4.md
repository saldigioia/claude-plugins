# Kickoff — 1.15.4 "EMPTY ≠ ABSENT" (paste as the first prompt of the session)

Read these in order before touching anything:

1. `CHECKUP-2026-08-27.md` (plugin root) — **end to end**. It is the contract
   for this round: findings A1–F12 with repro recipes, the assumption
   register, the coverage map, the "Interrogated and sound" list (do NOT
   re-litigate anything on it), the round packaging, and the post-checkup
   one-liner ledger — those fixes are already applied and the suite ran
   274/274 green on the edited tree.
2. `WO-1.15.2-FIELD-DEFECTS.md` — skim "What the field run revealed" for the
   house voice and the UNPROVEN ≠ FAILED rule this round's twin extends.
3. `WO-1.15.3-VERIFY-POC-REACH.md` — filed, corrected same day, unexecuted.
   **Not this round; don't start it.**

Tree state: the one-liner round + both checkup docs + the corrected WO are
UNCOMMITTED in the working tree. The `plugins/hunt/*` modifications in git
status are mine, predate all of this — never touch, revert, or commit them.

**First action:** commit the remuxing-to-mov changes only (path-scoped
`git add` of `plugins/remuxing-to-mov/` — nothing from hunt/), one commit, a
message in the house style summarizing the checkup + one-liner round.

**Then file `WO-1.15.4-EMPTY-NE-ABSENT.md` and execute it.** Scope, from the
checkup's round packaging, and nothing else (1.15.5 one-writer, 1.15.6
jurisdiction, the harness round, and the docs round come later):

- **A1** — the audio plan fails open (`remux.sh:135` `|| true`): probe
  failure must be distinguishable from "no audio" and must refuse/route,
  never bless. Cover the whole feeder family the checkup names: `mov.sh:499`
  PLANOUT, `rebuild-paff.sh:101`, `verify.sh:407` naud, and the
  `eval "$(probe.sh --kv | grep …)"` sites (`mov.sh:174,425`, `auto.sh:67`)
  where probe.sh's awk fabricates `PR_AUD_COUNT=0` on a failed producer.
- **C2** — verify-source with an empty/unreadable source baseline must
  report "no baseline", never accuse "INTRODUCED".
- **C3** — verify.sh gate (b): empty-vs-empty hashes are "could not decode",
  never "frames differ / NOT a lossless copy".
- **C4** — ts-health dying on an unreadable input must say so and exit 2
  (usage/pre-flight), never a silent 1 (= DAMAGED per its own contract).
- **C6** — the `spo()` ffprobe field-order fix (`verify.sh:1196`), deferred
  from the one-liner round BECAUSE it re-arms the dead D4 verdict branch:
  land it WITH the D4 fixture + test.
- **C7** — mov.sh must survive a child's exit 10 (remux.sh's sanctioned
  REVIEW) and still run verify + print `MOV_SUMMARY` + its own verdict.
- **D1** — the confession hard-stop report pipelines
  (`remux.sh:436`, `pairfill-paff.sh:370`) must not SIGPIPE away the
  `Kept: … (log: …)` pointer on large muxlogs (`derive-dts.sh:218` is
  already fixed — use it as the pattern reference).
- **D2** — `verify.sh --full` hlist: a mid-decode failure must produce a
  diagnostic, not a silent exit-1, and must not leak the mktemp dir
  (same shape: `lead-check.sh:150`, `qt-groups.sh:290`).
- **C8** — plumb `RTM_PROBESIZE`/`RTM_ANALYZEDURATION` into
  `derive-dts.py`'s `av.open()` calls (the 200M-floor class the rung exists
  for; the repo's own `late-sps.ts` fixture measures it).

Rules of engagement, non-negotiable:

- **EMPTY ≠ ABSENT** (this round's rule, twin of UNPROVEN ≠ FAILED): no
  probe output feeds a verdict, plan, or accusation without its exit status.
  House idiom: the `set +e; x=$(…); rc=$?; set -e` capture at `clean.sh:45`.
- Every fix lands with a test that is **red on the pre-fix code** — the
  checkup appendix's repro recipes are the fixture recipes; use the unit
  lane (test-76 pattern) wherever the function is text-in/text-out, and the
  PATH-shim pattern for the fault injections.
- Pin relationships, never bench literals. Trust no comment — verify
  against code; the checkup's own claims were verified once, but re-measure
  any figure you build on.
- Gate: `bash tests/regression.sh` green from `plugins/remuxing-to-mov/`
  AND `claude plugin validate --strict` green, version bump + CHANGELOG
  entry in house style, provenance comments naming this round.
- Don't re-fix what the one-liner ledger already covers; don't expand scope
  into the other rounds no matter how tempting the adjacent finding looks —
  record the temptation in the WO's leftovers section instead.

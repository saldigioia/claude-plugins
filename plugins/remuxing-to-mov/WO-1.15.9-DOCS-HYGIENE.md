# 1.15.9 Work Order — Flags That Lie, Parsers That Shrug, Docs That Teach the Retired Route

> **Status (2026-08-27): filed and executed in the same session.** The final
> checkup round: **F2, F5, F6, F7** plus the hygiene debt the earlier rounds
> deferred — **D3** (the `ffp … | head -1` class conversion) and the
> **dim-scan D1 sibling**. Test **91**, red-verified against e3110b9
> (19 red of 26).

## What landed

- **F5 — `--mp4-swap` and metadata on the PAFF path** (`mov.sh`): the flag
  was parsed and silently ignored there (the `--audio-keep` class of trap,
  fixed six lines away in 1.15.2 for AKEEP only) — it now rides through to
  `auto.sh`, which owns the swap (fires on a post-build fidelity FAIL), and
  the usage string names it. A PAFF REVIEW build (rc=10) silently skipped
  requested metadata (`MDARGS` applied only on rc=0 while the non-PAFF path
  applies unconditionally) — metadata now applies on 0 AND 10, with a
  REVIEW floor that survives the post-metadata re-verify (the 10 may have
  come from auto's other gates, e.g. playability; a clean container
  re-verify does not clear those).
- **F6 — parser strictness:** `diagnose.sh IN --deep` was a silent no-op
  (--deep is clean.sh's flag — the operator reads "diagnosed deep");
  `clock.sh`/`gop-probe.sh` swallowed stray third arguments; a `ts-health`
  MODE typo (`--kvv`) fell back to human mode so a --kv consumer got zero
  KV rows and exit 0; `mov.sh in.ts -full` took the typo as the OUTPUT
  filename and BUILT a file named "-full". All five now exit 2 naming the
  stray; the mov.sh fix treats any leading-dash positional as a flag (the
  option loop rejects unknowns).
- **F2 — the retired routing doctrine:** "reordered → pairfill" (the exact
  misroute 1.14 shipped to fix, preserved as instructions) is gone from
  `README.md`'s ladder, `skills/mov/SKILL.md`'s PAFF bullet, and
  `SKILL.md`'s hard-won-facts route line — all three now route by MEASURED
  profile and name Rung 3-DERIVE. `references/timeline-repair.md` — named
  by SKILL.md as "the full repair ladder" — finally carries a Rung 3-DERIVE
  section and the widened (2026-08-18) junction precondition in its
  Rung 3-PAIR preconditions (the page asserted strict alternation a version
  behind the code); `rebuild-paff`'s scope-limit paragraph routes reordered
  streams by profile instead of "use pairfill".
- **F7 — promises match the gates:** README's "decoded-pixel identity
  (timestamp-agnostic MD5)" for EVERY output was `--full`'s proof — the
  default tier's arbiter is the coded-bitstream (VCL) identity, and the
  text now says so. `dual-track-quicktime.md` no longer steers "when
  unsure, default to dual-track" against the classifier the drivers
  actually run: E-AC-3 is QuickTime-native (copy-single in the drivers);
  the AC-3 table row applies to E-AC-3 only when the operator explicitly
  dual-tracks for an access/preservation split.
- **D3 — the `ffp … | head -1` class:** 94 sites converted to `ffp1`
  (92 by a reviewed scripted pass + 2 hand sites hiding behind the `#` in
  `'%+#1'` read-intervals). These carried the exact preconditions of the
  1.15.2 SIGPIPE field defect (multi-line producers on program-bearing TS,
  early-exit reader, bench-stable race); `ffp1` is byte-identical on
  single-line queries and the doctrine since 1.15.2 — it was used at 2
  sites. Chained sites (`| head -1 | tr …`) became `ffp1 … | tr …`. The
  no-single-pipe-sites-remain sweep is pinned in test 91 §5 (comment-
  stripped, so lib-probe's own doc line doesn't count).
- **dim-scan D1 sibling:** the `grep | head -1 | awk` assignment-position
  pipeline (SIGPIPE under pipefail on a ~1900-CHANGE scan) became a single
  `awk '/^CHANGE /{print $2; exit}'` reading the file directly.

## Gates

Test 91 red-verified (19 red of 26; the clock probe corrected to a valid
PLAYER_TIME so its red is for the right reason — 0:01 was already rejected
as non-numeric); neighbors 14/21/45/53/66/67/71/72/88/89 green after the
94-site sweep; suite **289/289** (288 carried + 1 new);
`claude plugin validate --strict` green on both manifests.

## Residuals (recorded)

- F6 is scoped to the measured offenders (diagnose/clock/gop-probe/
  ts-health/mov dash-OUT); a tree-wide strict-argv sweep of every entry
  point was not attempted — test 14's derived roster now catches contract
  violations, not stray-arg tolerance.
- The D3 sweep converted `ffp` sites; direct `ffprobe | head -1` sites
  (rare, mostly on OUTPUT files with no program duplication) were not in
  the checkup's measured class and were left.
- `clock.sh`'s PLAYER_TIME accepts numeric seconds only (`0:01` is
  rejected) — pre-existing, surfaced while red-verifying; recorded, not
  changed (the usage string says seconds).

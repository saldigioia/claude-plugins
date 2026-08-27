# 1.15.8 Work Order — The Harness Counts What It Cannot See

> **Status (2026-08-27): filed and executed in the same session.** The checkup
> round packaged as "harness" (CHECKUP-2026-08-27 **Class E**; rule 6: *the
> harness counts skips, cross-checks each case's tail line against its exit
> status, and derives rosters from the tree*). Plus the now-tractable
> closures: **E6** (the in-situ POC UNPROVEN count arm — testable since
> 1.15.5's census side files), **E4** (the vacuous `--signaling` gate — a
> color-tagged fixture and a lossless `h264_metadata` VUI-rewrite drift
> fixture are both mintable, measured this session), and **E8's 5.2 debt**
> (`rewrap_nudges`/`rewrap_hard_confessions` unit tables — pure
> text-in/count-out functions). Test **90**; E7 lands inside test 14 itself.

## Scope

- **E1 — enrollment is +x-gated and a deleted lane reads green.** Measured:
  a non-exec stub and even a deleted `regression.d/` both yield
  `PASSED: 0 FAILED: 0`, exit 0 — one `chmod 644` retires a defect's only
  guard invisibly (and F3 showed bits drift in this repo). Fix: the runner
  loop factors into `tests/lib-harness.sh` (`run_subsuites`); every `*.sh`
  is enrolled REGARDLESS of exec bit (bash needs no +x; a missing bit is a
  printed mode-drift note, never an un-enrollment), and a missing/empty
  `regression.d/` is a suite FAILURE.
- **E2 — the harness trusts only exit status.** Measured: a stub whose last
  command succeeds while its own tail says "1 failed" counts PASS. Fix:
  the runner cross-checks the tail line against the exit status — a green
  exit with a nonzero "N failed" tail, or with NO recognizable tail at all,
  is a convention-breach FAILURE. (Sweep at execution: all existing
  sub-suites already carry the `name: X passed, Y failed` tail.)
- **E3 — skips are green and invisible.** Eight distinct capability gates
  (pcm_bluray, MP4Box, libx265, PyAV, qlmanage, yuv422p, ipcm, setts) exit
  0 with no counter — a leaner bench keeps the "N/N" shape while whole
  lanes stop being tested. Fix: the runner counts SKIP announcements in
  each sub-suite's output and the final banner prints the tally — green,
  but VISIBLE. (Main-section skips outside the sub-suite lane are not in
  the tally; recorded below.)
- **E7 — the exit-contract roster is hand-kept and 8 scripts behind.** Test
  14 now derives its roster from `scripts/*.sh` minus `lib-*` at runtime;
  the eight 1.15-era entry points (clean, clock, dim-scan, lead-check,
  mp4-swap, surgical-cut, verify-source, zero-base) join the forced-failure
  battery, and any FUTURE entry point joins automatically.
- **E6 closure:** the in-situ POC-gate UNPROVEN branch (the count arm — the
  pre-flight now owns the poc_type arm) is exercised end-to-end through
  pairfill via a canned census whose picture count matches the build (the
  histogram gate must pass) but whose poc table is short — rows != packets
  trips the count guard: machine row `unproven=1 why=count`, retention +
  re-judge route, exit 1.
- **E4 closure:** `--signaling` sees real color tags both ways — preserved
  (bt709 source, `-c copy`, value printed back) and DRIFT (the same
  bitstream with its VUI rewritten to bt2020/PQ via `h264_metadata` — a
  LOSSLESS rewrite, so every other gate passes while signaling must catch
  it: the exact "invert the comparison" mutation E4 warned stays green).
- **E8 / 5.2 debt:** `rewrap_nudges` / `rewrap_hard_confessions` unit
  tables — canned logs, counts, and the discrimination pin (a +1-tick
  nudge is never a hard confession and vice versa).

## Not this round (recorded)

- **E5** — the junction setts arithmetic on REAL untimestamped data: the
  synthesis limit is house doctrine (encoders/muxers stamp every packet;
  test 65's header records it); the mechanism halves stay injection-pinned.
- **E8 remainder** — doctor.sh degraded verdicts never forced;
  `derive-dts.py` DTS math has no direct unit tests (PyAV-gated E2E only);
  `pf_dts_source` sniff table injection-only. Fixture-reality gaps:
  multi-program on success paths, real open-GOP, DTS/DCA audio, MBAFF.
- The skip tally covers the sub-suite lane (where the eight capability
  gates live); main-section skip echoes are uncaptured by design — noted
  in the banner text.


## Execution record (2026-08-27, same session as filing)

Executed against f45b89d (the 1.15.7 tree). Test 90 red-verified first
(6 red — the E1/E2/E3/E7 metas; the E6/E4/E8 sections were coverage
additions, green through the 1.15.5 seams once their fixtures were right),
then green 31/31, mode 755. E7 landed inside test 14: roster derived from
scripts/*.sh minus lib-*, the nine new entry points (the 1.15 clinic family
+ poc-gate) joined the forced-failure battery and passed IN CONTRACT on
every arm (109/109) — no code fixes needed, which is itself the round's
best measurement.

Bench facts recorded in test 90 (each measured this session):
- a command substitution around `run_subsuites` loses the recorders — plain
  redirection, never `$( )` (subshell);
- bare `-color_primaries/-color_trc` encoder flags landed only the MATRIX
  on this bench — `setparams` stamps all three VUI fields;
- a MOV output masks a rewritten SPS behind a `colr` atom written from the
  INPUT's codec parameters — the E4 drift fixture rides mpegts, where the
  probe reads the SPS.

The full suite's first run through the honest runner: **288/288**, and the
banner surfaced **4 real skip announcements** on this very bench (the E3
visibility working as designed — those are the dormant lanes an operator
now sees). `claude plugin validate --strict` green on both manifests.

Residuals as filed (E5 synthesis limit; E8 remainder: doctor degraded
verdicts, derive-dts.py direct units, pf_dts_source beyond injection;
fixture-reality gaps; main-section skips outside the tally).

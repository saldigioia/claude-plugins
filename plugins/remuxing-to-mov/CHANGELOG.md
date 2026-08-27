# Changelog — remuxing-to-mov

History moved here from the `plugin.json` description in 1.15.0 (the orphaned
1.14 Phase-6 packaging item). Detailed doctrine lives in `skills/remuxing-to-mov/
SKILL.md` and `references/`; every empirical claim below is dated in the docs.

## 1.15.6 — "one writer, atomic bless" round (2026-08-27)

`WO-1.15.6-ONE-WRITER.md` — the checkup round packaged as "one writer"
(CHECKUP-2026-08-27 **A2 + F11**, both CONFIRMED with measured repros),
penciled there as "1.15.5" and shipping as 1.15.6 (WO-1.15.3's execution
took 1.15.5). Tests **86–87**, red-verified against 6e90e20 first
(86: 14 red — including the sequential evidence-truncation pin; 87: 11 red).

- **A2, half 1 — unique part names:** `rtm_part` now mints
  `out.part-<pid>-<epoch>.mov` (extension-keeping as ever — D6 is about the
  SUFFIX, not determinism). The deterministic name was half the measured
  corruption: two runs sharing one part path meant run B's `ffmpeg -y`
  truncated run A's part mid-census (A blessed foreign bytes, rc=0,
  delivered file undecodable), and the SEQUENTIAL half — a stale `.part`
  kept as FAIL evidence was silently truncated by the next run's `-y`, the
  very file the retention message invited the operator to inspect. Test 86
  pins the kept evidence surviving a retry byte-identical. `rtm_sidecar`
  stays deterministic on purpose (premeta/autobest must be re-derivable
  within a run; cross-run safety is the lock's job). `trim-to-idr.sh`'s
  1.9-era inline part name converts to `rtm_part`. Test 45's exact-name
  pins re-recorded as shape pins (deviation recorded in the WO).
- **A2, half 2 — the per-OUT writer lock:** `rtm_lock`/`rtm_unlock`
  (lib-mux.sh) — `mkdir "<OUT>.lock"` (atomic POSIX primitive; macOS ships
  no flock) holding pid + host. A second live writer REFUSES pre-flight,
  exit 2, nothing written, machine row `RTM_LOCK verdict=refused holder=
  dir=`. A dead same-host holder is stolen with one announced line
  (kill-9/reboot self-heal); an EMPTY pid file is treated as LIVE — the
  holder's mkdir-to-pid-write window is never stolen (never-corrupt beats
  auto-heal; the refusal names `rm -rf` for the truly-orphaned case).
  Drivers hold ONE lock across children/sidecars/post-build reads via the
  exported `RTM_LOCK_HELD` re-entry (mov.sh after OUT settles, auto.sh
  before the stale-park rm, mp4-swap.sh newly sourcing lib-mux,
  waiver.sh — a waiver must never bind to a MOVING OUT). Release is an
  EXIT trap at the acquisition site (after every arg guard — the lib-exit
  EXIT-trap caveat pattern); lib-exit already routes INT/TERM/HUP through
  exit 1, so killed runs release; kill-9 leaves the stale-steal case.
- **F11 — disk pre-flight:** `rtm_disk_preflight OUT SRC [STAGE_DIR]` —
  free bytes on OUT's volume (and the staging volume: `rebuild-paff` stages
  ~1× the source's media on TMPDIR before its mux starts) must be ≥ the
  source size, else REFUSE exit 2 with the arithmetic + machine row
  `RTM_DISK verdict=refused free= need= vol=`. ONE rule deliberately (the
  TSH_LOSS_FAIL precedent); its stated assumption — a lossless remux
  writes roughly the source's size — has legitimate exceptions (cuts,
  trims), so `RTM_DISK_CHECK=0` is an OPERATOR knob: a resource heuristic
  is not an evidence gate, which is why a knob is legitimate here where
  1.15.2 Defect-B forbade one. A failed `df` announces "could not
  measure — proceeding unverified" and never refuses (EMPTY ≠ ABSENT
  applies to refusals too: a broken meter is not a full disk). Test hook
  `RTM_DISK_FREE_KB`; threshold pinned as a relationship in test 87 (free
  just below the fixture's size refuses, just above proceeds).
- **Wiring:** `rtm_writer_preflight OUT SRC [STAGE_DIR]` (lock + disk) at
  all 11 builders' writer-begins point (the `rtm_part` site — read-only
  modes like `--print-plan` never reach it); `zero-base`/`surgical-cut`
  re-arm their TMP traps to include the unlock. Lock-only at the four
  driver/sidecar scripts. Machine rows tabled in SKILL.md; knobs
  (`RTM_DISK_CHECK`, hooks) in `knobs.md`.
- **Recorded residual:** `batch.sh`'s ledger CSV (a report, not an
  artifact) is not locked — two concurrent batch runs sharing a ledger
  path interleave it; inherited by the next filing knowingly.

## 1.15.5 — "verify the POC gate's reach" round (WO-1.15.3 executed, 2026-08-27)

`WO-1.15.3-VERIFY-POC-REACH.md`, filed 2026-08-27 and executed the same day,
after 1.15.4 — so the round ships as **1.15.5** (no released 1.15.3 exists
and versions only move forward; the WO keeps its filed name). The checkup's
penciled "1.15.5 one-writer" round shifts to the next free number. Reserved
tests **77–79** land here, each verified RED against 9b1c792 first
(77: 28 red / 78: 12 red / 79: aborts on the missing script).

- **Item 1 — capability pre-flight (`pf_poc_capability`, lib-paff.sh):** the
  junction POC-lattice gate's verdict on a `pic_order_cnt_type != 0` source
  was knowable from a 40-frame head probe in seconds, yet its discovery cost
  the entire build (field-recorded: ~55 min mux + a 26-min whole-file output
  parse to a foregone UNPROVEN, exit 1, 24.8 GB `.part` kept). The head
  feature-probe is now captured once to a file and parsed for capability:
  `why=no_pictures` folds in the old "parsed no coded picture" refusal (now
  with the probe's rc — EMPTY ≠ ABSENT), `why=poc_type` is a new pre-flight
  refusal in the precondition voice, exit 3, nothing written, naming the
  manual route (`references/timeline-repair.md`) and the `auto.sh`
  consequence. **No bypass flag, deliberately** (1.15.2 Defect-B lesson) —
  and no attestation route either. `PCAP_MAXLSB` rides forward to the gate;
  two known SPS captures that disagree refuse loudly (a changed SPS across a
  `-c copy` indicts the source, not the gate). The census count-mismatch note
  now states its consequence (count guard WILL trip → UNPROVEN ceiling) —
  announced, not refused: that class has a legitimate multi-slice/non-VCL
  population and the duration gate still judges it. Machine row
  `PP_POC_CAPABILITY` (additive). Driver behavior per profile (Item 1 step
  6) decided and documented in `auto.sh`: the established fallbacks stand
  (PF_REORDER=no → flattening rebuild; reorder + derive signature → Rung
  3-DERIVE — neither POC-gated), the refusal guarantees only that pairfill
  itself writes nothing. Test 77 (unit lane on canned head logs +
  integration on the appendix fixtures; `PF_HEAD_TRACE_FILE` hook).
- **Item 2 — census-pass reuse (1.15.2 leftover 5.4):** `pf_trace_census`
  now emits the per-picture `idr,poc` table + SPS `log2_max` value as
  optional side files from the SAME whole-file pass (zero extra reads; the
  awk grew four token matches), and the gate builds its table as
  census-`idr,poc` ⨯ output-ffprobe-PTS — the output pays only its PTS list
  instead of the ~20-minute header re-parse. Soundness is measured, not
  argued: the gate's own extraction produced byte-identical tables across
  ts → `-c copy` → mov (appendix 2026-08-27; pinned by test 78's A/B). The
  license — copy-by-construction within the same run — is stated in the
  code; the direct-output extraction is factored (`pf_poc_extract`) and kept
  as the fallback arm. Cost model recorded in `references/knobs.md`.
- **Item 3 — `scripts/poc-gate.sh`:** playbook step 7's "re-run the gate
  against the `.part` standalone" now exists as a script (the field run had
  hand-sourced lib-paff.sh). Direct extraction + `pf_poc_lattice`, same
  human line and machine row; `--table CSV` judges a prepared table (the
  unit lane's entry point — test 76's tables drive it as-is); `--maxlsb N`
  explicit. Exit contract 0/1/**10**/2 — the 5.1 principle applied locally:
  standalone there is no bless decision, so UNPROVEN is honest REVIEW
  semantics (10), while inside pairfill the same verdict keeps exit 1 +
  retention. Companions: the UNPROVEN branch gained its machine row
  (`PP_POC_LATTICE unproven=1 why=… rows=… packets=…` — it previously
  printed nothing machine-readable) and both retention messages name the
  re-judge route. Test 79. **Considered and declined:** a `verify.sh --poc`
  flag — verify's contract is route-agnostic lowest-cost-conclusive, and the
  POC lattice is junction-specific and whole-file-parse expensive; a flag
  there invites running it where it proves nothing. Recorded here so it is
  not re-litigated.
- **Item 4 — `pic_order_cnt_type` 2 doctrine:** position 1 (pre-flight-
  announced UNPROVEN) shipped as the floor; position 2 shipped as a
  doctrine sentence in `references/timeline-repair.md`, explicitly labeled
  argument-not-measurement (type-2 lattice degenerates to a uniform ramp;
  the duration histogram is the operative evidence). Position 3 (POC
  reconstruction from `frame_num`, §8.2.1.3) **declined until a field case
  demands it** — spec-heavy code with no measured demand, and
  UNPROVEN ≠ FAILED already keeps the verdict honest. Type 1 stays
  UNPROVEN, honestly labeled by the same pre-flight (no fixture source on
  this bench: x264 emits only 0 and 2, measured).
- **Skipped, recorded (Item 1 fix 5):** the optional `/clean` capability
  line. `clean.sh` is the source clinic — report-only, source-domain, and
  its findings deliberately route timestamp-profile matters to
  `diagnose.sh` ("NOT clinic business"); the capability is a remux-rung
  evidence property that pairfill itself now announces at pre-flight before
  any cost, and `poc-gate.sh` covers the standalone ask. Adding it would
  also have introduced the clinic's first trace_headers probe for a fact
  the remux path surfaces for free.
- Docs: reach map in `pairfill-paff.sh`'s header + `timeline-repair.md`;
  `PP_CENSUS` / `PP_POC_CAPABILITY` / `PP_POC_LATTICE` rows added to
  SKILL.md's machine-lines table (PP_CENSUS emitted since 2026-08-18,
  tabled now); `poc-gate.sh` row in the task table; `PF_HEAD_TRACE_FILE`
  hook + the cost-models section in `knobs.md`. Suite 283/283; the
  1.15.2-Phase-5 leftovers 5.1/5.2/5.5/5.6 and the field follow-ups stay
  open and are restated in the WO's closing ledger.

## 1.15.4 — "EMPTY ≠ ABSENT" round (2026-08-27)

First round packaged by `CHECKUP-2026-08-27.md` (six-axis audit; findings
verified with measured repros) — the sites where a probe's EMPTY output was
read as a measured fact. The rule this round lands, twin of 1.15.2's
UNPROVEN ≠ FAILED: **no probe output feeds a verdict, a plan, or an
accusation without its exit status** (the `clean.sh` capture idiom,
`set +e; x=$(…); rc=$?; set -e`, at every touched site). Full scope +
leftovers: `WO-1.15.4-EMPTY-NE-ABSENT.md`. No released 1.15.3 exists —
`WO-1.15.3-VERIFY-POC-REACH.md` stays filed-unexecuted (its reserved test
numbers 77–79 are kept; this round's cases are 80–85).

- **A1 (the worst confirmed finding — silent false-bless):** one failed
  ffprobe (the audio-manifest query) shipped a silently audio-stripped MOV as
  ">> DONE … verified lossless", exit 0. The whole feeder family now fails
  CLOSED: `remux.sh`'s plan probe refuses exit 2; `probe.sh --kv` emits
  `PR_AUD_MANIFEST=failed` + exits 1 instead of fabricating
  `PR_AUD_COUNT=0` from its awk END block (which silently disabled the
  Dolby-E refusal loop at every eval site); the `mov.sh`/`auto.sh` eval
  sites capture the probe rc and refuse; `mov.sh`'s `--print-plan` consumer
  relays a failed plan instead of reading it as MODE=none ("no audio →
  pure copy"); `rebuild-paff.sh`'s audio census refuses instead of
  "rebuilding video only"; `verify.sh` gates (f)/(g) report a failed census
  as **UNPROVEN → REVIEW**, never "gate N/A" + OK. Test 80 (PATH-shim fault
  injection, the checkup-appendix recipe, plus fail-closed-not-fail-always
  negative controls).
- **C2:** `verify-source.sh` with an empty/invalid SOURCE baseline
  (`--src-tsh` empty file, failed scan) accused "backward DTS INTRODUCED
  (0 → N)" on a byte-identical copy. Now: "no source baseline — attribution
  UNPROVEN", one REVIEW, the four s_*-dependent comparisons skipped and the
  output counters printed unattributed. Test 81.
- **C3:** `verify.sh` gate (b) read empty-vs-empty hashes (tool failure —
  both `fhead` and the VCL branch end `|| true`) as "decoded frames differ /
  VCL MISMATCH — NOT a lossless copy". Accusations now require two NON-EMPTY
  differing hashes; empty is "could not decode — INCONCLUSIVE" REVIEW,
  mirroring gate (a) and the degraded-env arm. Test 81 (ffmpeg-shim
  injection + re-encode discrimination controls).
- **C4:** `ts-health.sh` on an unreadable input died at its first probe with
  zero output and exit 1 — the contract's DAMAGED. Now an announced
  pre-flight: "cannot read (ffprobe rc=N), NOT a damage verdict", exit 2;
  `clean.sh` propagates the child's 2 as 2 instead of relabeling it. Test 81.
- **C6 (+ the D4 fixture it was deferred for):** `verify.sh`'s `spo()` read
  ffprobe's `start_pts`/`time_base` by LINE NUMBER while ffprobe emits
  canonical order (measured: line 1 = time_base) — declared start_pts read 0
  unconditionally, the D4 "delta == declared start_pts, content aligned"
  branch (built for the 2026-08-15 field case) was dead code, and the report
  printed a false measurement inviting the exact "fix" the D4 comment warns
  against. Now parsed BY KEY; the branch is re-armed WITH its fixture: a
  minted dual-track MOV whose 4800-sample decode delta equals its declared
  start_pts reads "ALIGNED at offset 0 … not drift" → OK, and a
  non-matching offset still reads "NOT explained" → REVIEW. Test 82.
- **C7:** `mov.sh`'s bare builder calls died at a child's exit 10 —
  remux.sh's SANCTIONED REVIEW — skipping verify, playability, metadata,
  `MOV_SUMMARY`, the verdict line and trim custody (measured: rc=10,
  verify ran 0). Builders are now rc-captured: 10 continues into the gate
  battery with a REVIEW floor (an OK verify cannot outrank the child's own
  10); other codes announce, keep temp custody, and propagate unchanged.
  Test 83.
- **D1:** the confession hard-stop's frequency summary
  (`…| sort -rn | head -4`) SIGPIPEd its producer on large muxlogs and the
  ERR trap ate the "kept at $PART (log: $MUXLOG)" pointer — a mktemp path,
  unfindable without it (`remux.sh` + `pairfill-paff.sh`; `derive-dts.sh`
  was fixed in the one-liner round). The reader is now `awk 'NR<=4'` (reads
  to EOF). Test 84 reproduces with a 30k-line log — measured red pre-fix on
  this bench.
- **D2:** `verify.sh --full`'s whole-file decodes ran in statement position —
  a mid-decode failure was a SILENT exit 1 (no verdict line) that leaked the
  mktemp dir of framemd5 lists (~40 MB/occurrence). Both `--full` arms now
  capture per-decode rcs, print "FAILED mid-stream … INCONCLUSIVE (UNPROVEN,
  not FAILED)", land REVIEW, and clean up on every path. Siblings fixed the
  same way: `lead-check.sh`'s astats probe (announces, keeps
  `audio_hot=na`) and `qt-groups.sh`'s essence proofs (UNPROVEN — not
  blessed, evidence pointer intact; the empty-vs-empty accusation arm is
  unreachable for tool failures). Test 84.
- **C8:** `derive-dts.py` opened inputs at libav's stock 5 MB probesize
  against lib-probe.sh's "no call site can fall back to stock defaults"
  (measured on the repo's own late-sps.ts: PyAV saw 0x0). `rtm_open_options()`
  now plumbs `RTM_PROBESIZE`/`RTM_ANALYZEDURATION` (same 200M defaults,
  K/M/G parsed to plain integers) into both read-side `av.open` calls.
  Test 85 (unit lane, importlib — no PyAV needed) + a lockstep guard on the
  call sites.
- **A4 lockstep guard:** the one-liner round's broadened `mux_confessions`
  carried a "keep in lockstep" comment with no test — test 84 now asserts
  the two confession regexes byte-identical and pins the 4.4-era spellings.

One carried pin re-recorded, not weakened: test 12 §3's never-mask control
fed remux.sh a garbage input to provoke its mux-stage failure — with A1 an
unreadable input now refuses at the pre-flight (exit 2, nothing written,
still no retry line), so the pin records the new contract while the
property it guards (a non-probe-shaped failure is never retried, reported
once, writes nothing) is asserted unchanged.

Suite 280/280 on this bench (274 carried + tests 80–85, each verified RED
against a checkout of the pre-round commit); `claude plugin validate
--strict` green on plugin and marketplace.

## 1.15.2 — field-defects round (2026-08-27)

Four defects measured in the field on one live capture (2022-08-28 MTV VMA
satellite backhaul, 23.68 GB PAFF mpegts — `WO-1.15.2-FIELD-DEFECTS.md` holds
the full evidence; none was caught by the 1.15.1 suite). Every defect sat in
the honesty machinery — the gates that judge the work — never in the muxing:

- **Defect A (silent abort):** `rewrap_layout`'s `program=` probes died by
  SIGPIPE under `pipefail` (`ffprobe | head -1` — program= emits one line per
  program PLUS one blank per program_stream; head's early close is a race the
  field bench lost 5/5 at the 200M window). Killed `zero-base.sh` /
  `surgical-cut.sh` with exit 1 and zero diagnostic. Fix: `ffp1` in
  lib-probe.sh (awk reads to EOF, first non-empty line), both sites
  converted; test 73 pins the recovered values and greps the class.
- **Defect B (prediction contract):** the pre-pass ran `-f null -` +
  `-copyts` — a different mux than the build (field: predicted 0, observed
  11; the gate would have FAILED a fully-explained build). `rewrap_predict`
  is now a TRUE DRY RUN — the caller's own mpegts mux, layout opts included,
  bytes discarded; callers run `rewrap_layout` first and mirror extra build
  options through `RW_PREDICT_IN_OPTS`/`RW_PREDICT_OUT_OPTS`, which the build
  itself splices so the commands cannot drift. Test 74 pins predicted ==
  observed on a collision-bearing timeline (relationship, never a literal).
- **Item C (doctrine qualified + pre-flight):** the "TS→TS plain copy
  preserves the pair-timestamped PAFF shape" claim is scoped to its case
  file — the field source measured the opposite ('Timestamps are unset', the
  hard-stop class, after a full 23.68 GB build chasing 40 ms of cosmetic
  start_time). `zero-base.sh` now refuses pair-timestamped PAFF at
  pre-flight (exit 2, nothing built, `pairfill-paff.sh` named); test 75.
- **Defect D (POC-lattice false FAIL — regression vs the recorded proving
  job):** `pf_poc_lattice` never unwrapped `pic_order_cnt_lsb`, so any IDR
  sequence outliving one wrap period read as off-lattice — broadcast
  long-IDR open-GOP is the NORM (field: 24 sequences × ~73 wraps →
  3,179/451,071 on a provably correct build; 55 minutes to a false FAIL at
  the last gate). The gate now unwraps per ITU-T H.264 §8.2.1.1, preferring
  the SPS's `MaxPicOrderCntLsb` (captured in the same trace_headers pass)
  over per-sequence inference; the patched gate restores the proving job's
  451,071/451,071 on the same artifact and still fails a genuinely off-slot
  picture. Test 76 (the unit-test lane's first resident: pure CSV tables, no
  media). Git bisect: the unwrap never existed in-repo — the 2026-08-18
  proving figure came from the pre-extraction hand-run gate.
- **UNPROVEN ≠ FAILED:** the not-extractable POC branch now reports the gate
  UNPROVEN (still exit 1, still never blessed — but no longer an accusation
  against the artifact). Retained `.part` messages state the byte size and
  the delete command.
- **UX:** `mov.sh --audio-keep` on the PAFF path is rejected (exit 2) instead
  of silently ignored.

## 1.15.1 — topline-semantics round (2026-08-26)

Cross-ref against the live plugins reference (code.claude.com/docs/en/
plugins-reference + plugin-marketplaces, fetched 2026-08-26):

- **`$schema` added to both manifests** — the docs now name official schemas
  (`json.schemastore.org/claude-code-plugin-manifest.json` and
  `…/claude-code-marketplace.json`; both verified live, HTTP 200
  application/json). This REVERSES the 1.15.0 Phase-0 decision below, which
  was correct on its evidence at the time (no URL was then verifiable on
  this bench) — the reversal is recorded, not hidden.
- `description` tightened to the docs' "brief, concise for marketplace
  display" guidance (~360 chars, history pointed at CHANGELOG.md);
  marketplace entry description aligned to match.
- `displayName` → **"Remux to MOV & Source Clinic"** (free-form per docs,
  not used for lookup) — the picker now names both storeys.
- Marketplace entry enriched with the recognized optional fields
  (`displayName`, `author`, `homepage`, `repository`, `license`).
- **`name` kept as `remuxing-to-mov`, deliberately**: it keys
  `enabledPlugins`, the install identity, and the `/remuxing-to-mov:*`
  command namespace. The docs' `renames` map (v2.1.193+) makes a rename
  *possible*, but identity stability is house doctrine (machine lines never
  rename) and the name still names the plugin's center of gravity; the wider
  scope lives in displayName/description/keywords, the surfaces built for it.
- `claude plugin validate` passes clean (plugin `--strict` and the whole
  marketplace — entry-level plugin.json checks included).

## 1.15.0 — the source-clinic round (2026-08-26)

The storey below the ladder: integrity checks and corrections **to the source
file in its own container** (.ts/.mkv) — re-wrap, never remux, never in place,
never touching the original. Origin: the 2019-VMA `feed.ts` cleanup case file.

- **Phase 0 (the orphaned 1.14 Phase 6):** `CHANGELOG.md` (this file);
  `plugin.json` description shrunk to two sentences; `.bak`/`.DS_Store` strays
  removed; `allowed-tools` comma-separated in both SKILL frontmatters; CI
  resurrected at the monorepo root (the plugin-level workflow never ran there —
  GitHub only reads `.github/workflows/` at the repo root); `references/knobs.md`
  env-knob table; SKILL.md path-convention note (`scripts/…` resolves under
  `${CLAUDE_PLUGIN_ROOT}/skills/remuxing-to-mov/`). Decision recorded: no
  `$schema` added — no verified schema URL exists on this bench and no sibling
  plugin carries one; inventing an unverifiable URL fails house doctrine.
  **[REVERSED in 1.15.1, same day: the live docs name the official
  schemastore URLs; verified and added — see the 1.15.1 entry.]**
- **verify-source.sh** — the source-domain verification battery as a unit:
  filtered-reference streamhash (per-stream identity of a *cut* proven as
  rigorously as a straight copy), census arithmetic vs the plan, head/tail
  decode checks, duration arithmetic, and the nothing-unexplained gate.
  Closes the "no lossless-identity prover for non-MOV outputs" hole
  (known-limits: verify.sh gate (d) is QTFF-shaped by design).
- **clock.sh** — the player-clock translator: player-clock time = container
  time − `format.start_time`; translates a "video starts at X" report into a
  raw timestamp address with bracketing keyframes and per-frame luma means.
- **zero-base.sh** — Tier-1 structural re-wrap: mpegts timeline zero-base
  (`-muxdelay 0 -muxpreload 0`) with PID/program layout preserved, the
  minimum-start floor stated up front (first-frame reorder delay; exact 0 is
  impossible with B-frames without inventing timing), and a null-muxer
  prediction pre-pass whose expected artifact set (equal-DTS +1-tick nudges)
  is announced before the build and reconciled after it.
- **lead-check.sh** — black-lead detection: luma-mean sweep + keyframe map +
  H.264 NAL-type census (IDR vs open-GOP I) + audio level across the candidate
  splice; names the exact cut address and what a cut would discard.
- **surgical-cut.sh** — the sanctioned non-IDR cut on MPEG-TS: deterministic
  packet selection (`noise=drop=` by video packet index / audio PTS,
  `-copyts` + `-output_ts_offset`, no seeking — both `-ss` forms are
  measured-unreliable on TS), leading-B rule applied, PID layout preserved.
  **Tier 2 consent:** refuses without `--discard-content` and prints the exact
  decodable-media loss statement.
- **dim-scan.sh** — whole-file frame-dimension sweep; the mid-stream
  SPS/resolution-change named limitation gains its detection half.
- **clean.sh + `/remuxing-to-mov:clean`** — the clinic driver: cheapest-first
  analysis battery, findings where every route stays in the source container,
  Tier-1 offered / Tier-2 named for the operator.
- Recorded candidates (named, not built): `wrap-split.sh` (≥2-wrap horizon),
  `derive-dts.sh --container mkv` (same-container MKV lane), bars-and-tone
  lead detection.
- **First-ever CI run, and what it taught (2026-08-26):** the resurrected
  workflow's maiden run failed on every leg — none of it from this round's
  code. Test 61 (1.14) had pinned exact decoder-chatter counts measured on
  the macOS bench ("2 decode lines") that Linux static builds count
  differently — re-pinned as build-measured *relationships* (count registers
  and equals the most-forgiving candidate at delta 0; decisive delta positive),
  never as constants. The ms-timebase alternation pin is now gated on the
  fixture's own minted shape (ffmpeg 6.1/7.1 mint it with uniform durations —
  nothing to preserve there, announced skip). And the **4.4 matrix leg was
  dropped: the supported floor is 6.1** — 4.4 failed 20 assertions across a
  dozen sub-suites because that 2021 build predates surfaces the plugin
  legitimately depends on; below the floor the claims are benched for, green
  would have meant papering over, not proving. One real behavioral finding
  came out of the same run: **ffmpeg 6.1/7.1 movenc rounds a ms-quantized
  source's alternating 41/42 ms deltas into a uniform duration table on a
  `--timescale` remux** — the C68 "alternation survives, source-baked, not
  smoothed" claim holds on ≥8.x only, and the suite now says so per version
  instead of asserting one bench's truth everywhere.

## 1.14.0 — the reorder-DTS round (2026-08-16..24)

The 54.6 GB 2023-VMA MKV incident: reordered field-coded H.264 in a DTS-less
container — ffmpeg reconstructs DTS with a frame-unit reorder depth applied as
a packet delay, short by exactly 2× on field packets. Essentially every 1080i
North-American HD feed muxed to MKV.

- **Rung 3-DERIVE (`derive-dts.sh` + vendored `derive-dts.py`, PyAV):**
  whole-file DTS derivation from the sorted PTS column (DTS[i] = (i−D)-th
  smallest PTS) — codec-agnostic, packets copied byte-for-byte; refuses outside
  its signature (exit 3, family-consistent); `--force` as announced operator
  override; attested precondition overrides via `lib-attest.sh`.
- **Measure right:** unit-aware reorder depth (`PF_DEPTH_*`, `PF_PPF`,
  `PF_DTS_SOURCE=carried|reconstructed` with printer annotations); both
  coded-rate ratio hypotheses tested and announced; modal sorted-PTS delta
  coded rate; presentation-order gap census (`DISC_P_*`) carries every
  dropped-time claim (the ~1000× overstatement fix).
- **Judge right:** `mux_census` three-verdict (missing=FAIL / expected
  surplus=announced PASS / unexpected surplus=REVIEW, never "missing");
  mux-confessions split video (hard stop verbatim) vs audio/subtitle nudges
  (announced REVIEW); gate (g) source-baseline subtraction.
- **Route right:** rungs chosen by measured profile, every verdict printing the
  measurements that drove it; junction fill model + POC-lattice gate in
  pairfill (max-run-2 displaced-timestamp class).

## 1.13.0 — the container axis (2026-08-15)

- **Rung 3-SWAP (`mp4-swap.sh`):** the same MPEG-2 4:2:2 bitstream AVFoundation
  destroys as `.mov` (`m2v1`+`glbl`) renders correctly as `.mp4` (`mp4v`+`esds`)
  — SSIM 0.9175+ on the exact failing timestamps, where all five MOV retags
  corrupted identically (movenc writes one generic sample-description body for
  every MPEG-2 fourcc). A fidelity FAIL routes here before Rung 4, ever.
- **Post-mux census (`RMX_CENSUS`)** at every mux site — ffmpeg was measured
  dropping 1 of 3 mapped streams at `-v warning`, silently, shipping green.
- **Scan-keyed fidelity:** 0.90 was progressive-tuned and false-FAILed healthy
  interlaced material; interlaced judged at 0.86 with per-plane Y/U/V split
  (the deficit is chroma-plane — field normalization measured and rejected).
- Audio gate corrected both directions: `ipcm` allowlisted; allowlist demoted
  from verdict to prior (off-list tags get the decode probe); MP2 with no PCM
  access track finally REVIEWs. Extension-keeping part files (`x.part.mov`).

## 1.12.0 — fidelity storey (2026-08-15)

- `playable-check.sh --fidelity`: renders ≠ renders correctly — bounded
  avconvert ProRes windows SSIM-compared against the ffmpeg reference decode.
- m2v1→xd5* decoder-dispatch retag advisory (advisory-only; auto-apply
  deferred pending bench). Movie-timescale overflow truth (2^31-tick warning
  onset; geometry-gated silent chapter-track drop past 2^32, warning
  suppressed on exactly the dangerous geometries — pre-announced).
- Post-hoc gap-collapse repair route for an already-collapsed MOV.

## 1.11.0 — keep-all audio, evidence-demoted gates (2026-08-13/14)

- `--audio-keep all` default (dropping buys no playability — TN3177); per-track
  `--audio auto`; DRC `-drc_scale 0` default on AC-3/E-AC-3 decodes.
- The categorical 4:2:2 refusal **falsified on macOS 26.6.1** and demoted to
  announce + build + post-build empirical playability proof. Backhaul timeline
  rot demoted from refusal to warn+build (the measured gates judge the artifact).
- VC-1/VP9/AV1 video and Dolby E audio refused pre-flight with routes (exit 11,
  `MOV_REFUSED`) at every entry point. `pcm_bluray`/`pcm_dvd` routed to PCM
  access (the copy-muxed HDMV track is undecodable). Mid-GOP starts auto-trimmed
  (`trim-to-idr.sh`). 200M probe windows with announced 1G retry. SOURCE DAMAGED
  keyed to transport evidence, never decode noise.

## 1.10.0 — backhaul gate at every entry point (2026-08-01)

- The 1.8.0 refusal gate enforced at every `.mov`-writing entry point (closed
  after a direct build produced a doomed 2017-feed MOV the front door would
  have refused).

## 1.9.0 — H.264 High 4:2:2 (2026-07-31)

- QT-undecodable gate widened to H.264 High 4:2:2 (both classes later
  re-measured and demoted in 1.11.0 — the registry records the reversal).

## 1.8.0 — ts-health (2026-07-30)

- `ts-health.sh` one-command capture scan (transport loss, missing timestamps,
  DTS rot, forward gaps, 33-bit PTS wrap, mid-GOP start, single-GOP,
  audio drift — every finding routed). Backhaul refusal gate (since demoted).
  `verify.sh --silence` content parity (the ~17-min injected-silence class).

## 1.7.0 — QTFF audit round 5 complete (2026-07-26)

- `rung4.sh` — the only sanctioned re-encode path (verbatim operator
  attestation + mdta provenance); verify.sh master-purity scan; waiver
  sidecars (`waiver.sh`); track-set-aware audio policy; Tahoe decode-set
  drift documented; ms-timebase doctrine.

## 1.6.0 — QTFF spec audit rounds 1–4 (2026-07-26)

- 62-claim registry (`qtff-claims.md`) with dated verdicts; pairfill
  boundedness gates; `--signaling` pasp check; VFR-safe duration gate.

## 1.5.0 — post-mortem teeth (2026-07-25)

- The pair-timestamped PAFF class (PES timestamps only on the first field of
  each pair; a straight copy makes the MOV muxer INVENT timing): `pairfill-paff.sh`
  keeps every real PTS; `rebuild-paff.sh` refuses reordered streams; the
  muxer-confession hard stop; whole-file output-timeline gate (d); scrub gate.

## 1.4.0 (2026-07-24)

- `/mov` one-command shortcut; discontinuity resync (`resync.sh`); E-AC-3
  recognized QT-native (copied single-track); opt-in QuickTime `mdta` metadata
  (`metadata.sh`); capability doctor (`doctor.sh`).

## 1.1.0 (2026-07-23)

- `/mov` command added; verify decode check hardened.

## 1.0.0 (2026-07-22)

- Initial release: lossless-first remux ladder, dual-track audio deliverable,
  verification gates, references.

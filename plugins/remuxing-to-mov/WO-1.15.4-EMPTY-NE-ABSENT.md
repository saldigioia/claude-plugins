# 1.15.4 Work Order — "EMPTY ≠ ABSENT"

> **Status (2026-08-27): FILED and EXECUTED the same session.** This is the
> first round packaged by CHECKUP-2026-08-27.md ("Suggested round packaging"):
> the sites where a probe's empty output is read as a measured fact — a plan,
> a verdict, or an accusation built on evidence that was never collected. The
> scope is the checkup's, verbatim: **A1** (audio plan fails open, plus its
> whole feeder family), **C2** (verify-source manufactures "INTRODUCED"),
> **C3** (gate (b) empty-vs-empty reads "frames differ"), **C4** (ts-health
> dies silently with the DAMAGED code), **C6** (`spo()` field order — deferred
> from the one-liner round because it re-arms the dead D4 branch; lands here
> WITH the D4 fixture), **C7** (mov.sh dies at a child's sanctioned REVIEW
> exit 10), **D1** (the confession hard-stop report SIGPIPEs away the
> `Kept:` pointer), **D2** (`--full` mid-decode failure is a silent exit-1 +
> mktemp leak; siblings lead-check/qt-groups), **C8** (derive-dts.py opens at
> stock 5 MB probesize). Nothing else — 1.15.5 (one writer), 1.15.6
> (jurisdiction), the harness round and the docs round are later; WO-1.15.3
> stays filed-unexecuted and keeps its reserved test numbers 77–79 (this
> round's cases start at **80**).
>
> **The rule this round lands, twin of 1.15.2's UNPROVEN ≠ FAILED:**
> **EMPTY ≠ ABSENT — no probe output feeds a verdict, a plan, or an
> accusation without its exit status.** The house idiom is `clean.sh:45`:
> `set +e; x=$(…); rc=$?; set -e` and then an explicit refusal/announcement
> on `rc != 0` or a missing sentinel key. "The probe returned nothing" must
> route to *refuse* (builders/pre-flight), *UNPROVEN → REVIEW* (verify
> gates), or *"no baseline"* (comparisons) — never to "the property is
> absent" and never to a confident accusation.
>
> Every line number below was re-verified against the working tree at commit
> 42eb9e1 (post one-liner round) before filing; match on the quoted text, not
> the number. Every claim relied on was re-measured on this bench
> (ffmpeg/ffprobe 9.0.1, macOS Darwin 25.6.0) — the C6 field-order swap and
> the D4 fixture recipe were re-measured this session (transcript below).

**Bench:** ffmpeg/ffprobe 9.0.1 (libx264 present), macOS (Darwin 25.6.0),
zsh, APFS. Paths `scripts/…` mean
`plugins/remuxing-to-mov/skills/remuxing-to-mov/scripts/…`; the suite is
`bash tests/regression.sh` from `skills/remuxing-to-mov/` (274/274 green at
filing). New cases enroll in `tests/regression.d/` **with mode 755** (the
harness silently un-enrolls 644 — checkup E1; the exec bit is part of the
deliverable).

---

## Item A1 — the audio plan must fail CLOSED (refuse, never bless)

The measured end-to-end failure: one failed ffprobe (the audio-manifest query)
ships a silently audio-stripped MOV as ">> DONE … verified lossless", exit 0.
Every feeder in the family conflates "probe failed" with "no audio":

1. **`remux.sh:135`** — `PLAN=$(ffp … -select_streams a … | awk …) || true`.
   Fix: house-idiom capture of the ffprobe pass *separately from* the awk
   selection. `rc != 0` ⇒ refuse, exit 2 (pre-flight, nothing written), with
   the probe's stderr shown. A genuinely audio-free source still probes rc=0
   with empty output and still plans `audio: none`.
2. **`probe.sh:23` `aud_manifest_kv`** — the awk END block fabricates
   `PR_AUD_COUNT=0` even when its producer failed (measured: probe exits 1,
   36 keys still emitted, the Dolby-E refusal loop silently disabled). Fix:
   capture the producer; on failure emit `PR_AUD_MANIFEST=failed` (additive
   key), do NOT emit `PR_AUD_COUNT`, and return 1 so `--kv` exits 1.
3. **`mov.sh:175` and `mov.sh:426`, `auto.sh:70`** — `eval "$(probe.sh --kv |
   grep …)"` discards probe.sh's exit status. Fix: house-idiom capture; refuse
   (exit 2) when rc != 0 **or** the output lacks a `PR_AUD_COUNT=` line — the
   audio classifier and the Dolby-E refusal loop must never run on a
   fabricated zero.
4. **`mov.sh:500`** — `PLANOUT=$(bash remux.sh … --print-plan 2>&1 || true)`.
   A failed plan (exit 2/11/1) currently yields KEPT="" ⇒ `MODE=none` ⇒
   "-- no audio (or none kept) -> pure copy --". Fix: capture rc; on rc != 0
   or a missing `RMX_PLAN ` row, print the plan output (the refusal voice
   must reach the operator) and exit with the child's own contract code
   (11 stays 11, 2 stays 2, else 1).
5. **`rebuild-paff.sh:101`** — `NA=$(ffp … | sort -u | grep -c . || true)`:
   probe failure ⇒ NA=0 ⇒ "note: no audio streams found; rebuilding video
   only". Fix: house-idiom capture, refuse exit 2 on probe failure.
6. **`verify.sh:407` (gate f) and `verify.sh:558/562` (gate g)** — the audio
   census `| sort -u | grep -c . || true` reads a failed probe as "no audio
   tracks — gate N/A" and disarms both gates. Fix: capture the census output
   + rc once per gate; on rc != 0 the gate is **UNPROVEN**: announced, REVIEW
   (never FAIL — the artifact is not indicted; never a silent N/A). Count
   with awk (`NF`), not `grep -c` (whose rc-1-on-zero is what bred `|| true`).

Exit-code note: the refusals are 2 (usage/pre-flight — could not even read
the source; nothing written), consistent with C4 below.

## Item C2 — verify-source: no baseline ⇒ "no baseline", never "INTRODUCED"

`verify-source.sh:251–254` guards the OUTPUT ts-health scan against emptiness
but not the SOURCE scan (and `--src-tsh` accepts an empty file); every
`${s_back:-0}` then reads 0 and `:263–275` accuses "backward DTS INTRODUCED
(0 -> N)" on an identical copy. Fix: validate the baseline (non-empty AND
carries `TSH_VERDICT=`); when invalid, announce **"no source baseline —
inherited-vs-introduced attribution UNPROVEN"**, downgrade REVIEW once, and
skip the four comparisons that need the s_* counters (back/dup/gaps/wrap; the
output's absolute counters still print, unattributed). The live scan's rc is
captured and named in the message. The S_P_* rows come from verify-source's
own packet scan, not ts-health, and keep their existing comparisons.

## Item C3 — verify.sh gate (b): empty-vs-empty is "could not decode"

`verify.sh:166–174` (`fhead` ends `|| true`; empty==empty falls into "decoded
frames differ; output is NOT a lossless copy", FAIL) and the symmetric VCL
branch `:145–154` (`sv`/`ov` empty ⇒ "VCL MISMATCH — slice data differs").
Fix: an empty hash on either side is *no evidence* — print which side
produced nothing, verdict REVIEW ("cannot cheaply prove lossless — could not
decode/hash"), mirroring gate (a)'s "inconclusive" and the degraded-env arm.
The accusation arms are reached only on two NON-EMPTY differing hashes.

## Item C4 — ts-health: unreadable input says so, exit 2

`ts-health.sh:64` — the first failing assignment under `set -e` exits 1 with
zero output, and 1 is the contract's DAMAGED. Fix: the first probe (format
container) becomes an announced pre-flight: house-idiom capture via `ffp1`
(SIGPIPE-safe), on failure print "cannot read (ffprobe rc=N)" + the probe's
stderr and **exit 2**; the header comment gains the pre-flight meaning of 2.
Consumers: `clean.sh:46/57` currently relabel any probe/scan failure exit 1
(= DAMAGED per its own contract) — both guards now propagate a child rc 2 as
exit 2 (pre-flight), keeping 1 for real scan failures.

## Item C6 — `spo()` field order, landed WITH the D4 fixture + test

`verify.sh:1198–1204`: ffprobe emits stream fields in canonical order —
re-measured this session: line 1 is `time_base`, line 2 is `start_pts` — so
the awk reads them swapped and `split(start_pts,"/")[2]==""` forces `print 0`
unconditionally: the D4 "delta == declared start_pts, content aligned" branch
(built for the 2026-08-15 field case) is dead code and the report prints a
false measurement. Fix: parse by KEY (`-of default=nw=1`, match
`^start_pts=` / `^time_base=`) — the same ffprobe-order trap the codebase
already documents at `metadata.sh` (canonical-order note) and remux.sh:277.
Deferred from the one-liner round BECAUSE it re-arms a verdict branch with
zero coverage; it therefore lands with the D4 fixture, re-measured this
session and mintable deterministically:

```
# src.mov: v(h264 2s) + a:0 pcm_s16le 96000 samples
# out.mov: v copy + a:0 = first 91200 samples, -itsoffset 0.1 (=4800 samples)
#          + a:1 = bit-exact copy of src a:0
# measured: a:0 start_pts=4800, decode delta 4800 samples == declared offset
# pre-fix verify --audio: "declared start_pts a:0=0 a:1=0 … NOT explained" REVIEW
# post-fix: "= the declared start_pts DELTA … ALIGNED at offset 0" >> OK
```

The test carries a NEGATIVE control (offset ≠ delta must STILL read "NOT
explained" REVIEW) so the re-armed branch cannot degrade into always-pass.

## Item C7 — mov.sh survives a child's exit 10 (sanctioned REVIEW)

`mov.sh:533–565` — bare builder calls under `set -e`; `lib-exit.sh` passes a
child's 10 through, so remux.sh's REVIEW (whose own text says "verify gates
(f)/(g) judge audio. Building on; exit will say 10") kills the driver at the
call site: no verify, no playability check, no metadata, no MOV_SUMMARY, no
verdict, `trim_cleanup` skipped (measured via RTM_MUX_LOG_APPEND: remux
direct rc=10 correct; through mov.sh rc=10 with `verify ran: 0`). Fix:
house-idiom capture around every builder in the MODE case. rc==10 ⇒ announce
and continue into verify with a REVIEW floor on the final verdict (an OK
verify cannot outrank the builder's own 10); rc ∉ {0,10} ⇒ announce, run
`trim_cleanup`, exit with the child's contract code unchanged (11/2/1
propagate as themselves — behavior identical to today, now with the
announcement and the temp-custody message).

## Item D1 — the confession hard-stop report must not eat the `Kept:` pointer

`remux.sh:436` and `pairfill-paff.sh:370` — the
`grep | sort | uniq -c | sort -rn | head -4` frequency summary over a large
muxlog: `head -4`'s early close SIGPIPEs the producer above ~64 KB, pipefail
+ ERR-trap exit AFTER the summary but BEFORE the `Kept: $PART (log: $MUXLOG)`
echo — and MUXLOG is a mktemp path, unfindable without the pointer. Fix:
replace the early-exit reader with `awk 'NR<=4'` (reads to EOF — the ffp1
doctrine applied to a display pipeline) + a `|| true` belt (pure display; the
verdict was already decided by the confession counter). `derive-dts.sh:218`
is the already-fixed pattern reference (grep -m4 — that site has no
frequency summary to preserve; these two do, so the EOF-reader form is used).

## Item D2 — `--full` mid-decode failure: diagnostic, REVIEW, no leak

`verify.sh:1041–1044` — `hlist "$SRC" > "$HLD/s"` in statement position:
a mid-decode failure (stderr already /dev/null'd) is a silent ERR exit;
`rm -rf "$HLD"` never runs (~40 MB of framemd5 lists per occurrence). Fix:
capture each hlist's rc; on failure print "--full decode FAILED mid-stream
(src rc=…, out rc=…) — presentation-order check INCONCLUSIVE (UNPROVEN, not
FAILED)", verdict REVIEW, and `rm -rf "$HLD"` on every path. The non-H.264
`fmd5` arm (`:1070–1071`) has the identical statement-position exposure and
gets the identical capture (same finding, other branch of the same gate).
Siblings, same shape, same round per the checkup: `lead-check.sh:150` (the
astats probe — on failure announce "audio probe failed mid-decode (rc=N)"
and keep `audio_hot=na`, never a silent exit 1) and `qt-groups.sh:290–299`
(the essence-hash proofs — capture rc; on rc != 0 or empty output print
"proof could not run: ffmpeg failed mid-decode (rc=N). UNPROVEN — not
blessing. Evidence kept at $PART" and exit 1 with the pointer intact; the
empty-vs-empty `[ -n "$V_IN" ]` accusation arm becomes unreachable for the
tool-failure class).

## Item C8 — derive-dts.py inherits the probe-window floor

`derive-dts.py:131,176` — `av.open(src)` with no options, stock 5 MB
probesize, vs `lib-probe.sh:2–4` ("no call site can fall back to stock
defaults"); measured on the repo's own late-sps.ts: PyAV sees 0x0 where the
plugin floor reads 1280x720. Fix: a pure helper `rtm_open_options()` reads
`RTM_PROBESIZE`/`RTM_ANALYZEDURATION` (same defaults, 200M/200M; K/M/G
suffixes parsed to plain integers so no libav string-parsing assumption is
made) and both READ-side `av.open` calls pass `options=rtm_open_options()`.
The helper is PyAV-free (unit lane, importlib — the test-63 pattern); a
lockstep guard pins that every read-side `av.open(src` in the file carries
the options (the confession-regex lockstep discipline).

## A4 lockstep guard (fix already landed in the one-liner round)

The `mux_confessions` broadening shipped 2026-08-27 with a "keep the two
patterns in lockstep" comment and no guard — the exact comment-rot class the
1.15.2 provenance trap names. A test now extracts both regexes from
`lib-paff.sh` and asserts they are byte-identical, and asserts
`mux_confessions` counts the 4.4-era spellings ("Non-monotonous DTS",
"non monotonically increasing dts") a canned log carries.

---

## Tests (all red on the pre-fix tree; 77–79 stay reserved for WO-1.15.3)

- **`80-empty-ne-absent-audio-plan.sh`** (A1) — PATH shim failing ONLY the
  audio-manifest query shape (the checkup's appendix recipe):
  remux.sh refuses exit 2, nothing written; mov.sh end-to-end refuses (never
  ">> DONE" + audio-stripped output); probe.sh --kv emits no fabricated
  `PR_AUD_COUNT=0` and exits nonzero; auto.sh refuses; rebuild-paff (audio
  census shim) refuses exit 2 instead of "rebuilding video only"; verify.sh
  (f)/(g) census shim ⇒ UNPROVEN + REVIEW, never "gate N/A" + OK. PLANOUT
  guard: mov.sh with a bad `--audio-keep 5` never prints the false
  "no audio (or none kept)" banner — the plan's own refusal is relayed.
  Negative controls: unshimmed audio-free source still plans `audio: none`
  and builds; unshimmed audio source still builds identically.
- **`81-empty-ne-absent-verdicts.sh`** (C2/C3/C4) — C4: garbage input ⇒
  exit 2 + "cannot read", never a silent 1/DAMAGED (clean.sh propagates 2).
  C2: byte-identical rot.ts copy + `--src-tsh empty` ⇒ "no source baseline"
  REVIEW, never "INTRODUCED" FAIL; control with a real baseline stays
  inherited. C3: unreadable pair ⇒ gate (b) "could not decode", a verdict
  line is reached, and no "NOT a lossless copy" accusation; VCL variant
  (h264 source vs garbage output) ⇒ REVIEW not "VCL MISMATCH" FAIL.
- **`82-c6-d4-start-pts.sh`** (C6+D4) — the fixture above: post-fix prints
  the true `declared start_pts a:0=4800` and the D4 "ALIGNED at offset 0"
  arm with ">> OK"; negative control (offset 2880 ≠ delta 4800) still
  "NOT explained" REVIEW.
- **`83-c7-mov-review-passthrough.sh`** (C7) — an `[aost#…] Non-monotonic
  DTS` confession log via RTM_MUX_LOG_APPEND drives remux.sh to its
  sanctioned 10 through mov.sh: rc=10 AND verify ran AND MOV_SUMMARY AND the
  ">> REVIEW" verdict line all present; an OK-verifying build with a
  builder-10 still floors at 10.
- **`84-d1-d2-evidence-loss.sh`** (D1/D2/A4-lockstep) — D1: a 30k-line
  video-confession muxlog through remux.sh's hard stop must keep the
  `Kept: … (log: …)` pointer; class guard: no confession-report pipeline in
  scripts/ pipes its summary into `head` any more. D2: verify --full against
  a truncated output prints the INCONCLUSIVE diagnostic, reaches a verdict,
  and leaks nothing under a private TMPDIR; class guards pin the lead-check
  and qt-groups captures. A4: the two confession regexes in lib-paff.sh are
  byte-identical and the narrow copy counts the 4.4-era spellings.
- **`85-c8-py-probe-floor.sh`** (C8) — unit lane: importlib
  `rtm_open_options()` (defaults 200M/200M ⇒ 200000000; RTM_PROBESIZE=5M ⇒
  5000000; bad values fall back to the floor, never to stock); lockstep
  guard on the read-side `av.open` call sites.

## Rules of engagement (from the kickoff, restated as executed)

- EMPTY ≠ ABSENT at every touched site; the `clean.sh:45` idiom is the shape.
- Every fix ships with a red-first test; repro recipes are the checkup
  appendix's. Relationships pinned, never bench literals.
- Gate: full `bash tests/regression.sh` green AND
  `claude plugin validate --strict` green; version 1.15.4 + CHANGELOG entry;
  provenance comments name CHECKUP-2026-08-27 + this WO.
- No scope expansion into 1.15.5/1.15.6/harness/docs — temptations recorded
  below instead.

## Leftovers — adjacent findings seen and deliberately NOT taken

- **verify.sh `--silence` (`:961` nao) and `--audio` (`:1127` na)** carry the
  same failed-census-reads-as-no-audio shape as gate (f)/(g); opt-in gates,
  same one-line idiom — next verify-side round.
- **verify.sh gate (f) `vdur`/`sdur`** (`:406`) reads an empty video-duration
  probe as "no stream durations — N/A"; same family, untouched here.
- **derive-dts.sh gate 3 phash** (`:282–291`) has the C3 empty-vs-empty shape
  ("PACKET-HASH GATE FAILED" on two empty hashes) — with the C3 rule now
  written, that site should take the same inconclusive arm in a later round.
- **`dim-scan.sh:62`** — D1's assignment-position sibling (checkup:
  SUSPECTED, needs a ~1900-CHANGE-line scan) — untouched.
- **D3's 55-site `ffp1` sweep** — its own round with a grep-guard test.
- **clean.sh displays an empty `audio_tracks=` when probe.sh omits the count**
  — cosmetic; the guard above it already refuses rc != 0.
- **batch.sh ledger classification of the new exit-2 refusals** — batch
  records the child code; whether "cannot probe" deserves its own ledger
  column is a batch-round question.
- **WO-1.15.3 test numbering** — 77–79 remain reserved; its E6 injection
  seam is untouched.
- **D1 siblings in DISPLAY position elsewhere** — `ts-health.sh` (transport
  summary), `probe.sh` (`ms_tb_scan`'s duration histogram) and `diagnose.sh`
  each still end a `uniq -c | sort -rn | head` display pipeline in an
  early-exit reader; none sits on a failure path that loses a mktemp
  pointer, so they stay with `dim-scan.sh:62` in the sibling ledger. The
  test-84 class guard is deliberately scoped to the two confession sites.

## Execution record (2026-08-27, this bench)

- All nine scope items landed as specified above; no scope was added.
- Tests 80–85 shipped mode 755 (checkup E1) and were each run against a
  `git archive HEAD` checkout of the pre-round commit (42eb9e1): **80** red
  21/28 (including the measured worst — ">> DONE … verified lossless" over
  an audio-stripped output), **81** red 14/19, **82** red 6/10, **83** red
  4/11, **84** red 11/16 (the 30k-line SIGPIPE and the leaked `tmp.*/s`
  both reproduced), **85** red 3/3. All green on the fixed tree.
- **One deviation, recorded:** test 12 §3 (probe-retry's never-mask control)
  pinned the OLD behavior of a garbage input — mux-stage "mux FAILED" rc 1 —
  which A1's pre-flight now intercepts as REFUSED exit 2, nothing written.
  The pin was re-recorded to the new contract; the property it guards (no
  retry on a non-probe-shaped failure; honest single report; nothing
  written) is asserted unchanged. This is the C4/A1 rule applied to the
  suite's own fixture, not a weakening.
- **Measurement notes:** macOS `mktemp -d` (no template) ignores TMPDIR
  (measured — it uses the darwin per-user temp dir), so test 84's leak watch
  marks time and sweeps `getconf DARWIN_USER_TEMP_DIR` for a fresh
  `tmp.*/s`; a truncated faststart MOV decodes to a clean EOF (ffmpeg rc 0),
  so the D2 injection is an ffmpeg shim that emits real framemd5 output and
  then exits 1 — the true "I/O error at 90%" shape.
- Gate: full `bash tests/regression.sh` **280/280** (274 carried + 6 new
  cases), `claude plugin validate --strict` green on the plugin and the
  marketplace. Version 1.15.4; CHANGELOG entry in house style; every edit
  carries a provenance comment naming CHECKUP-2026-08-27 + this WO.

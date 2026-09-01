# Research — the 25-minute clean remux (everyday-path cost, 2026-08-31)

> **Status: implemented in 1.18.0** (same day). Taken: A (identity settle,
> with B folded into it — the count/column compare subsumes the arithmetic
> check on the copy path), D (verdict semantics), F (remedy ordering + the
> budget-REVIEW-is-reportable rule, in verify.sh, FAST PATH, and /mov), G's
> cost-model paragraph, K's prose. **J dropped deliberately** — the settle
> *measures* copy-ness instead of trusting a caller-declared rung class
> (never trust a claim you can measure). **I descoped**: a `--settle`
> ledger-resume needs restructuring the verify monolith; `poc-gate.sh`
> already settles (k) standalone, and with the identity settle the
> budget-REVIEW mostly disappears. C, E, H remain recorded candidates.
> Test: `tests/regression.d/120-struct-budget-identity.sh`. Details in
> CHANGELOG 1.18.0.

**The incident.** `/remuxing-to-mov:mov video.mp4 video.mov` — 5.15 GB, 75:33,
H.264 + AAC, probe clean, no PAFF, pure Rung-0 copy. The mux completed cleanly,
census matched, gate (a) proved the video bit-identical — and the job still ran
**25+ minutes**, ending in a whole-file `trace_headers` parse *and* a whole-file
double decode of a file nothing had accused of anything.

This document reconstructs where the time went, names the root causes, and
lists every option considered. It is the follow-on to 1.17.1 (FAST PATH /
diagnosis gating) and 1.17.2 (disk-gate conversion): those fixed the
*pre-flight* half of the over-work; this is the *post-build* half.

---

## 1. Where the 25 minutes went

| Phase | What ran | Cost class | Est. on this file |
|---|---|---|---|
| Probe + pre-flights | `probe.sh --kv`, mid-GOP head scan | head reads | seconds |
| Mux | `-c copy` + in-place faststart relocation | 2× write I/O (measured 19 s / 3.93 GiB, 2026-08-29) | ~1–2 min |
| Verify, default tier | (a) streamhash ×2 sides, (b) VCL hash ×2, (d) packet list + disc_scan, (e)–(g), (i), (j), (l) | **~6 whole-file demux passes** | ~2–5 min |
| Gates (h)/(k) | **DECLINED ON BUDGET** (5.15 GB > 4 GiB `RTM_STRUCT_MAX_BYTES`) → UNPROVEN → **verdict forced to REVIEW (exit 10)** | free — but poisons the verdict | 0 |
| Session settles (k) | `poc-gate.sh` — whole-file `trace_headers` parse | CPU-bound header parse (measured ~20 min / 24 GB class, `lib-paff.sh`) | ~4 min |
| Session settles the rest | `verify.sh --full` — whole-file decode, both sides | full double decode of 75 min of video | ~10–15 min |
| Session overhead | sleep-polling wait loops between each step | wall time | minutes |

The mux plus the cheap tier — the actual *job* — was done inside ~5 minutes.
Everything after was verdict-driven.

## 2. Root causes, ranked

**R1 — Gates (h)/(k) are class-blind, and their budget-decline forces REVIEW.**
The container-declaration tier was born from the 2026-08-29 post-mortem: two
builds bit-identical to source and unusable (one MOV sample per coded FIELD;
a `.mp3` entry over Layer II). Both defects were authored by **timeline-repair
writers or a broken-timestamp mux** — not by a Rung-0 copy of a healthy
MP4-family source. Yet (h)/(k) are owed identically on every H.264 QTFF
output, and above 4 GiB they decline → UNPROVEN → REVIEW (verify.sh:1358).
Consequence: **every clean H.264 `.mov` over 4 GiB exits 10 on the everyday
path.** Bigger file ⇒ more suspicion ⇒ more work, with no finding anywhere.

**R2 — The decline text prescribes the most expensive remedy.** The printed
settle is `verify.sh SRC OUT --full` (or `RTM_STRUCT_MAX_BYTES=0`), i.e. the
whole-file parse or the whole-file double decode — the very thing SKILL.md
says never to default to. A session that obeys the script's own words runs it.

**R3 — 1.17.1's trigger rule made this worse, not better.** The FAST PATH
lists "a verify REVIEW/FAIL" as a legitimate trigger for deeper work. Correct
for a REVIEW that carries a *finding*; wrong for a REVIEW whose only cause is
"a gate declined on its own cost budget." A budget decline is a statement
about the *verifier's* spending limit, not about the file — treating it as an
accusation converts the budget into an anti-budget (the gate exists to save
time and instead spends 3× more).

**R4 — The "cheap tier is seconds" claim is false at size.** SKILL.md: "demux-
only packet hash + sampled decode — seconds, not runtime." The default tier is
~6 whole-file demux passes (streamhash ×2, VCL hash ×2, packet list,
disc_scan). Demux-only ≈ disk speed, so minutes per pass on multi-GB files.
Nobody — operator or session — can predict runtime from the docs, so waiting
looks like hanging and hanging invites more probing.

**R5 — Session mechanics.** Sleep-polling loops (`until grep -q … sleep 10`)
between every stage, and auto-settling without an operator ask.

## 3. Options

Each option carries: what it costs, doctrine fit (Constitution II.1 "unproven
is never a silent pass"; TIERS "gate the assertion, not the attempt"), risk.

### A. Class-keyed applicability: copy rungs prove (h)/(k) by IDENTITY — recommended core
On a copy-rung artifact, the remux's whole obligation is *faithfulness*. The
cheap sufficient proof: **output video packet count == source packet count**
(already known — census + gate (d)'s packet list) and **PTS column equality**
(same packet dumps, one `awk` compare). If both hold, the output *declares
what the source declared*: any (h)/(k)-class defect is inherited, i.e.
diagnosis territory (the source was already wrong in the player), not remux
verification. Gate rows become `pass (identity-proven: N==N packets, PTS
column equal)` — a real measurement, so II.1 is satisfied; nothing is waived.
The **absolute** structural proof stays owed where the writer *authored*
timing: pairfill/rebuild/poc/derive artifacts (their gates already run it) and
`--full` sign-off. Cost: ~zero (data already read). Risk: a source that is
itself misdeclared ships with an inherited defect — mitigated by option B,
which catches the known systemic class outright.

### B. Atom-arithmetic (h)-lite — run ALWAYS, no budget needed
The field-per-sample stutter class is *systemic*: declared sample rate ≈ 2×
the picture rate, file-wide. That is detectable from the **sample table
alone** — read `stts`/`mvhd` (a `lib_faststart.py`-style box walk,
milliseconds at any size) and compare declared average sample rate against
the measured frame rate probe already computed. No bitstream parse. This
turns the headline defect of the 2026-08-29 post-mortem into a free,
size-independent check on every output — the budget concept disappears for
the class that motivated the gate.

### C. Sampled (k)-lite — windows instead of the whole file
`trace_headers` on head/middle/tail windows (~30 s each): POC lattice checked
statistically, seconds instead of minutes, honest scope note in the ledger
("sampled 3 windows, N pictures"). Catches systemic misordering; misses a
single displaced junction. Reasonable as the default-tier form on repair-rung
artifacts; `--full` keeps the exhaustive form.

### D. Verdict semantics: a budget decline is not a REVIEW when identity holds
With A/B in place: substantive gates green + identity-proven + atom check
clean ⇒ **OK (exit 0)** with the ledger note stating exactly what was proven
and how. REVIEW remains for: repair-rung artifacts with declined gates, any
identity mismatch, any actual finding. This is the exit-code half of R1 — the
part that stops the escalation cascade at its source.

### E. Raise or auto-scale `RTM_STRUCT_MAX_BYTES`
Crude: any fixed number recreates the cliff at a new size; scaling by
measured parse throughput still spends CPU proportional to file size on
files nothing accused. Rejected as a fix (kept as a knob).

### F. Rewrite the decline/remedy text + FAST PATH refinement
Cheapest sufficient settle named FIRST (`poc-gate.sh` for (k) alone; the atom
check for (h)); `--full` named LAST and only for sign-off. Add one sentence to
both the decline text and FAST PATH: **"a REVIEW whose only cause is a budget
decline is reportable as done — settle it only on the operator's ask."**
Distinguishes finding-REVIEW (a trigger) from budget-REVIEW (a report).
Doctrine-clean: the trigger rule already keys on *findings*.

### G. Cost model + progress lines
State the measured cost model in SKILL.md (demux pass ≈ disk speed;
trace_headers ≈ ~1 min/GB CPU-bound; full decode ≈ content-length-dependent)
and have verify print per-pass `-- (a) … [pass 2/6, ~40s] --` style progress.
Kills the "is it hung?" probing loop at the session layer. Cheap, additive.

### H. Progressive verification (deferred deep tier)
Deliver on the default tier; offer the deep extras as an explicit background
or scheduled job. Fits the attended UX; recorded as a candidate — needs care
so "deferred" never silently becomes "skipped".

### I. Ledger resume: `verify.sh --settle`
Re-run ONLY the unproven rows of a previous ledger and merge (the session in
the incident hand-rolled exactly this with `poc-gate.sh`). Makes any settle
cost exactly its own gate, never a full re-verify. Complements F.

### J. Rung context plumbed to verify
`mov.sh`/`auto.sh` pass the artifact class (`RTM_ARTIFACT_CLASS=copy|repair`)
so verify keys applicability (A) without inferring. One env var; the builders
already know their rung (`RMX_CENSUS stage=`).

### K. Session-layer prose (skills/mov/SKILL.md + main SKILL.md)
Foreground the run instead of sleep-polling; report a budget-REVIEW verbatim
with a one-line offer ("two structural gates declined on the 4 GiB budget;
say the word and I'll settle them — ~N min") and STOP. The 1.17.1 "done means
done" sentence gets its missing half: done includes budget-declined gates.

## 4. Recommended package

**A + B + D + F + I + J**, plus G's cost-model paragraph and K's prose. Net
effect on the incident file: probe → mux (~2 min) → default tier (~3 min,
now including identity + atom checks) → **exit 0**, ledger stating precisely
what was proven and by which measurement. The deep proofs remain exactly
where they earn their cost: the repair rungs and `--full` sign-off.
C, E, H recorded as candidates, not taken.

**What does not change:** no gate is deleted; every skipped proof is a named
ledger row; the repair rungs keep their full suite; `--full` keeps its
meaning. Fewer verdicts that *demand* work; strictly more precision about
what was proven.

## 5. Test plan (if implemented)

- Extend test 87-style relationship pins: >budget clean copy ⇒ exit 0 +
  `identity-proven` rows; >budget repair-rung artifact ⇒ REVIEW unchanged;
  identity mismatch ⇒ REVIEW/FAIL; atom check catches a constructed
  2×-samples fixture (the 2026-08-29 defect class) at any size.
- Pin the decline text's remedy ordering and the budget-REVIEW sentence
  (119-style prose pin).

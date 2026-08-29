# WO-1.15.21 — "no pairing here" round

**Filed:** 2026-08-28, from the revision-3 field report (2024 VMA capture on
the 1.15.20 build — first contact between this file and the sparse-stamp rung).
**Outcome under test:** Rung 3-DERIVE refused the whole file at exit 3, all 24
holes orphaned, 0 bytes written, 38 s. The refusal is correct. What it exposed
is not.

**One sentence:** the sparse-stamp rung's single evidence rule assumes the two
fields of a frame are coded-adjacent, and on real reordered broadcast PAFF that
is false in **every one of 424,596 adjacent pairs** — so this round makes the
rung state its true jurisdiction, surfaces the second (independent) blocker the
windowed gate cannot see, and stops `auto.sh` reporting a principled refusal as
a gate breach.

**Verified against the tree before filing** (not taken on the report's word):
`auto.sh:240` (`RESULT=FAIL  # signature refusal (exit 3) or a failed gate`),
`auto.sh:37` (header admits the flattening), `derive-dts.sh:113` (the
`duplicate-PTS values=` line), `PF_SCAN_WINDOW=5000` (`lib-paff.sh:55`),
`_pair_parity`'s premise and `fill_sparse`'s unconditional orphan branch
(`derive-dts.py:154–192`, `232–280`).

---

## What the field run established

| Claim | Measurement | Status |
| :--- | :--- | :--- |
| Adjacent coded pairs one field apart | **0 of 424,596**; both parities 0/212,298 against a 99% bar | premise falsified |
| Dominant coded deltas | −3, +5, −1, +11 fields on a period of 6, summing +6/cycle (48.985% / 16.331% / 16.330% / 16.324%) | reorder pyramid, not a field cadence |
| `+1 field` delta | **never occurs** | the pairing the rung looks for does not exist here |
| Holes with timestamped immediate neighbours | 24 of 24 | necessary, not sufficient |
| Whole-file duplicate PTS | **10**, two of them bracketing the two bursts exactly | second, independent refusal |
| Windowed gate's duplicate count | `duplicate-PTS values=0` (5,000-packet head window) | unscoped claim |
| Rung exit 3 as seen by the operator | `>> FAIL` exit 1 | verdict flattening |

The two burst-bracketing duplicates (`pts=241616215` at coded 131818/131845;
`pts=619486615` at 337589/337617) are the same discontinuity events as the
lost PES headers — the holes and the repeated timestamps are one phenomenon,
not two.

---

## A1 — The rung's evidence rule has no jurisdiction over reordered PAFF  **(the headline)**

`_pair_parity` (`derive-dts.py:154`) rests on: *the two fields of a frame sit
adjacent in coded order, one field duration apart*. That premise holds for
simply-paired PAFF. It is false for a stream whose reorder pyramid distributes
fields across the coded order — which is the *majority* of the broadcast
captures this plugin exists for, and is the very stream the rung was built to
repair. `fill_sparse` then takes `orphans.append(j)` for every hole before it
reads a single mate, which is why the count is 24 of 24 rather than 1 of 24.

This is a **scope discovery, not a bug**: the refusal is the correct output of
a sound rule that does not apply here. What is wrong is that nothing says so.

**Fix (this round — honest jurisdiction, no new evidence rule):**

1. `fill_sparse`'s orphan refusal must distinguish its three shapes instead of
   listing them. When `parity is None`, say *that*, with the measurement:
   "the field pairing is not provable on this stream: 0 of N adjacent coded
   pairs differ by one field duration (both parities below the 99% bar) — this
   stream's fields are not coded-adjacent, so no hole has a readable mate."
   The current message invites the operator to hunt for a per-packet cause
   that does not exist.
2. Print the parity evidence unconditionally, pass or fail — the 1.15.7
   jurisdiction rule. A rule that never fires must say it never fired and on
   what evidence, or the next reader re-derives it.
3. `references/timeline-repair.md` and the rung's header: state the class the
   pre-pass covers (sparse holes in a stream with **provable coded-adjacent
   field pairing**) and the class it does not (sparse holes in a
   reorder-distributed stream). Name this capture as the motivating negative
   case, the way the round's positive fixtures are named.
4. `diagnose.sh` must reach this verdict **without** a 38-second rung run:
   when the pairing is unprovable, say so and stop, rather than printing a
   route whose only outcome is exit 3. (Same rule as S1's sixth defect, one
   layer in.)

**Explicitly NOT in this round:** loosening the 99% bar, falling back to any
2-neighbour inference, or filling "the obvious ones." The bilateral-cadence
rule was deleted in 1.15.20 for being imitable by a reorder anchor, and every
hole here sits at a discontinuity — the worst place to guess. See the spike.

---

## A2 — SPIKE (investigate, go/no-go, do not build blind): whole-file cadence as a second evidence rule

The report's histogram is a *proven, whole-file, periodic* structure — a
different evidence class from the deleted 2-neighbour rule. If the coded-order
delta cycle is provable at the same unforgiving bar, a hole's PTS may be forced
by its cycle phase.

**The spike's job is to answer one question with measurement, before any code
ships:** does the cycle hold *across the burst positions*? All 24 holes sit on
transport discontinuities, and a discontinuity is exactly where an encoder
cadence resets. The prior expectation is that it does **not** hold there —
which would mean the cycle rule buys nothing on the only file that needs it.

**Go criteria, all required:** the cycle is provable whole-file at ≥99% with a
losing-hypothesis ceiling (the `_pair_parity` shape); the predicted value for a
hole agrees when computed forward from `j−1` and backward from `j+1`; it
collides with nothing; and the rule is validated on the fixture lane *plus* a
minted fixture that reproduces a cadence break at a discontinuity. Anything
less and the answer is no, recorded with its measurement.

Deliverable either way: a short measured finding appended to this WO. Not a
merge.

---

## B1 — The second blocker is invisible to the gate that reports it

`derive-dts.sh:113` prints `packets=… N/A-PTS=… duplicate-PTS values=$DD_DUP`
measured over `PF_SCAN_WINDOW` (5,000) head packets. On this capture that reads
`0`; the whole-file truth is **10**. The header line does say "window", but the
value line reads as an absolute fact and the refusal at `:167` is phrased as
one. Even with the pairing solved, `derive_dts()` refuses on the first
duplicate — so the file has a second, independent, structural blocker that the
pre-flight actively reports as absent.

**Fix:**
1. Scope every windowed number in that line at the point of print
   (`duplicate-PTS values=0 (in window)`), and make the absence claim
   conditional: a windowed 0 is "none in the window", never "none".
2. `diagnose.sh` gains a **whole-file** duplicate-PTS census (it already reads
   the file; this is a counter, not a new pass) reporting the count, the
   values, their coded positions, and — the finding that matters — **how many
   straddle an unstamped burst**. Two of ten here; that is the signature that
   tells an operator "holes and duplicates are one discontinuity event" in one
   line instead of a session.
3. The duplicate-PTS refusal message names `diagnose.sh` already; make
   diagnose actually answer it.

**Policy question recorded, not decided:** whether a duplicate PTS that
straddles a known discontinuity is ever repairable. It breaks the unique
display timeline the derivation indexes, so the honest default stays refusal.
Any change here is a doctrine decision with an operator attestation, not a
gate tweak.

---

## C1 — `auto.sh` flattens a principled refusal into a gate breach  **(checkup C5, still open, now field-confirmed)**

`auto.sh:240` — `RESULT=FAIL  # signature refusal (exit 3) or a failed gate:
settled below`. The comment states the conflation outright, and `auto.sh:37`
records it as known. The operator sees `>> FAIL` exit 1 for a run in which
**nothing was built and nothing was wrong with any artifact** — the
REFUSED-vs-FAIL ledger corruption the 1.11 round fixed for VP9, reintroduced
one layer down, exactly as the 2026-08-27 checkup's C5 predicted.

The handoff's own outcome table prescribes different operator responses for
exit 3 and FAIL. The flattening makes that table unusable in the field.

**Fix:** a child's exit 3 propagates as REFUSED with its own verdict token and
rung attribution (`best_rung=none result=REFUSED`), distinct from FAIL, at
every call site that currently maps `*)` to FAIL — `run_rung` (`:207`, `:211`),
the derive arm (`:240`), the resync arm (`:254`), and the terminal verdict.
`mov.sh`, `batch.sh` and the summary rows learn the token (the verdict
vocabulary is API — checkup rule 4). Pin with a test that a refusing child
never produces `>> FAIL`.

---

## D1 — Correct the handoff, and the reasoning that produced it

`tryagain2024.md` revision 2 (mine) was wrong in three ways the report caught,
and the corrections belong in the file, not just in a reply:

1. **"The two stride-2 bursts should fill."** This reasoned from *timestamped
   immediate neighbours* — which is the bilateral-cadence rule 1.15.20 had
   just deleted as unsound. The build was right and the handoff was wrong; the
   prediction should have been "all 24 fill or none do, depending on whether
   whole-file pairing is provable."
2. **"Packet 12 is the open question."** It is not distinguished. When parity
   is unprovable every hole orphans identically.
3. **Off-by-one burst indices** (131825–131845 / 337595–337617 vs coded
   131824–131844 / 337594–337616), and the named end points are the duplicate
   partners, not holes.

**Fix:** revision 4 of `tryagain2024.md` — the corrected fingerprint table, the
measured parity result, both blockers, and the prediction discipline that
failed here: *a handoff must not predict from a rule the build rejects.*

---

## Tests

- **100-parity-jurisdiction.sh** — fixture: sparse holes in a reorder-
  distributed stream (mint from the measured cycle: period 6, deltas
  −3,−3,−3,+5,−1,+11 fields, no +1). Asserts: exit 3; the refusal names the
  unprovable pairing with its measurement; the three-shapes list does not
  appear; parity evidence prints on the passing fixture too.
- **101-dup-window-scope.sh** — injected column with 0 duplicates in the first
  5,000 packets and duplicates later: the windowed line must not claim an
  absolute 0; diagnose's whole-file census reports the count, positions, and
  the straddle count.
- **102-refused-not-fail.sh** — a child exiting 3 through `auto.sh` and
  `mov.sh`: verdict token REFUSED, `best_rung=none`, no `>> FAIL`, distinct
  exit. Red on today's tree at `auto.sh:240`.
- Mutation guards registered for each (the round's own class guard: no new
  `*) RESULT=FAIL` arm may swallow a 3).

**Gate:** `bash tests/regression.sh` green (297 carried + new),
`tests/mutation-audit.sh` new guards in contract, `claude plugin validate
--strict` green, version → **1.15.21**, CHANGELOG in house style,
`WO-1.15.21 <item>` provenance on every edit.

---

## What this round does not claim

It does not make the 2024 VMA capture convertible. Both blockers are whole-file
structural facts: this stream's fields are not coded-adjacent, and it carries
10 duplicate PTS. After this round the plugin will refuse it **faster, in the
right words, under the right verdict token, with both reasons named** — and
whether any sound evidence path exists for a reorder-distributed stream is the
A2 spike's question, answered with measurement or not at all.

## Leftovers

- Rung-1 copy skip still covers only the PAFF arm (1.15.20 ledger, unchanged).
- The `RTM_SPARSE_NOPTS_MAX` bound was never reached on this file and is not
  implicated; do not touch it.
- Whether `probe.sh`/`ts-health` should carry a whole-file duplicate-PTS and
  unstamped-packet census as standing instrumentation (this round adds it to
  diagnose only).

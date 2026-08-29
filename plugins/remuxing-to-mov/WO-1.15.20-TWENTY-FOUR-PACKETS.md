# WO-1.15.20 — "Twenty-Four Packets" round

**Status:** EXECUTED 2026-08-28 (shipped as 1.15.20).
**Filed:** 2026-08-28, from the field re-test report against the 2024 VMA capture
(`feed.ts`, 25.38 GB, 02:24:25 — 24 unstamped video packets of 424,645,
three clusters, two with stride 2).
**Source of record:** the "Twenty-Four Packets" report (next-phase.html). Its
measurements were made on the field bench; every figure below that this round
builds on must be re-measured here per the pin-relationships rule.

**One sentence:** the F9 fixes turned a 54 GB / 4-minute failure into a
9-second / 0-byte refusal — correct, and this round (a) brings those field
patches home, (b) kills the diagnostic's dead-end route (the sixth defect),
and (c) builds the one missing rung the refusal now precisely describes:
stamp the isolated unstamped packets from their pair-mates, then derive.

---

## S0 — Reconcile the field F9 patches with this repo  **(FIRST ACTION)**

The report describes an installed build labeled 1.15.18 with in-place F9
edits (2026-08-28) to `auto.sh`, `lib-paff.sh`, `pairfill-paff.sh`,
`derive-dts.sh`, `probe.sh`, `diagnose.sh` — including behavior this tree
does not have:

- Rung 1 (copy) skipped from the probe measurement when `nopts_frac > 0`
  ("packets with data but no PTS force the muxer to invent timing… the
  refusal is predetermined") — no such skip exists in this tree's `auto.sh`
  (grep: no `skipping Rung 1`, no `invent timing` outside `zero-base.sh:134`).
- The `-- verdict FAIL; NO AUTOMATIC ROUTE (… no rung composes 'fill the few
  missing PTS' -> 'derive DTS') --` verdict text — absent from this tree.

**Work:** diff the field install against this repo (operator supplies the
field tree or the F9 diff). Port every behavioral change home with its
provenance comments intact. If the field diff is unavailable, re-derive the
two behaviors above from the report's transcript and mark them
`WO-1.15.20 S0 (re-derived; field original unavailable)`. Nothing else in
this round starts until the tree contains the behavior the report re-tested
— otherwise the round's tests pin a build that isn't this one.

Also from the report: the field patches shipped WITHOUT a version bump
(handoff's "still 1.15.18 ⇒ reinstall did not take" check read as a false
negative). See S4.

---

## S1 — The sixth defect: diagnose.sh routes into the dead end pairfill no longer guards

**Confirmed in this tree:**
- `diagnose.sh:83–85` — the fallback branch
  `elif [ "$PF_HALF_TS" = yes ] || [ "$PF_REORDER" = yes ]` routes to
  pairfill with the claim: *"its own gates refuse (exit 3) if the shape is
  not the pair class."*
- `pairfill-paff.sh:120` — the shape check is a warning that proceeds:
  `[ "$PF_PAFF" = yes ] || echo "   note: … — proceeding anyway (caller's
  call)."` The half_ts check is the same class. The exit-3 refusals that DO
  exist are codec (`:119`) and rate-map (`:140–142`) — not shape.

**Cost if followed:** a full-length pair-fill build (~26.8 GB, minutes) and
then a timeline-gate rejection, on the promise the tool would refuse first.
`auto.sh` and `diagnose.sh` currently give contradictory routing for the
same measurement; `auto.sh` is correct.

**Fix:**
1. `diagnose.sh:85` — the prose must state what pairfill actually does:
   warns and builds. No route may be printed on the strength of a refusal
   that does not exist (this is the same class as the F1/1.15.11 rule: the
   clinic must not hand you a refusal — nor promise you one).
2. Add the sparse-unstamped class as an explicit branch BEFORE the fallback:
   `reorder=yes ∧ half_ts=no ∧ 0 < unstamped` → route to the S2 rung when
   its preconditions hold (mate-evidenced, see S2), else print the same
   NO-AUTOMATIC-ROUTE verdict auto.sh prints, with the measured evidence.
   diagnose and auto must emit the SAME routing for the same profile —
   pin that with a test, not a comment.

---

## S2 — The missing rung: bounded sparse-stamp pre-pass, then derive  **(the round's centerpiece)**

The report: *"a bounded pre-pass that stamps 24 isolated packets from their
pair-mates would satisfy the derive precondition exactly, and derive-dts.sh
would then run unmodified. Building that is a plugin decision."* This round
builds it. The MKV strict-mux failure (error −22) established the timeline
as the sole obstacle, so stamp-then-derive is sufficient, not merely
necessary.

**Shape — a pre-pass inside derive-dts.py, not a new script:**
`derive-dts.py:38–41` currently refuses ANY video packet with data but no
PTS ("this derivation would invent, not derive"). That refusal stays the
default. New: when the unstamped set is SPARSE and every member is
MATE-EVIDENCED, fill each missing PTS from its pair-mate before the
(unchanged) derivation:

- **Sparse:** `n_nopts / n_video ≤ RTM_SPARSE_NOPTS_MAX` (default pinned as
  a relationship: well below the pairfill signature's ~0.5, well above this
  file's 5.65e-5 — propose 0.01, document why) AND every unstamped packet
  sits in a cluster whose neighbors are timestamped.
- **Mate-evidenced:** the packet's pair-mate (stride-2 neighbor, the PAFF
  field-pair signature `lib-paff.sh:555–556` already names) carries a real
  PTS, and the fill value is `mate_pts ± modal field duration`
  (`modal_step()` already computes it, `derive-dts.py:61–70`). A filled
  value that collides with an existing PTS is a REFUSAL, not a nudge —
  the duplicate-PTS refusal (`derive-dts.py:80–86`) must fire on filled
  values exactly as on carried ones.
- **Any unstamped packet without a mate ⇒ refuse the whole file, exit 3,**
  with the count and positions. Never fill some and derive anyway — a
  partial fill is the invented-timing class with better manners.

**Announcement + census:** every stamp announced (position, mate, value);
machine row `stamped=N of=M method=pair-mate` in the census/sidecar, so the
artifact's provenance records that N timestamps are reconstructions. The
derivation, its monotonicity/PTS-bound asserts, and every output gate
(packet-hash gates included — stamps are container metadata, essence
untouched) run unchanged after the fill.

**Keep the pure function pure:** the fill logic lands beside `derive_dts()`
as a PyAV-free function (`fill_sparse(coded_pts_with_holes) -> (filled,
stamped_positions)` or refuse), so the unit lane pins the math via importlib
on a PyAV-less bench, same as the derivation itself (`derive-dts.py:49–50`).

**Routing (auto.sh + diagnose.sh + probe.sh advisory):**
- The class `reorder=yes ∧ half_ts=no ∧ 0 < nopts ≤ sparse-bound` routes to
  Rung 3-DERIVE, whose own pre-pass now settles fill-vs-refuse from
  whole-file evidence. auto.sh's derive-signature test (`auto.sh:150`,
  `frac ≤ 0.001`) widens to the sparse bound — but see S3: the routing
  DECISION must ride the whole-file count, not the head-window fraction.
- The NO-AUTOMATIC-ROUTE verdict survives for the class the rung refuses
  (orphaned unstamped packets); its text drops "no rung composes…" —
  after this round one does — and states the actual refusal reason.

**Rung 4 / gate-loosening doctrine unchanged:** `PF_PTS_COMPLETE_MAX`-style
loosening remains rejected for the reason the report records — the
derivation indexes a column unstamped packets have no place in. The
pre-pass gives them a place from evidence; it does not loosen the gate.
State this in the rung's header comment.

---

## S3 — Head-window fraction vs whole-file count: the routing evidence mismatch

The field transcript prints `nopts_frac=0.004` (head-window, probe.sh scan)
for a file whose whole-file truth is 24/424,645 = 5.65e-5 — a 70× overread
that pushed the file past diagnose's `FRAC0` cutoff (`diagnose.sh:63`,
`≤ 0.001`) into the pairfill dead end. Meanwhile derive-dts.py gates on the
EXACT whole-file count. Three inconsistent evidence scopes for one decision.

**Fix:**
1. probe.sh prints the raw counts beside the fraction and names the window
   (`nopts=20/5000 (head window; whole-file count decided at the rung)`),
   per the scanner-jurisdiction rule (1.15.7).
2. Routing branches in diagnose.sh/auto.sh that sit near a cutoff treat the
   head-window fraction as ADVISORY: the sparse class routes to the rung,
   and the rung's own whole-file census (it reads every packet anyway —
   pass 1 already walks the file) makes the fill/refuse decision. No more
   routing a 0-<-frac-≤-0.001 file into derive's unconditional refusal —
   that was a route-to-a-foregone-refusal (the 1.15.2 Item-C shape) this
   tree still contains today.

---

## S4 — Build identity: a field bench must be able to tell what is installed

The report burned its first minutes on "version says 1.15.18, but the
mtimes and markers say patched" — the handoff's version check produced a
false negative because in-place patches shipped without a bump.

**Fix (small, mechanical):**
1. `doctor.sh` (and `probe.sh --kv` as `PR_PLUGIN_VERSION=`) print the
   version read from `.claude-plugin/plugin.json` at runtime — never a
   hardcoded copy.
2. CONSTITUTION.md gains the rule: any behavioral edit that reaches an
   installed bench carries a version bump, even a hotfix — the version
   string is the handoff's only cheap integrity check, and a stale one is
   worse than none.

---

## S5 — Docs: the sparse-unstamped class exists now

The report: *"nothing in `references/` documents this class at all."*

- `references/timeline-repair.md` — add the class to the ladder: definition
  (PTS-complete except isolated unstamped packets), why derive refused it,
  why pairfill never applied (24 packets is not the ~0.5 pair signature),
  the new pre-pass, its refusal conditions, and the 2024-VMA capture as the
  motivating case.
- `SKILL.md` — Rung 3-DERIVE's description gains the pre-pass sentence and
  the census row (`stamped=`) joins the `RMX_CENSUS` enum (the F4 lesson:
  the enum is declared-stable API — update it WITH the emitter).
- `diagnose.sh`/`probe.sh` advisory prose swept for any surviving
  "no rung composes" / false-refusal claims after S1/S2 land.

---

## Tests (every fix red on the pre-fix tree)

**Fixtures** (`tests/make-fixtures.sh`):
- `sparse-nopts.ts` — reordered, PAFF-shaped, fully timestamped except a
  few packets in stride-2 clusters with timestamped mates (mint via the
  PyAV writer lane; pin minted count as a variable, not a literal).
- `sparse-orphan.ts` — same, plus one unstamped packet whose mate is also
  unstamped (the refusal control).

**Cases** (`tests/regression.d/`):
- **96-sparse-routing.sh** — diagnose.sh and auto.sh on the sparse profile
  (injection lane, test-64 pattern): both print the SAME route; neither
  prints a pairfill route; the pre-fix tree prints pairfill from
  diagnose.sh:85 (red). Mutation guards G/P-registered per house style.
- **97-fill-math.sh** — unit lane (importlib, PyAV-free): `fill_sparse()`
  fills stride-2 holes from mates at modal field duration; refuses orphans;
  a filled value colliding with a carried PTS refuses; filled column feeds
  `derive_dts()` and its asserts hold.
- **98-stamp-derive-e2e.sh** — PyAV-gated: full rung on `sparse-nopts.ts` →
  census `stamped=N` equals the minted count (relationship pin), verify OK;
  `sparse-orphan.ts` → exit 3, no output, positions named.
- **99-sixth-defect-prose.sh** — greps diagnose.sh for the false exit-3
  claim shape (text pin registered as prose-guard, not behavior).
- S0's ported behaviors each land with the test the field build never had
  (rung-1 nopts skip: plan-mode assertion that no `.part` is created and
  the skip reason prints; NO-ROUTE verdict: routing case in 96).

**Gate:** `bash tests/regression.sh` green (293 carried + new) from
`plugins/remuxing-to-mov/`, `tests/mutation-audit.sh` new guards 4/4 in
contract, `claude plugin validate --strict` green, version → **1.15.20**,
CHANGELOG entry in house style, every edit carrying `WO-1.15.20 <item>`
provenance.

---

## Rules of engagement (carried forward, non-negotiable)

- EMPTY ≠ ABSENT: the pre-pass fills only from measured mate evidence; a
  hole without evidence refuses the whole file. UNPROVEN ≠ FAILED: probe
  failures during the pre-pass are announced UNPROVEN, never counted as
  holes or as fills.
- Pin relationships, never bench literals (the 24, the 5.65e-5, the 0.004
  are this capture's numbers — tests pin `stamped == minted`, cutoffs are
  named constants with rationale).
- Trust no comment — S0's port must verify each field claim against the
  code it lands in; re-measure any figure built upon.
- Don't expand scope: the head-trim (1.960 s black lead), Rung 4, and
  `--force` remain operator calls exactly as the handoff left them. The
  D1 display siblings and other 1.15.19 residuals stay in their ledgers.

## Leftovers (recorded, not this round)

- batch.sh ledger column for exit-2 refusals (1.15.19 residual, unchanged).
- `clean.sh` cosmetic empty `audio_tracks=` (1.15.19 residual, unchanged).
- A general nopts whole-file scanner in ts-health (the clinic currently has
  no lane that counts unstamped packets file-wide; the rung's pass-1 census
  covers this round's need).

---

## Execution record (2026-08-28)

**S0 was not blocked.** The field tree was found installed at
`~/.claude/plugins/cache/rare-data-club/remuxing-to-mov/1.15.18/` (six scripts
with post-install mtimes), so the port is the MEASURED diff against clean
1.15.18 (`cbcb0f8`), not a re-derivation from the report's transcript. No
`re-derived` markers were needed. The F9 hunks applied to 1.15.19 without fuzz.

**Two claims in this WO were measured false and the round corrected them.**

1. *"the packet-hash gates … run unchanged after the fill"* — they could not.
   `derive-dts.sh`'s gate 3 used the raw container-sensitive `streamhash`, so
   a byte-perfect TS → MOV copy FAILed exit 1 on **every `.ts` source**.
   Reproduced with `stamped=0`, so it long predates the pre-pass. Fixed by
   mirroring `verify.sh` gate (a)'s VCL fallback. Without it this round could
   not have delivered a blessed artifact for its own motivating class.
   Output gate 2 needed teaching too (it is told which reconstructions to
   expect, not loosened).
2. *"the fill value is `mate_pts ± modal field duration`"* via a stride-2
   neighbour, with a bilateral-cadence reading — the bilateral rule is
   UNSOUND and was removed. See the CHANGELOG and `references/timeline-repair.md`
   for the measurement (coded 306/307/308 on this round's own fixture).

`lib-paff.sh:555-556` does not name a "stride-2 neighbour"; it is the `pf_half`
pair-signature comment. The pairing is now proven from the whole file instead.

## Leftovers (recorded, not this round)

- **The F9 rung-1 copy skip covers the PAFF arm only.** A non-PAFF reordered
  source with unstamped packets still spends a full-length copy write to reach
  a foregone confession-gate refusal (Article I.3). The rule is
  shape-independent in principle, but F9's measurement is from a PAFF capture
  and this bench has no fixture for the non-PAFF case — extending an unmeasured
  claim to an untestable class is exactly what the house forbids. Pinned as a
  gap here rather than silently widened.
- **A boundary hole in an unprovable-pairing stream refuses.** The head packet
  of the field capture is reconstructable only because a PAFF pairing is
  provable there. No one-sided extrapolation rule was added; there is no
  evidence for the direction.
- **Gate 3's VCL arbiter is exercised on H.264 only.** `filter_units
  remove_types=6|7|8|9` has per-codec semantics; the mpeg2video path through
  this rung is unpinned (it reaches the arbiter only when the raw hashes
  already disagree).
- **Fixture reality.** `sparse-nopts.ts`/`sparse-orphan.ts` impose a synthetic
  field-pair TIMELINE on frame-coded x264 essence — legitimate, because the
  rung copies packet bytes untouched and the timeline IS the class, but true
  PAFF essence remains the house synthesis limit (libx264 cannot mint it).
- **The 2024-VMA capture itself was never on this bench.** Everything here is
  verified on fixtures minted to the same MEASURED profile. The field run is
  the only thing that can confirm the capture's own 24 packets fill — in
  particular whether its head packet has a provable mate.
- Carried unchanged from 1.15.19: batch.sh ledger column for exit-2 refusals;
  `clean.sh` cosmetic empty `audio_tracks=`; a general nopts whole-file scanner
  in ts-health (the rung's pass-1 census covers this round's need).

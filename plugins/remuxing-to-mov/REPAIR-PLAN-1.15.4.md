# Repair Plan: WO-1.15.4 — "EMPTY ≠ ABSENT"

**Date:** 2026-08-28  
**Scope:** Apply fixes for checkup findings A1, C2, C3, C4, C6, C7, plus D1/D2 and A4/C8  
**Gate:** `bash tests/regression.sh` green + `claude plugin validate --strict` green + version bump + CHANGELOG  

---

## The Core Rule

```
EMPTY ≠ ABSENT (twin of UNPROVEN ≠ FAILED)
No probe output may feed a verdict, plan, or accusation without its exit status.

House idiom: set +e; x=$(…); rc=$?; set -e; [ -n "$x" ] || refuse
```

---

## A1 — Audio Plan Fails Open (6 sites)

**Issue:** Probe failure indistinguishable from "no audio" → video-only MOV ships as "verified lossless, rc=0"

**Root cause:** `remux.sh:135` `|| true` swallows exit status. `mov.sh:519` reads empty PLAN as MODE=none. `verify.sh:407` disables gates.

**Sites to fix:**
1. `remux.sh:135` — main audio plan (ffprobe query)
2. `mov.sh:499` — PLANOUT subshell
3. `rebuild-paff.sh:101` — PAFF rebuild plan
4. `mov.sh:174` / `auto.sh:67` — eval "$(probe.sh --kv | grep …)"
5. `probe.sh` awk END block — fabricates PR_AUD_COUNT=0 on failure

**Fix pattern:**
```bash
set +e; x=$(…); rc=$?; set -e
[ -n "$x" ] || { echo "ABORT: probe failed (context)" >&2; exit 1; }
# Then use $x
```

**Test:**
- `tests/regression.d/80-empty-ne-absent-audio-plan.sh` (PATH shim failing audio query)
- Repro: `mov.sh` with ffprobe exit 1 on audio query → must exit 1, NOT "verified lossless"

---

## C2 — verify-source Accuses "INTRODUCED" on Empty Baseline

**Issue:** No check if source baseline exists → accuses "backward DTS INTRODUCED (0 -> 1)" on identical files

**Root cause:** `verify-source.sh:251` reads `$SOURCE_BASELINE` without existence check

**Fix:** `verify-source.sh:251–260`
```bash
if [ ! -s "$SOURCE_BASELINE" ]; then
  echo "** ABORT: source baseline is empty or unreadable" >&2
  exit 2
fi
```

**Test:**
- `tests/regression.d/81-empty-ne-absent-verdicts.sh` — verify-source with empty baseline

---

## C3 — verify.sh gate (b): Empty vs Empty Read "Frames Differ"

**Issue:** ffmpeg tool failure → empty hash → empty==empty → accusation "NOT lossless"

**Root cause:** `verify.sh:145–154,166–174` — `fhead=$(… || true)` swallows tool failure

**Fix:** Capture exit status, treat empty as "inconclusive" not "different"
```bash
set +e
vhead=$(ffmpeg …)
vhead_rc=$?
set -e
[ $vhead_rc -eq 0 ] || { echo ">> REVIEW(b): tool failure"; return 0; }
[ -n "$vhead" ] || { echo ">> REVIEW(b): empty hash"; return 0; }
```

**Test:**
- `tests/regression.d/81-empty-ne-absent-verdicts.sh` — unreadable inputs → REVIEW(b), not FAIL

---

## C4 — ts-health Silent Exit 1 on Unreadable Input

**Issue:** First assignment under `set -e` → exit 1 with zero output. Exit 1 = "DAMAGED" per contract. "Could not read" ships as "proven damaged" silently.

**Root cause:** `ts-health.sh:64` — no pre-flight check

**Fix:** `ts-health.sh:55–80` — pre-flight ffprobe read:
```bash
if ! ffprobe -v error -show_streams "$SRC" >/dev/null 2>&1; then
  echo "** EXIT 2: ffprobe cannot read source (pre-flight)" >&2
  exit 2
fi
```

**Test:**
- `tests/regression.d/81-empty-ne-absent-verdicts.sh` — unreadable file → exit 2, not 1

---

## C6 — verify.sh spo() Dead D4 Branch (Re-arm WITH test + fixture)

**Issue:** ffprobe emits canonical field order, not requested order. `spo()` reads NR==1 as time_base, NR==2 as start_pts. Split on empty denominator → always prints 0. D4 "delta == declared start_pts" branch unreachable.

**Root cause:** `verify.sh:1196` — assumed requested field order == emitted order

**Fix:** `verify.sh:1196–1210` — measure actual field positions:
```bash
function spo() {
  local fields=$(ffprobe -select_streams $1 -show_entries stream=start_pts,time_base -of default=nw=1:nk=1 "$2" 2>/dev/null)
  local time_base=$(echo "$fields" | head -1)
  local start_pts=$(echo "$fields" | tail -1)
  # Extract num/denom correctly from time_base
  local num=${time_base%%/*} denom=${time_base##*/}
  [ -n "$denom" ] && [ "$denom" -ne 0 ] && \
    awk "BEGIN {print int(($num*$start_pts/$denom))}" || echo 0
}
```

**CRITICAL:** Re-arms D4 verdict branch. Land WITH:
- D4 test fixture (source with audio at non-zero start_pts)
- Test that proves D4 REVIEW classification reachable

**Test:**
- `tests/regression.d/82-c6-d4-start-pts.sh` — audio with declared start_pts > 0 → D4 REVIEW, delta printed

---

## C7 — mov.sh Dies on Child Exit 10, Skips Verify + Gates

**Issue:** `mov.sh:527–565` — bare `bash remux.sh …` under `set -e`. Exit 10 (remux's sanctioned REVIEW) kills mov.sh at call site. No verify, no verdict, no cleanup.

**Root cause:** Builder call not wrapped; exit 10 propagates, killing the function before verify

**Fix:** `mov.sh:527–565` — unwrap from set -e:
```bash
REMUX_RC=0
bash remux.sh "$SRC" "$PART"
REMUX_RC=$?
[ $REMUX_RC -eq 0 ] || [ $REMUX_RC -eq 10 ] || exit $REMUX_RC

# verify ALWAYS runs, even on exit 10
bash verify.sh "$SRC" "$PART" …
# then decide final verdict based on both
```

**Test:**
- `tests/regression.d/83-c7-mov-review-passthrough.sh` — remux exit 10 → verify still runs

---

## D1 — Confession Report SIGPIPEs, Loses Mktemp Pointer

**Issue:** `grep | sort | uniq -c | sort -rn | head -4` over large log: producer takes SIGPIPE after 4 lines but before `Kept: (log: …)` echo. Mktemp path unfindable.

**Sites:** `remux.sh:436`, `pairfill-paff.sh:370` (derive-dts.sh:218 already fixed)

**Fix:** Replace `head -4` with `grep -m4`:
```bash
# BEFORE: grep … | sort | … | head -4
# AFTER: grep -m4 … | sort | …
```

**Test:**
- `tests/regression.d/85-d1-d2-evidence-loss.sh` — large muxlog, verify log path printed

---

## D2 — verify.sh --full Leaks Mktemp Dir on Decode Failure

**Issue:** `verify.sh:1039–1042` — ffmpeg decode to /dev/null under pipefail. Failure → silent ERR exit before cleanup. `rm -rf "$HLD"` at :1065 never runs. ~40 MB leak per 2 h broadcast.

**Sites:** `verify.sh:1039`, (SUSPECTED) `lead-check.sh:150`, `qt-groups.sh:290`

**Fix:** Capture exit status, always cleanup:
```bash
set +e
hlist=$(ffmpeg -i … 2>&1 | md5sum)
hlist_rc=$?
set -e
[ $hlist_rc -eq 0 ] || {
  echo ">> REVIEW(full): frame decode failed" >&2
  rm -rf "$HLD"
  return 0
}
```

**Test:**
- `tests/regression.d/85-d1-d2-evidence-loss.sh` — decode failure in --full, verify mktemp cleaned

---

## A4 — Confession Pattern Drift (Already applied in one-liner round)

**Status:** ✓ Checked. `lib-paff.sh:445` and `derive-dts.sh:214` both use `non-?monoton(ic|ous)` pattern. Checkup one-liner already applied this.

**No action needed.** Reference for test coverage verification.

---

## C8 — derive-dts.py Opens at 5 MB Probesize (200 M Floor Feeder)

**Issue:** `derive-dts.py:131,176` — `av.open(src)` with no options. On `late-sps.ts` (repo's own fixture): PyAV sees 0x0; ffprobe sees 1280×720.

**Root cause:** `lib-probe.sh:2–4` floor (200 M) not plumbed into Python

**Fix:** `derive-dts.py:131, 176` — read RTM_PROBESIZE env:
```python
import os
probesize_str = os.environ.get('RTM_PROBESIZE', '200M')
probesize_bytes = int(probesize_str.rstrip('M')) * 1024 * 1024

options = {
    'probesize': str(probesize_bytes),
    'analyzeduration': str(probesize_bytes * 10)
}
container = av.open(src, options=options)
```

**Test:**
- `tests/regression.d/84-c8-py-probe-floor.sh` — derive-dts on late-sps.ts with RTM_PROBESIZE=200M

---

## Testing Gate

**All 8 test cases must be red on pre-fix code, green on fixed code:**
1. `80-empty-ne-absent-audio-plan.sh` (A1)
2. `81-empty-ne-absent-verdicts.sh` (C2, C3, C4)
3. `82-c6-d4-start-pts.sh` (C6)
4. `83-c7-mov-review-passthrough.sh` (C7)
5. `84-c8-py-probe-floor.sh` (C8)
6. `85-d1-d2-evidence-loss.sh` (D1, D2)

**Full suite:** `bash tests/regression.sh` = 274/274 baseline + new 6+ tests PASSED

**Validation:** `claude plugin validate --strict` passes

**Commit:**
```
WO-1.15.4: EMPTY ≠ ABSENT (A1 audio plan, C2/C3/C4 baselines & verdicts, C6 D4 re-arm, C7 verify passthrough, D1/D2 evidence loss)

- A1: audio plan fail-open fixed at 6 sites (remux.sh, mov.sh, rebuild-paff.sh, probe.sh)
- C2: verify-source refuses empty baseline, doesn't accuse INTRODUCED
- C3: verify.sh gate (b) treats tool failure as inconclusive, not difference claim
- C4: ts-health pre-flight read check exits 2 (pre-flight), not 1 (damaged)
- C6: verify.sh spo() reads canonical ffprobe field order; D4 branch re-armed WITH test
- C7: mov.sh verify gates run even on remux exit 10 (REVIEW)
- D1: confession report uses grep -m4 instead of head (no SIGPIPE)
- D2: verify.sh --full cleans mktemp on decode failure
- A4: confession pattern drift already applied (one-liner round checkup)
- C8: derive-dts.py respects RTM_PROBESIZE floor (200M)

All fixes include WO-1.15.4 provenance comments. Test coverage: 274+6/280 PASSED.
```

---

## Execution Checklist

- [ ] A1: fix 6 sites (remux.sh, mov.sh×2, rebuild-paff.sh, auto.sh, probe.sh)
- [ ] C2: verify-source.sh baseline check
- [ ] C3: verify.sh gate (b) empty-hash handling
- [ ] C4: ts-health pre-flight
- [ ] C6: spo() field-order fix + D4 fixture + test
- [ ] C7: mov.sh verify passthrough on exit 10
- [ ] D1: remux.sh, pairfill-paff.sh confession report (grep -m4)
- [ ] D2: verify.sh, lead-check.sh, qt-groups.sh decode-failure cleanup
- [ ] C8: derive-dts.py probesize options
- [ ] Create tests 80–85
- [ ] Run `bash tests/regression.sh` → 274+6+ PASSED
- [ ] Run `claude plugin validate --strict` → PASS
- [ ] Version bump + CHANGELOG entry
- [ ] Commit with house-style message
- [ ] Verify `plugins/hunt/*` untouched (pre-session state preserved)


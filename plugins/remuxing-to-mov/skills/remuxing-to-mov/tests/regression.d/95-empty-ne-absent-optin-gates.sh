#!/usr/bin/env bash
# 95-empty-ne-absent-optin-gates.sh — WO-1.15.4's own leftover ledger, closed
# (1.15.19). The EMPTY ≠ ABSENT rule was applied to the gates that run by
# DEFAULT and left at the ones the operator has to ASK for — which is the
# worse place to leave it: a caller who typed --silence or --audio is the one
# caller who has declared they want that evidence, and a failed probe handed
# them a clean skip.
#
#   L1  verify.sh --silence (:1011) — `| grep -c . || true` read a FAILED
#       audio census as 0 tracks -> "no audio in output — silence parity
#       N/A.", exit unchanged. Measured pre-fix on this bench: gates (f) and
#       (g) print "audio census probe FAILED … UNPROVEN" (A1's fix) and TWO
#       LINES LATER the same failed probe reads "no audio" in this gate.
#   L2  verify.sh --audio (:1204) — same census, same `|| true`: "output has
#       0 audio track(s); … Skipping." on a probe that never ran.
#   L3  verify.sh gate (f) vdur (:431) — `vdur=$(sdur v:0)` in ASSIGNMENT
#       position with pipefail: a failed video-duration probe was not the
#       recorded "reads N/A" at all — measured, it is a SILENT ERR-trap abort
#       at gate (f) with NO verdict line printed and rc 1, which is verify's
#       FAIL. "I could not measure the video duration" shipped as "this file
#       FAILED verification". (The C4 shape, inside verify.sh itself; the WO
#       leftover ledger understated it and is corrected in place.)
#   L4  derive-dts.sh gate 3/4 (:285) — `phash() { … || true; }` then
#       `[ -n "$sp" ] && [ "$sp" = "$op" ]`: two EMPTY hashes take the else
#       arm and print ">> PACKET-HASH GATE FAILED — the copied bitstream is
#       not identical." with `src=` and `out=` blank, exit 1. The C3
#       accusation-from-zero-evidence shape, on a builder's blessing path.
#
# The rule in one line: a gate the operator ASKED for may report PASS, FAIL,
# or UNPROVEN — never a silent skip and never an accusation, on evidence that
# was never collected.
#
# Fault injection is the house PATH-shim pattern (test 81): each shim fails
# exactly one query shape and execs the real tool for everything else, so the
# rest of the run is genuine. Every section carries its discrimination
# control — the un-shimmed arm must keep the behavior the fix is not about.
#
# Standalone: bash tests/regression.d/95-empty-ne-absent-optin-gates.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"; FIX="$TESTS/fixtures"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
. "$TESTS/lib-harness.sh"   # grepq: reads to EOF (a `| grep -q` here is the
                            # 1.15.2 SIGPIPE class the suite's own §10 guard forbids)
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
hasnt () { case "$1" in *"$2"*) no "$3 [unexpected: $2]";; *) ok "$3";; esac; }
ff () { ffmpeg -nostdin -hide_banner -loglevel error "$@"; }

# fixture corpus self-heal (standalone runs; the harness heals once up front)
[ -f "$FIX/aac.ts" ] || bash "$TESTS/make-fixtures.sh" aac.ts >/dev/null 2>&1 || true
SRC="$FIX/aac.ts"
[ -f "$SRC" ] || { echo "95: (SKIP: aac.ts fixture unavailable)"; echo "empty-ne-absent-optin-gates: 0 passed, 0 failed"; exit 0; }
OUT="$WORK/out.mov"
ff -i "$SRC" -map 0:v:0 -map 0:a:0 -c copy -f mov "$OUT" -y

REAL_FFPROBE="$(command -v ffprobe)"; REAL_FFMPEG="$(command -v ffmpeg)"
# shim CEN: fail ONLY the audio-census query shape (`-select_streams a ` with a
# trailing space — `a:0` queries must still work, or the whole report dies and
# the pin would pass for the wrong reason).
mkdir "$WORK/shimCEN"
cat > "$WORK/shimCEN/ffprobe" <<EOF
#!/bin/bash
case "\$*" in *"-select_streams a "*"stream=index"*) exit 1;; esac
exec "$REAL_FFPROBE" "\$@"
EOF
# shim VDUR: fail ONLY the v:0 stream-duration query (gate (f)'s vdur).
mkdir "$WORK/shimVDUR"
cat > "$WORK/shimVDUR/ffprobe" <<EOF
#!/bin/bash
case "\$*" in *"-select_streams v:0"*"stream=duration"*) exit 1;; esac
exec "$REAL_FFPROBE" "\$@"
EOF
# shim HASH: fail ONLY the streamhash pass (derive-dts gate 3).
mkdir "$WORK/shimHASH"
cat > "$WORK/shimHASH/ffmpeg" <<EOF
#!/bin/bash
case "\$*" in *"-f streamhash"*) exit 1;; esac
exec "$REAL_FFMPEG" "\$@"
EOF
# shim VCL: a REAL essence difference, with two NON-EMPTY hashes. The output
# side of every streamhash pass answers with a different digest, so gate 3's
# accusation arm is exercised on evidence that actually was collected — the
# discrimination control for the UNPROVEN arm above (WO-1.15.20).
mkdir "$WORK/shimVCL"
cat > "$WORK/shimVCL/ffmpeg" <<EOF
#!/bin/bash
# two nested tests, not one glob: the .part- input appears BEFORE
# "-f streamhash" on the command line, so an ordered pattern never matches
case "\$*" in *"-f streamhash"*)
  case "\$*" in *.part-*) echo "0,v,MD5=00000000000000000000000000000000"; exit 0;; esac ;;
esac
exec "$REAL_FFMPEG" "\$@"
EOF
chmod +x "$WORK/shimCEN/ffprobe" "$WORK/shimVDUR/ffprobe" "$WORK/shimHASH/ffmpeg" "$WORK/shimVCL/ffmpeg"

# the (--silence) / (--audio) block only, so a pin cannot be satisfied by the
# identically-worded (f)/(g) lines that A1 already fixed above them. LITERAL
# prefix via index(), never a dynamic regex: `awk -v h='^-- \(--audio\)'`
# processes the backslash escapes out of the value and the parens then read as
# a GROUP, so the header never matches and every block pin passes vacuously on
# an empty string (measured while writing this test — the first red run).
block () { printf '%s\n' "$1" | awk -v h="$2" 'index($0,h)==1 {g=1; next} g && index($0,"-- ")==1 {exit} g'; }

echo "== L1: --silence on a FAILED audio census — UNPROVEN, never 'no audio' =="
o=$(PATH="$WORK/shimCEN:$PATH" bash "$SC/verify.sh" "$SRC" "$OUT" --silence 2>&1); rc=$?
b=$(block "$o" "-- (--silence)")
[ -n "$b" ] && ok "the --silence block is reached and prints" || no "no --silence block in the output"
hasnt "$b" "no audio in output" "a failed census is never reported as 'no audio in output'"
has "$b" "UNPROVEN" "the block says UNPROVEN"
has "$b" "census probe FAILED" "the block names the probe failure (with its rc)"
# the pre-fix proof-of-shape: (f)/(g) DID say UNPROVEN from this same probe
has "$o" "sync parity UNPROVEN" "control: gate (f) still reports the same probe failure (A1)"
# verify.sh's exit contract is ACCEPTED LEGACY (its header, since 1.10.0):
# ">> OK" and ">> REVIEW" BOTH exit 0 and callers map the PRINTED verdict
# (mov.sh/auto.sh/resync.sh/qt-groups.sh -> their own 10). The verdict LINE
# is the API here, so that is what this pin reads — coding it to rc alone is
# the qt-groups defect the 1.11 round fixed.
has "$o" ">> REVIEW" "the printed verdict is REVIEW (verify's API; OK/REVIEW both exit 0)"
[ "$rc" -eq 0 ] && ok "exit 0 per verify's legacy contract (not a FAIL)" || no "rc=$rc (want 0)"

echo
echo "== L2: --audio on a FAILED audio census — UNPROVEN, never 'Skipping' =="
o=$(PATH="$WORK/shimCEN:$PATH" bash "$SC/verify.sh" "$SRC" "$OUT" --audio 2>&1); rc=$?
b=$(block "$o" "-- (--audio)")
[ -n "$b" ] && ok "the --audio block is reached and prints" || no "no --audio block in the output"
hasnt "$b" "output has 0 audio track(s)" "a failed census never becomes a track COUNT of 0"
has "$b" "UNPROVEN" "the block says UNPROVEN"
has "$b" "census probe FAILED" "the block names the probe failure (with its rc)"
# verify.sh's exit contract is ACCEPTED LEGACY (its header, since 1.10.0):
# ">> OK" and ">> REVIEW" BOTH exit 0 and callers map the PRINTED verdict
# (mov.sh/auto.sh/resync.sh/qt-groups.sh -> their own 10). The verdict LINE
# is the API here, so that is what this pin reads — coding it to rc alone is
# the qt-groups defect the 1.11 round fixed.
has "$o" ">> REVIEW" "the printed verdict is REVIEW (verify's API; OK/REVIEW both exit 0)"
[ "$rc" -eq 0 ] && ok "exit 0 per verify's legacy contract (not a FAIL)" || no "rc=$rc (want 0)"

echo
echo "== L2b: discrimination — a REAL single-track output still says 'Skipping' =="
o=$(bash "$SC/verify.sh" "$SRC" "$OUT" --audio 2>&1); rc=$?
b=$(block "$o" "-- (--audio)")
has "$b" "audio track(s)" "a successful census that finds 1 track reports the count"
has "$b" "Skipping" "a legitimate not-dual-track layout is still a plain skip"
hasnt "$b" "UNPROVEN" "a successful census never claims UNPROVEN"

echo
echo "== L3: gate (f) video-duration probe FAILS — announced, never a silent rc 1 =="
o=$(PATH="$WORK/shimVDUR:$PATH" bash "$SC/verify.sh" "$SRC" "$OUT" 2>&1); rc=$?
nv=$(printf '%s\n' "$o" | grep -cE '^>> ' || true)
[ "${nv:-0}" -ge 1 ] && ok "a verdict line is printed (pre-fix: silent ERR abort, zero verdict lines)" \
  || no "no '>> ' verdict line — the run still dies mid-report"
[ "$rc" -ne 1 ] && ok "rc=$rc is not the FAIL code (pre-fix: 1 = 'this file FAILED verification')" \
  || no "rc=1 — an unmeasurable duration is still reported as a FAILED file"
# verify.sh's exit contract is ACCEPTED LEGACY (its header, since 1.10.0):
# ">> OK" and ">> REVIEW" BOTH exit 0 and callers map the PRINTED verdict
# (mov.sh/auto.sh/resync.sh/qt-groups.sh -> their own 10). The verdict LINE
# is the API here, so that is what this pin reads — coding it to rc alone is
# the qt-groups defect the 1.11 round fixed.
has "$o" ">> REVIEW" "the printed verdict is REVIEW (verify's API; OK/REVIEW both exit 0)"
[ "$rc" -eq 0 ] && ok "exit 0 per verify's legacy contract (not a FAIL)" || no "rc=$rc (want 0)"
b=$(block "$o" "-- (f)")
has "$b" "UNPROVEN" "gate (f) says UNPROVEN"
hasnt "$b" "no audio or no stream durations" "a FAILED probe is not the no-declared-duration N/A"
has "$o" "master-purity" "the report continues past gate (f) to the later sections"

echo
echo "== L3b: discrimination — unshimmed, gate (f) measures and the file passes =="
o=$(bash "$SC/verify.sh" "$SRC" "$OUT" 2>&1); rc=$?
b=$(block "$o" "-- (f)")
hasnt "$b" "UNPROVEN" "a working probe never claims UNPROVEN"
{ [ "$rc" -eq 0 ] || [ "$rc" -eq 10 ]; } && ok "the identical copy is not FAILed (rc=$rc)" \
  || no "rc=$rc on a -c copy of the source"

echo
echo "== L4: derive-dts gate 3/4 on a FAILED hash pass — UNPROVEN, not 'not identical' =="
if ! bash "$SC/derive-dts.sh" --help >/dev/null 2>&1 && \
   ! "$HOME/.claude/plugins/data/remuxing-to-mov/venv/bin/python" -c 'import av' >/dev/null 2>&1; then
  echo "  (SKIP: PyAV venv absent — derive-dts.sh exits 10 before its gate battery)"
else
  DD="$WORK/dd.mov"
  o=$(PATH="$WORK/shimHASH:$PATH" bash "$SC/derive-dts.sh" "$SRC" "$DD" --force 2>&1); rc=$?
  if printf '%s\n' "$o" | grepq 'output gate 3/4'; then
    hasnt "$o" "is not identical" "two EMPTY hashes never assert the bitstream differs"
    has "$o" "UNPROVEN" "the gate reports UNPROVEN"
    has "$o" "Kept:" "the .part is kept with its pointer (evidence survives)"
    [ "$rc" -eq 10 ] && ok "REVIEW exit 10 (pre-fix: 1 = condemned on zero evidence)" \
      || no "rc=$rc (want 10)"
    [ ! -f "$DD" ] && ok "nothing is blessed on an unproven gate" || no "$DD was blessed"
    # discrimination 1 — an UNSHIMMED run of this fixture. Its raw hashes DO
    # differ, and pre-WO-1.15.20 that alone was an exit-1 accusation that "the
    # copied bitstream is not identical". MEASURED FALSE: the difference is a
    # dropped ZERO-SIZE flush packet (the rung skips packets carrying no coded
    # picture) plus Annex-B vs avcC framing, and the VCL payloads are
    # byte-identical (`2898a5df…` both sides on this bench, 2026-08-28). The
    # gate now consults the container-neutral arbiter before accusing anyone,
    # so a lossless artifact is no longer condemned for its container's
    # framing — the same class as C3, on a builder's blessing path.
    o2=$(bash "$SC/derive-dts.sh" "$SRC" "$WORK/dd2.mov" --force 2>&1); rc2=$?
    has "$o2" "raw hashes differ" "control: the raw hashes really do differ here"
    has "$o2" "VCL payload identical" "control: …and the arbiter proves the coded pictures are not"
    hasnt "$o2" "PACKET-HASH GATE FAILED" "control: framing alone is never an accusation"
    [ "$rc2" -eq 0 ] && ok "control: a lossless artifact is blessed (rc=0)" || no "control rc=$rc2 (want 0)"
    # discrimination 2 — a REAL essence difference still FAILs, with two
    # NON-EMPTY hashes. Without this the fix above would have removed the
    # gate's teeth instead of its false positives.
    o3=$(PATH="$WORK/shimVCL:$PATH" bash "$SC/derive-dts.sh" "$SRC" "$WORK/dd3.mov" --force 2>&1); rc3=$?
    has "$o3" "PACKET-HASH GATE FAILED" "control: a REAL bitstream difference is still FAILED"
    has "$o3" "is not identical" "control: the accusation survives for real evidence"
    has "$o3" "out VCL=0,v,MD5=00000000" "control: …and prints the NON-empty hashes it judged"
    [ "$rc3" -eq 1 ] && ok "control: a real mismatch still exits 1" || no "control rc=$rc3 (want 1)"
    [ ! -f "$WORK/dd3.mov" ] && ok "control: nothing blessed on a real mismatch" || no "dd3.mov was blessed"
  else
    echo "  (SKIP: derive-dts did not reach gate 3 on this bench — $(printf '%s' "$o" | tail -1))"
  fi
fi

echo
echo "== L6: gate (g)'s SOURCE-side censuses (found by L5's class guard, not the ledger) =="
# A1 captured gate (g)'s OUTPUT census and left three SOURCE/OUTPUT siblings
# in the same gate on `grep -c . || true`. They matter in OPPOSITE directions:
# g_srcaud=0 discards the damage baseline; g_src_mp2=0 DISARMS the naked-MP2
# finding; g_has_pcm=0 ARMS it (accusing a legitimate dual-track file). This
# shim fails only the SOURCE-targeted census queries, so the output census
# above still succeeds and gate (g) runs its full length.
mkdir "$WORK/shimSRC"
cat > "$WORK/shimSRC/ffprobe" <<EOF
#!/bin/bash
case "\$*" in *"aac.ts"*) case "\$*" in *"stream=index"*) exit 1;; esac;; esac
exec "$REAL_FFPROBE" "\$@"
EOF
chmod +x "$WORK/shimSRC/ffprobe"
o=$(PATH="$WORK/shimSRC:$PATH" bash "$SC/verify.sh" "$SRC" "$OUT" 2>&1); rc=$?
b=$(block "$o" "-- (g)")
[ -n "$b" ] && ok "the gate (g) block is reached and prints" || no "no gate (g) block in the output"
has "$b" "source audio census probe FAILED" "the failed SOURCE census is announced"
has "$b" "UNPROVEN, not absent" "a failed census is not a measured absence of tracks"
hasnt "$b" "the source has NO audio track to compare against" \
  "the baseline arm never restates a failed probe as 'no audio to compare against'"
has "$b" "classification census FAILED" "the MP2/PCM classification census failure is announced"
hasnt "$b" "MP2 audio with NO PCM access track" \
  "the naked-MP2 accusation never fires on an unmeasured layout"
# verify.sh's exit contract is ACCEPTED LEGACY (its header, since 1.10.0):
# ">> OK" and ">> REVIEW" BOTH exit 0 and callers map the PRINTED verdict
# (mov.sh/auto.sh/resync.sh/qt-groups.sh -> their own 10). The verdict LINE
# is the API here, so that is what this pin reads — coding it to rc alone is
# the qt-groups defect the 1.11 round fixed.
has "$o" ">> REVIEW" "the printed verdict is REVIEW (verify's API; OK/REVIEW both exit 0)"
[ "$rc" -eq 0 ] && ok "exit 0 per verify's legacy contract (not a FAIL)" || no "rc=$rc (want 0)"

echo
echo "== L5: the class guard — no opt-in census may read a failed probe as a count =="
# `grep -c . || true` on a census is the exact shape this round removed; it
# must not come back at the sites the round owns. Comment lines are stripped
# so the doctrine comments describing the OLD shape do not match themselves.
resid=$(sed 's/#.*//' "$SC/verify.sh" | grep -nE 'select_streams a .*stream=index' | grep -c 'grep -c' || true)
[ "${resid:-0}" -eq 0 ] && ok "no 'grep -c'-counted audio census left in verify.sh" \
  || no "$resid audio-census site(s) still count with grep -c"
resid2=$(sed 's/#.*//' "$SC/derive-dts.sh" | grep -c 'streamhash.*|| true' || true)
[ "${resid2:-0}" -eq 0 ] && ok "derive-dts's streamhash no longer swallows its rc with || true" \
  || no "$resid2 streamhash site(s) still end in || true"

echo
echo "empty-ne-absent-optin-gates: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# 42-rot-demoted.sh — work-order 4.2: the timeline-rot refusal demoted to a
# pre-build warning; the build's own measured gates judge the result.
#
# The 1.8.0–1.10.0 gate refused mpegts/mpeg2video with forward gaps + non-
# monotonic DTS before any build (exit 11, MOV_REFUSED, nothing written) on
# the claim "no lossless MOV of that class survives verify". That was a
# PREDICTION, not a measurement — verify.sh detects bad timelines directly,
# post-build, with evidence, and the mux-confession hard stop (invented
# timing) already refuses at the mux itself. Measured on the constructed rot
# fixture (bench 2026-08-14, ffmpeg 9.0.1): the prediction was wrong twice
# over — the demuxer's own discontinuity fixup muxed a monotonic timeline (no
# confession fired) and verify caught the REAL defect (dual-track access
# misalignment -> REVIEW). 1.11 converts the refusal to a warning carrying
# the refusal's same three routes plus the additive MOV_ROT_WARN machine
# line, then builds and lets verify judge. The mux-confession hard stop
# remains a hard stop — that one is measured, not predicted.
#
# Asserted:
#   1. fixture honesty: ts-health.sh reports BOTH forward gaps and
#      non-monotonic DTS on rot.ts, and the splice dirt stays FINDINGS
#      (never DAMAGED) — the fixture really is the demoted class.
#   2. mov.sh on rot.ts: NEVER a pre-build exit 11, NEVER MOV_REFUSED; the
#      warning carries the three honest routes (keep/playback/rung4) + the
#      MOV_ROT_WARN machine line; a build is ATTEMPTED (artifact or kept
#      .part); and the exit matches the measured verdict — 0 only with
#      ">> OK", 10 only with ">> REVIEW", 1 only with FAIL/HARD-STOP
#      evidence and NO blessed artifact. Nothing gets blessed that verify
#      won't sign.
#   3. corrupt.ts diagnosis unchanged: transport-evidence SOURCE DAMAGED
#      (TEI/PES counters), and its forward-gap class still routes to resync
#      — the demotion touched only the rot verdict.
#   4. the mux-confession hard stop still fires (injected confession log,
#      the suite's RTM_MUX_LOG_APPEND hook): exit 1, output NOT blessed.
#   5. diagnose.sh's rot verdict routes "build + verify will judge (warn)" —
#      no "refuses it up front", no pre-build exit-11 claim — and still
#      warns off resync.sh (the incident-derived advice stays).
#
# Standalone: bash tests/regression.d/42-rot-demoted.sh
# Exit 0 = all assertions pass; 1 = a regression; 2 = env failure.
# Regenerates missing fixtures via make-fixtures.sh. Scratch goes to mktemp
# (auto-cleaned); the repo tree is never written to.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"; FIX="$TESTS/fixtures"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
hasnt () { case "$1" in *"$2"*) no "$3 [unexpected: $2]";; *) ok "$3";; esac; }

for f in rot.ts corrupt.ts; do
  if [ ! -f "$FIX/$f" ]; then
    echo "== regenerating missing fixture: $f =="
    bash "$TESTS/make-fixtures.sh" "$f" || { echo "fixture build failed: $f"; exit 2; }
  fi
  [ -f "$FIX/$f" ] || { echo "fixture $f still missing after make-fixtures"; exit 2; }
done

echo "== 1. fixture honesty: ts-health sees BOTH rot ingredients on rot.ts =="
kv=$(bash "$SC/ts-health.sh" "$FIX/rot.ts" --kv 2>&1) || true
tget () { printf '%s\n' "$kv" | awk -F= -v k="$1" '$1==k{print $2}'; }
gaps=$(tget TSH_GAPS); back=$(tget TSH_BACK); dup=$(tget TSH_DUP)
[ "${gaps:-0}" -ge 1 ] && ok "forward gap(s) reported (TSH_GAPS=$gaps)" \
  || no "no forward gap on rot.ts (TSH_GAPS=${gaps:-?})"
[ $(( ${back:-0} + ${dup:-0} )) -ge 1 ] && ok "non-monotonic DTS reported (back=$back dup=$dup)" \
  || no "no DTS rot on rot.ts (back=${back:-?} dup=${dup:-?})"
has "$kv" "TSH_VERDICT=FINDINGS" "splice dirt stays FINDINGS, never DAMAGED"

echo
echo "== 2. mov.sh on the real rot class: warn + build + measured verdict, never exit 11 =="
o=$(bash "$SC/mov.sh" "$FIX/rot.ts" "$WORK/rot.mov" 2>&1); rc=$?
[ "$rc" -ne 11 ] && ok "no pre-build exit 11 (rc=$rc)" || no "rot still REFUSED pre-build (rc=11)"
hasnt "$o" "MOV_REFUSED" "no MOV_REFUSED line (nothing may refuse and then build)"
has "$o" "** WARN: BACKHAUL TIMELINE ROT" "the demoted gate keeps its voice (WARN)"
has "$o" "MOV_ROT_WARN profile=timeline-rot" "additive MOV_ROT_WARN machine line present"
# the SAME three honest routes the refusal printed (adversarial check (e):
# no demotion may lose its warning)
has "$o" "keep     the source as-is" "route 1: keep (the source is the archival master)"
has "$o" "playback ffmpeg -i" "route 2: playback (lossless MKV)"
has "$o" "rung4    scripts/rung4.sh" "route 3: rung4 (operator-attested re-encode)"
{ [ -f "$WORK/rot.mov" ] || [ -f "$WORK/rot.mov.part" ]; } \
  && ok "a build was ATTEMPTED (artifact or kept .part exists)" \
  || no "no build attempt — the demotion must build, not just warn"
# the exit is the MEASURED verdict, and nothing is blessed that verify won't
# sign: 0 needs ">> OK", 10 needs ">> REVIEW" (evidence above it), 1 needs
# FAIL / HARD-STOP evidence and NO blessed artifact at the final name.
case "$rc" in
  0)
    { case "$o" in *">> OK"*) true;; *) false;; esac && [ -f "$WORK/rot.mov" ]; } \
      && ok "rc=0 is verify-signed (>> OK + artifact)" \
      || no "rc=0 without verify's signature" ;;
  10)
    { case "$o" in *">> REVIEW"*) true;; *) false;; esac && [ -f "$WORK/rot.mov" ]; } \
      && ok "rc=10 carries verify's REVIEW evidence + artifact" \
      || no "rc=10 without REVIEW evidence" ;;
  1)
    { case "$o" in *">> FAIL"*|*"HARD STOP"*) true;; *) false;; esac && [ ! -f "$WORK/rot.mov" ]; } \
      && ok "rc=1 carries FAIL/HARD-STOP evidence and blessed nothing" \
      || no "rc=1 without evidence, or a failed build was blessed" ;;
  *) no "exit $rc outside the contract (want 0|10|1 with evidence)" ;;
esac

echo
echo "== 3. corrupt.ts diagnosis unchanged (damage stays damage) =="
d=$(bash "$SC/diagnose.sh" "$FIX/corrupt.ts" 2>&1); drc=$?
[ "$drc" -eq 0 ] && ok "diagnose exits 0 on corrupt.ts" || no "diagnose rc=$drc on corrupt.ts"
has "$d" "SOURCE DAMAGED" "transport damage still yields SOURCE DAMAGED"
has "$d" "transport counters:" "the damage verdict rests on transport EVIDENCE"
has "$d" "DISCONTINUOUS SOURCE" "corrupt.ts's gap-only timeline still routes as discontinuous"
has "$d" "resync.sh" "…to resync.sh (not swept into the rot demotion)"
hasnt "$d" "BACKHAUL TIMELINE ROT" "no rot verdict on a gap-only (no DTS rot) file"

echo
echo "== 4. the mux-confession hard stop still fires (measured, not predicted) =="
ff () { ffmpeg -nostdin -hide_banner -loglevel error "$@"; }
CT="$WORK/clean.ts"
ff -f lavfi -i "testsrc2=size=320x240:rate=25:duration=3" -c:v libx264 -g 25 \
   -pix_fmt yuv420p -f mpegts "$CT" || { echo "confession fixture mint failed"; exit 2; }
printf '[mov @ 0x1] pts has no value\n[mov @ 0x1] Non-monotonic DTS; previous 5, current 3; changing to 6\nTimestamps are unset in a packet\n' > "$WORK/conf.log"
o=$(RTM_MUX_LOG_APPEND="$WORK/conf.log" bash "$SC/remux.sh" "$CT" "$WORK/hs.mov" 2>&1); rc=$?
{ [ "$rc" -eq 1 ] && case "$o" in *"HARD STOP"*) true;; *) false;; esac; } \
  && ok "injected confession -> HARD STOP, exit 1 (the kept measured gate)" \
  || no "confession hard stop broken (rc=$rc)"
[ -f "$WORK/hs.mov" ] && no "confessed output was blessed to its final name" \
  || ok "confessed output NOT blessed"

echo
echo "== 5. diagnose's rot verdict routes build + verify, not a refusal =="
dr=$(bash "$SC/diagnose.sh" "$FIX/rot.ts" 2>&1) || true
has "$dr" "BACKHAUL TIMELINE ROT" "rot verdict still names the class"
has "$dr" "build + verify will judge" "verdict routes 'build + verify will judge (warn)'"
hasnt "$dr" "refuses it up front" "no 'refuses it up front' claim survives"
hasnt "$dr" "exit 11" "no pre-build exit-11 claim in the rot verdict"
has "$dr" "Do NOT route this to" "the incident-derived resync warning stays"

for f in rot.ts corrupt.ts; do
  [ -f "$FIX/$f" ] || no "fixture $f vanished during the run"
done
ok "sources untouched"

echo
echo "rot-demoted: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

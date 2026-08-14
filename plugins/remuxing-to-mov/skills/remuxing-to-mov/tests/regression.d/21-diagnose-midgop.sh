#!/usr/bin/env bash
# 21-diagnose-midgop.sh — work-order 2.1: diagnose.sh must not call a mid-GOP
# start "damage".
#
# Pins the measured defect (2026-08-13 bench finding, the false-SOURCE-DAMAGED
# class): on a healthy BBC capture that merely JOINED the broadcast mid-GOP,
# diagnose.sh printed "SOURCE DAMAGED (dropped/corrupt packets). No remux
# repairs this. Re-capture." — its 73 "decode-damage" lines were exactly the
# 73 pre-keyframe packets ts-health.sh counts, while every transport corruption
# counter (continuity / TEI / PES mismatch / scrambled) was ZERO. An operator
# trusting that verdict destroys a healthy, irreplaceable capture. The same
# tally also UNDER-detected the real thing: TEI-marked packets are dropped by
# the demuxer before any decoder sees them, so genuine transport rot could
# decode "clean" and dodge the damage verdict entirely.
#
# The fix under test: SOURCE DAMAGED is keyed to transport EVIDENCE (ts-health
# pass-1's counters, computed identically in diagnose step 1); decode noise
# fully explained by the pre-keyframe count is the MID-GOP START class — a
# lossless trim at the first IDR (scripts/trim-to-idr.sh), never "damage".
#
# Asserted here:
#   1. late-sps.ts (mid-GOP head, transport clean) -> MID-GOP START naming the
#      trim-to-idr route; never SOURCE DAMAGED, never Re-capture, and never the
#      old false comfort "timing looks sound" (a plain copy would carry the
#      pre-roll garbage into the .mov);
#   2. gap.ts (clean transport, one forward gap) -> DISCONTINUOUS SOURCE with
#      the resync route; never SOURCE DAMAGED, never a phantom MID-GOP START;
#   3. corrupt.ts (genuine TEI + PES transport rot) -> still SOURCE DAMAGED —
#      the honest positive proving the verdict was narrowed, not deleted — AND
#      the ladder keeps running so the inherited forward gap still gets its
#      DISCONTINUOUS route (damage no longer swallows the timeline verdict);
#   4. every run stays in the exit-code contract: 0 = diagnosis delivered.
#
# Standalone: bash tests/regression.d/21-diagnose-midgop.sh
# Exit 0 = all assertions pass; 1 = a regression; 2 = env/fixture failure.
# Regenerates its fixtures via make-fixtures.sh when missing. Scratch goes to
# mktemp (auto-cleaned); the repo tree is never written to.
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

# fixtures: regenerate any that are missing (media never ships in git)
need=""
for f in late-sps.ts gap.ts corrupt.ts; do [ -f "$FIX/$f" ] || need="$need $f"; done
if [ -n "$need" ]; then
  echo "== regenerating missing fixtures:$need =="
  # shellcheck disable=SC2086  # word splitting is the point
  bash "$TESTS/make-fixtures.sh" $need || { echo "fixture build failed"; exit 2; }
fi

echo "== 1. late-sps.ts: mid-GOP start is pre-roll, not damage =="
out=$(bash "$SC/diagnose.sh" "$FIX/late-sps.ts" 2>&1); rc=$?
has   "$out" "MID-GOP START"      "mid-GOP capture -> MID-GOP START verdict"
has   "$out" "trim-to-idr.sh"     "verdict names the lossless trim route (scripts/trim-to-idr.sh)"
has   "$out" "pre-roll only"      "verdict states the errors are fully explained by pre-roll"
hasnt "$out" "SOURCE DAMAGED"     "no SOURCE DAMAGED on a transport-clean mid-GOP capture"
hasnt "$out" "Re-capture"         "no re-capture advice for healthy pre-roll (the destroyed-capture class)"
hasnt "$out" "timing looks sound" "no plain-copy false comfort (a copy carries the pre-roll garbage)"
[ "$rc" -eq 0 ] && ok "exit 0 (diagnosis delivered)" || no "exit 0 (got $rc)"

echo
echo "== 2. gap.ts: clean transport + forward gap keeps its resync route =="
out=$(bash "$SC/diagnose.sh" "$FIX/gap.ts" 2>&1); rc=$?
has   "$out" "DISCONTINUOUS SOURCE" "gap capture -> DISCONTINUOUS SOURCE verdict"
has   "$out" "resync.sh"            "verdict names the gap-fill route (scripts/resync.sh)"
hasnt "$out" "SOURCE DAMAGED"       "no SOURCE DAMAGED on a transport-clean gap"
hasnt "$out" "MID-GOP START"        "no phantom mid-GOP verdict (capture starts on an IDR)"
[ "$rc" -eq 0 ] && ok "exit 0 (diagnosis delivered)" || no "exit 0 (got $rc)"

echo
echo "== 3. corrupt.ts: genuine transport rot is still called damage =="
out=$(bash "$SC/diagnose.sh" "$FIX/corrupt.ts" 2>&1); rc=$?
has "$out" "SOURCE DAMAGED"        "TEI+PES transport rot -> SOURCE DAMAGED survives the narrowing"
has "$out" "DISCONTINUOUS SOURCE"  "ladder continues past small loss: the gap still gets its route"
[ "$rc" -eq 0 ] && ok "exit 0 (diagnosis delivered)" || no "exit 0 (got $rc)"

echo
echo "diagnose-midgop: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# 109-attempt-not-predicted.sh — TIERS.md T3.1: the ladder EXECUTES its copy
# rung instead of predicting what it would produce.
#
# WHY (measured 2026-08-28/29). auto.sh skipped Rung 0 on any field-coded
# source with unstamped packets, on this reasoning: the MOV muxer cannot write
# a packet with no PTS, so it invents one, so the confession gate refuses the
# output, so the write is a foregone waste. Every clause was plausible. The
# conclusion was false — all nine plain `-c copy` variants return rc=0 and
# write every packet (scripts/attempt-battery.sh measures it on demand). What
# ffmpeg silently produces instead is a WRONG TIMELINE, which is a Tier-2
# defect for the verify suite to catch, not a reason to refuse the attempt.
#
# The cost of being wrong in the two directions is not symmetric. A doomed
# build wastes a pass. A refusal on a false prediction cost this plugin three
# sessions and a 25 GB capture it could in fact convert — and it never
# produced the evidence that would have corrected it, because it never ran.
#
# The prediction is not deleted. It is DEMOTED to what it always was: a
# warning, printed with its measurement, ahead of an attempt that then settles
# the question.
#
# Pins:
#   1. the copy rung is ATTEMPTED on a source with unstamped packets;
#   2. the prediction is announced, with the number it rests on;
#   3. the verdict afterwards cites a GATE and a COUNT, not a forecast;
#   4. "predetermined" has left the tree — the word is the tell;
#   5. no path refuses an attempt on an output-QUALITY prediction (tree sweep);
#   6. escalation still happens; the cut widens what is tried, not what ships.
#
# Standalone: bash tests/regression.d/109-attempt-not-predicted.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"; FIX="$TESTS/fixtures"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
. "$TESTS/lib-harness.sh"

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
hasnt () { case "$1" in *"$2"*) no "$3 [unexpected: $2]";; *) ok "$3";; esac; }

echo "== 1. the copy rung is attempted, not forecast =="
if [ ! -s "$FIX/sparse-orphan.ts" ]; then
  echo "  SKIP: sparse-orphan.ts absent — run: bash tests/make-fixtures.sh sparse-orphan.ts"
else
  o=$(bash "$SC/auto.sh" "$FIX/sparse-orphan.ts" "$WORK/a.mov" 2>&1); rc=$?
  has "$o" "-- attempting Rung 0" "Rung 0 is attempted on a source with unstamped packets"
  hasnt "$o" "skipping Rung 0" "the rung is no longer skipped"
  hasnt "$o" "predetermined" "no verdict is called predetermined"
  # the prediction survives as a WARNING carrying its measurement
  has "$o" "nopts_frac" "the prediction is still announced, with its measurement"
  # and the verdict afterwards is EVIDENCE FROM THE RUN — either the verify
  # block, or the muxer's own confession log, which is a measurement of the
  # attempt and not a forecast about it. Both are the right answer; a forecast
  # is not, and that is what this pins.
  case "$o" in
    *"verify: "*)  ok "the attempt was judged by verify" ;;
    *"HARD STOP"*) ok "the attempt was judged by the muxer's own log — a measurement of the run" ;;
    *)             no "the attempt produced no evidence at all" ;;
  esac
  case "$o" in
    *"HARD STOP"*)
      has "$o" "BUILT, and kept at" "the confession stop says the artifact EXISTS"
      has "$o" "unproven is its TIMELINE" "…and names what is actually unproven"
      has "$o" "scripts/verify.sh" "…and how to settle it on the kept part" ;;
  esac
  # escalation is unchanged: the ladder still moves on
  has "$o" "Rung 3-DERIVE" "the ladder still escalates past the copy rung"
fi

echo
echo "== 2. the word is the tell: 'predetermined' has left the tree =="
pd=""
for f in "$SC"/*.sh "$SC"/*.py; do
  [ -f "$f" ] || continue
  n=$(rtm_strip_comments "$f" | grep -ci 'predetermined' || true)
  [ "${n:-0}" -eq 0 ] || pd="$pd $(basename "$f"):$n"
done
[ -z "$pd" ] && ok "no script calls an unrun outcome predetermined" \
  || no "'predetermined' survives in:$pd"

echo
echo "== 3. no path refuses an attempt on an output-QUALITY prediction =="
# The narrow shape: a refusal whose reason is what the OUTPUT would be like,
# rather than what the tool cannot do. Tier 3's cached-attempt exception is a
# statement about the TOOL; a forecast about the artifact is not.
bad=""
for f in "$SC"/*.sh; do
  [ -f "$f" ] || continue
  code=$(rtm_strip_comments "$f")
  printf '%s\n' "$code" | grepqe 'would be (full-length|a waste|wasted)|foregone (refusal|verdict|hard-stop)|refusal is (predetermined|certain|guaranteed)' \
    && bad="$bad $(basename "$f")"
done
[ -z "$bad" ] && ok "no script refuses on a forecast about its own output" \
  || no "output-quality forecasts still gate an attempt in:$bad"

echo
echo "== 4. the measured replacement exists and answers the question =="
[ -x "$SC/attempt-battery.sh" ] || [ -f "$SC/attempt-battery.sh" ] \
  && ok "scripts/attempt-battery.sh is present — the measured answer to 'does the mux fail?'" \
  || no "no attempt-battery.sh: the prediction was removed with nothing to replace it"
if [ -f "$SC/attempt-battery.sh" ]; then
  S="$WORK/s.ts"
  ffmpeg -nostdin -y -v error -f lavfi -i testsrc2=s=160x120:r=25 -t 1 \
    -c:v libx264 -g 25 -bf 0 -pix_fmt yuv420p -f mpegts "$S" 2>/dev/null
  o=$(bash "$SC/attempt-battery.sh" "$S" --seconds 1 2>&1); rc=$?
  [ "$rc" -eq 0 ] && ok "the battery runs (exit 0)" || { no "battery rc=$rc"; printf '%s\n' "$o" | tail -4; }
  has "$o" "AB_VARIANTS=9" "all nine remux variants are attempted"
  has "$o" "AB_RC0=" "…and the count that actually succeeded is reported"
  has "$o" "MUXED this source" "the verdict is a measurement of what happened"
fi

echo
echo "attempt-not-predicted: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

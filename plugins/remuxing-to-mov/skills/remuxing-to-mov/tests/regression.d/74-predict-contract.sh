#!/usr/bin/env bash
# 74-predict-contract.sh — 1.15.2 Defect B: the prediction pre-pass must model
# the mux it predicts.
#
# Through 1.15.1 rewrap_predict ran `-f null -` with -copyts and without the
# build's muxdelay/muxpreload/layout options — a different mux than the one
# that runs. Field measurement: predicted 0 collision sites, build observed 11
# (the contract gate would have FAILED a fully-explained build). Reproduced
# synthetically on this bench with an overlapping-concat timeline: old
# pre-pass 0, real mpegts build 50, mirrored dry run 50.
#
# Pins (all RELATIONSHIPS, never a literal count — the 1.15.0 CI-fix rule):
#   1. on a collision-bearing timeline, predicted > 0 AND predicted ==
#      observed for the exact zero-base build command (red on 1.15.1: the
#      null-muxer pre-pass predicts 0 there);
#   2. on a clean source, predicted == observed == 0 (no false prediction);
#   3. the surgical-cut shape — bsf filters + RW_PREDICT_IN_OPTS (-copyts) +
#      RW_PREDICT_OUT_OPTS (-output_ts_offset) — predicts its own build too
#      (the filtered path is the one Tier 2 depends on).
#
# The collision fixture: a .ffconcat listing one clean clip twice with a
# deliberately short declared duration — the concat demuxer then overlaps the
# second segment's timestamps onto the first's, and the mpegts muxer must
# nudge every colliding DTS. Media-cheap (one 4 s clip + a text file) and
# deterministic per bench, which is all a relationship pin needs.
#
# Standalone: bash tests/regression.d/74-predict-contract.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
ff () { ffmpeg -nostdin -hide_banner -loglevel error "$@"; }

. "$SC/lib-probe.sh"
. "$SC/lib-rewrap.sh"

echo "== fixtures: clean clip + overlapping-concat collision timeline =="
CLIP="$WORK/clip.ts"; CAT="$WORK/overlap.ffconcat"
ff -f lavfi -i "testsrc2=s=320x240:r=25" -t 4 -c:v libx264 -g 25 -bf 2 \
   -pix_fmt yuv420p -f mpegts "$CLIP" || { echo "fixture mint failed"; exit 2; }
printf 'ffconcat version 1.0\nfile clip.ts\nduration 2\nfile clip.ts\n' > "$CAT"

# the build side of the contract: zero-base.sh's exact command, log harvested
# with the same counter the scripts use
build_obs () { # $1 in, $2 out -> echoes observed nudge count
  local log="$WORK/mux.log"
  ffmpeg -nostdin -y -hide_banner -nostats -v warning "${FF_INPUT_OPTS[@]}" -i "$1" \
    -map 0 -c copy -muxdelay 0 -muxpreload 0 \
    ${RW_STREAMID_OPTS[@]+"${RW_STREAMID_OPTS[@]}"} \
    ${RW_MUX_OPTS[@]+"${RW_MUX_OPTS[@]}"} \
    -f mpegts "$2" 2>"$log" || true
  rewrap_nudges "$log"
}

echo
echo "== 1. collision timeline: predicted > 0 and predicted == observed =="
rewrap_layout "$CAT"
PRED=$(rewrap_predict "$CAT")
OBS=$(build_obs "$CAT" "$WORK/b1.ts")
[ "${PRED:-0}" -gt 0 ] && ok "pre-pass sees the collision sites (predicted=$PRED)" \
  || no "pre-pass predicted 0 on a colliding timeline (the 1.15.1 null-muxer blindness)"
[ "${PRED:-x}" = "${OBS:-y}" ] && ok "predicted == observed ($PRED == $OBS)" \
  || no "contract breach: predicted $PRED, build observed $OBS"

echo
echo "== 2. clean source: predicted == observed == 0 =="
rewrap_layout "$CLIP"
PRED2=$(rewrap_predict "$CLIP")
OBS2=$(build_obs "$CLIP" "$WORK/b2.ts")
{ [ "${PRED2:-x}" = "0" ] && [ "${OBS2:-y}" = "0" ]; } \
  && ok "no false prediction on a clean source (0 == 0)" \
  || no "clean source predicted=$PRED2 observed=$OBS2 (want 0 == 0)"

echo
echo "== 3. the surgical-cut shape: filtered + mirrored extra opts =="
FILTV='noise=drop=lt(n\,10)'
rewrap_layout "$CLIP"
RW_PREDICT_IN_OPTS=(-copyts)
RW_PREDICT_OUT_OPTS=(-output_ts_offset 0)
PRED3=$(rewrap_predict "$CLIP" "$FILTV")
log3="$WORK/mux3.log"
ffmpeg -nostdin -y -hide_banner -nostats -v warning "${FF_INPUT_OPTS[@]}" \
  "${RW_PREDICT_IN_OPTS[@]}" -i "$CLIP" -map 0 -c copy -bsf:v "$FILTV" \
  "${RW_PREDICT_OUT_OPTS[@]}" -muxdelay 0 -muxpreload 0 \
  ${RW_STREAMID_OPTS[@]+"${RW_STREAMID_OPTS[@]}"} \
  ${RW_MUX_OPTS[@]+"${RW_MUX_OPTS[@]}"} \
  -f mpegts "$WORK/b3.ts" 2>"$log3" || true
OBS3=$(rewrap_nudges "$log3")
[ "${PRED3:-x}" = "${OBS3:-y}" ] && ok "filtered prediction matches the filtered build ($PRED3 == $OBS3)" \
  || no "filtered path breach: predicted $PRED3, observed $OBS3"

echo
echo "predict-contract: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

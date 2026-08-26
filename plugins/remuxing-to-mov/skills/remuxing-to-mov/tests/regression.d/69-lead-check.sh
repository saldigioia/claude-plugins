#!/usr/bin/env bash
# 69-lead-check.sh — 1.15 Phase 3: black-lead detection.
#
# Pins the black-lead signature detector on a constructed lead (1.4s black +
# program splice on a forced keyframe, audio hot throughout):
#   1. DETECTION: verdict=lead, the black run counted in frames and seconds,
#      exit 10 (the FINDINGS convention);
#   2. ADDRESSING: the splice keyframe named by PACKET INDEX + PTS ticks —
#      the surgical-cut currency — and the index equals the frame count of
#      the black lead (every lead frame is one packet on this fixture);
#   3. HONESTY: audio measured HOT across the splice and the discarded-audio
#      seconds stated; the route names surgical-cut.sh WITH --discard-content
#      (Tier 2 is quoted, never silent);
#   4. NO FALSE POSITIVE: a bright-from-frame-0 source -> verdict=clean,
#      exit 0, no cut suggested.
#
# Standalone: bash tests/regression.d/69-lead-check.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
hasnt () { case "$1" in *"$2"*) no "$3 [unexpected: $2]";; *) ok "$3";; esac; }
ff () { ffmpeg -nostdin -hide_banner -loglevel error "$@"; }

echo "== fixtures =="
BL="$WORK/blacklead.ts"; CL="$WORK/clean.ts"
ff -f lavfi -i "color=black:s=320x240:r=25:d=1.4" \
   -f lavfi -i "testsrc2=s=320x240:r=25:d=3" \
   -f lavfi -i "sine=440:d=4.4" \
   -filter_complex "[0:v][1:v]concat=n=2:v=1:a=0[v]" -map "[v]" -map 2:a \
   -c:v libx264 -g 25 -bf 2 -pix_fmt yuv420p -force_key_frames 1.4 -c:a mp2 -f mpegts "$BL"
ff -f lavfi -i "testsrc2=s=320x240:r=25" -f lavfi -i "sine=440" -t 3 \
   -c:v libx264 -g 25 -bf 2 -pix_fmt yuv420p -c:a mp2 -f mpegts "$CL"

echo
echo "== 1+2+3. the constructed lead is found, addressed, and honestly priced =="
out=$(bash "$SC/lead-check.sh" "$BL" 2>&1); rc=$?
[ "$rc" -eq 10 ] && ok "lead -> exit 10 (findings)" || no "lead exit $rc (want 10)"
line=$(printf '%s\n' "$out" | grep '^LEADCHECK_SUMMARY ') || true
[ -n "$line" ] && ok "LEADCHECK_SUMMARY emitted" || no "LEADCHECK_SUMMARY missing"
gp () { printf '%s\n' "$line" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -1; }
[ "$(gp verdict)" = lead ] && ok "verdict=lead" || no "verdict=$(gp verdict)"
nb=$(gp black_frames); bs=$(gp black_secs); si=$(gp splice_idx)
[ "$nb" = 35 ] && ok "black run counted exactly (35 frames = 1.4s at 25fps)" || no "black_frames=$nb (want 35)"
awk "BEGIN{d=($bs)-1.4; if(d<0)d=-d; exit !(d<0.1)}" && ok "black_secs ~1.4 ($bs)" || no "black_secs=$bs"
[ "$si" = "$nb" ] && ok "splice packet index ($si) == black frame count (the exact address)" \
  || no "splice_idx=$si != black_frames=$nb"
case "$(gp splice_pts_t)" in ''|na) no "splice_pts_t missing";; *) ok "splice PTS in ticks ($(gp splice_pts_t)) — the audio-drop currency";; esac
[ "$(gp audio_hot)" = yes ] && ok "audio measured HOT under the black" || no "audio_hot=$(gp audio_hot)"
ad=$(gp audio_discard_s)
awk "BEGIN{exit !(($ad) > 0.5)}" && ok "discarded-audio seconds stated ($ad)" || no "audio_discard_s=$ad"
has "$out" "surgical-cut.sh" "route names surgical-cut.sh"
has "$out" '--discard-content' "route quotes the Tier-2 consent flag"
has "$out" "DISCARDS DECODABLE MEDIA" "Tier 2 stated in words"

echo
echo "== 4. no false positive on a bright source =="
out=$(bash "$SC/lead-check.sh" "$CL" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "clean -> exit 0" || no "clean exit $rc"
has "$out" "verdict=clean" "verdict=clean"
hasnt "$out" "surgical-cut.sh" "no cut suggested on a clean head"

echo
echo "lead-check: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# 75-zero-base-paff-refusal.sh — 1.15.2 Item C: zero-base refuses
# pair-timestamped PAFF at PRE-FLIGHT, before any whole-file work.
#
# Field measurement (2022-08-28 source): a TS->TS copy of the pair-timestamped
# shape makes the mpegts muxer confess 'Timestamps are unset' — the
# invented-timing hard-stop class — so 1.15.1 burned a 54 s whole-file scan
# plus a 23.68 GB build to reach a foregone refusal, chasing 40 ms on a
# start_time every player rebases away.
#
# Pins:
#   1. half_ts profile (pf_detect's PF_PKT_FILE hook — real PAFF cannot be
#      minted in a sandbox) -> exit 2, nothing written;
#   2. the refusal names pairfill-paff.sh as the route;
#   3. it fires at pre-flight: no floor announcement, no prediction pre-pass,
#      no ts-health scan output in the transcript.
# (The no-false-refusal control is 68-zero-base.sh: its full-timestamp fixture
# must keep passing pre-flight and building.)
#
# Standalone: bash tests/regression.d/75-zero-base-paff-refusal.sh
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

echo "== fixture: clean TS + injected half-timestamped pair profile =="
S="$WORK/src.ts"
ff -f lavfi -i "testsrc2=s=320x240:r=25" -f lavfi -i "sine=1000" -t 3 \
   -c:v libx264 -g 25 -pix_fmt yuv420p -c:a mp2 -f mpegts "$S" || { echo "fixture mint failed"; exit 2; }
# the house half-ts injection (same table 64-routing feeds pf_detect):
# alternating real / N/A rows -> nopts fraction 0.5 -> half_ts=yes
awk 'BEGIN{for(i=0;i<120;i++){printf "%.6f,%.6f\nN/A,N/A\n", i*0.033367, i*0.033367}}' > "$WORK/pair.csv"

echo
echo "== pair-timestamped PAFF -> pre-flight refusal, nothing written =="
out=$(PF_PKT_FILE="$WORK/pair.csv" bash "$SC/zero-base.sh" "$S" "$WORK/nope.ts" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "exit 2 (usage/pre-flight class)" || no "rc=$rc (want 2)"
has "$out" "pairfill-paff.sh" "the refusal names the pairfill route"
has "$out" "Timestamps are unset" "the refusal names the measured hard-stop class"
found=$(find "$WORK" -name 'nope*' | head -1)
[ -z "$found" ] && ok "nothing written (no output, no .part)" || no "refusal left bytes behind: $found"
hasnt "$out" "FLOOR" "refused before the floor announcement"
hasnt "$out" "prediction pre-pass" "refused before the prediction pre-pass"
hasnt "$out" "whole-file health scan" "refused before the whole-file ts-health scan"

echo
echo "zero-base-paff-refusal: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

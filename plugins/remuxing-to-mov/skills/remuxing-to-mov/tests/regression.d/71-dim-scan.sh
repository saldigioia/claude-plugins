#!/usr/bin/env bash
# 71-dim-scan.sh — 1.15 Phase 4: the mid-stream resolution-change detector
# (the detection half of the known-limits "mid-stream SPS / resolution change"
# entry, which measured that NOTHING catches this class: probe, the copy mux,
# verify's gates and playable-check all pass while stsd lies about half the
# samples).
#
# Pins, on the known-limits fixture recipe (320x240 + 640x480 MPEG-2 ES
# concatenated into one TS stream):
#   1. DETECTION: exactly 1 change found, both resolutions listed, the splice
#      PTS named, exit 10;
#   2. ROUTES: cut-at-the-splice and do-not-remux-across-the-junction both
#      named (source-domain routes only);
#   3. NO FALSE POSITIVE: a single-resolution file -> CLEAN, exit 0;
#   4. CONTRACT: missing file -> exit 2; DIMSCAN_SUMMARY fields present.
#
# Standalone: bash tests/regression.d/71-dim-scan.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
ff () { ffmpeg -nostdin -hide_banner -loglevel error "$@"; }

echo "== fixtures (the known-limits splice recipe) =="
ff -f lavfi -i "testsrc2=s=320x240:r=25" -t 2 -c:v mpeg2video -b:v 1M -pix_fmt yuv420p -f mpeg2video "$WORK/a.m2v"
ff -f lavfi -i "testsrc2=s=640x480:r=25" -t 2 -c:v mpeg2video -b:v 1M -pix_fmt yuv420p -f mpeg2video "$WORK/b.m2v"
cat "$WORK/a.m2v" "$WORK/b.m2v" > "$WORK/ab.m2v"
# genpts: ffmpeg 9 refuses a copy mux of the raw ES into mpegts without it
ff -fflags +genpts -r 25 -f mpegvideo -i "$WORK/ab.m2v" -c copy -f mpegts "$WORK/splice.ts"
ff -f lavfi -i "testsrc2=s=320x240:r=25" -t 2 -c:v mpeg2video -b:v 1M -pix_fmt yuv420p -f mpegts "$WORK/uni.ts"

echo
echo "== 1+2. the splice is found, addressed, routed =="
out=$(bash "$SC/dim-scan.sh" "$WORK/splice.ts" 2>&1); rc=$?
[ "$rc" -eq 10 ] && ok "change found -> exit 10" || no "change exit $rc (want 10)"
line=$(printf '%s\n' "$out" | grep '^DIMSCAN_SUMMARY ') || true
[ -n "$line" ] && ok "DIMSCAN_SUMMARY emitted" || no "DIMSCAN_SUMMARY missing"
gp () { printf '%s\n' "$line" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -1; }
[ "$(gp changes)" = 1 ] && ok "exactly 1 change counted" || no "changes=$(gp changes)"
[ "$(gp dims)" = "320x240,640x480" ] && ok "both resolutions listed in order" || no "dims=$(gp dims)"
case "$(gp first_change_pts)" in ''|na) no "splice PTS missing";; *) ok "splice PTS named ($(gp first_change_pts)s)";; esac
has "$out" "MID-STREAM RESOLUTION CHANGE" "the class is named"
has "$out" "stsd" "the stsd-lies consequence is stated"
has "$out" "surgical-cut.sh" "cut route named"
has "$out" "do NOT remux across the junction" "keep route named"

echo
echo "== 3+4. clean control + contract =="
out=$(bash "$SC/dim-scan.sh" "$WORK/uni.ts" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "single resolution -> exit 0 CLEAN" || no "clean exit $rc"
has "$out" "changes=0" "changes=0 on the control"
bash "$SC/dim-scan.sh" "$WORK/nope.ts" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "missing file -> exit 2" || no "missing file rc=$rc"

echo
echo "dim-scan: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# 72-clean.sh — 1.15 Phase 5: the source-clinic driver.
#
# Pins the driver's contract:
#   1. REPORT-ONLY: on a black-lead + shifted fixture it finds both classes,
#      prints the Tier-1 zero-base command and RELAYS lead-check's Tier-2
#      surgical-cut command (with --discard-content quoted), writes NOTHING,
#      exits 10;
#   2. TIER SEPARATION: the zero-base route is labeled Tier 1 and the cut
#      Tier 2 — the consent model is visible in the report;
#   3. ROT ROUTING HONESTY: a rot source (the constructed rot fixture) routes
#      to diagnose.sh, and zero-base is NOT offered on it;
#   4. deep passes are opt-in: without --deep, dim-scan does not run; with
#      --deep on a spliced fixture the resolution change lands as a finding.
#
# Standalone: bash tests/regression.d/72-clean.sh
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
ff () { ffmpeg -nostdin -hide_banner -loglevel error "$@"; }

echo "== fixtures =="
BL="$WORK/blacklead.ts"
ff -f lavfi -i "color=black:s=320x240:r=25:d=1.4" \
   -f lavfi -i "testsrc2=s=320x240:r=25:d=3" \
   -f lavfi -i "sine=440:d=4.4" \
   -filter_complex "[0:v][1:v]concat=n=2:v=1:a=0[v]" -map "[v]" -map 2:a \
   -c:v libx264 -g 25 -bf 2 -pix_fmt yuv420p -force_key_frames 1.4 -c:a mp2 -f mpegts "$BL"
if [ ! -f "$FIX/rot.ts" ]; then
  bash "$TESTS/make-fixtures.sh" rot.ts || { echo "fixture build failed"; exit 2; }
fi
ff -f lavfi -i "testsrc2=s=320x240:r=25" -t 2 -c:v mpeg2video -b:v 1M -pix_fmt yuv420p -f mpeg2video "$WORK/a.m2v"
ff -f lavfi -i "testsrc2=s=640x480:r=25" -t 2 -c:v mpeg2video -b:v 1M -pix_fmt yuv420p -f mpeg2video "$WORK/b.m2v"
cat "$WORK/a.m2v" "$WORK/b.m2v" > "$WORK/ab.m2v"
ff -fflags +genpts -r 25 -f mpegvideo -i "$WORK/ab.m2v" -c copy -f mpegts "$WORK/splice.ts"

echo
echo "== 1+2. black-lead fixture: both findings, both tiers, nothing written =="
before=$(ls "$WORK" | sort)
out=$(bash "$SC/clean.sh" "$BL" 2>&1); rc=$?
[ "$rc" -eq 10 ] && ok "findings -> exit 10" || no "findings exit $rc (want 10)"
has "$out" "TIER 1" "zero-base offered as Tier 1"
has "$out" "zero-base.sh" "zero-base command printed"
has "$out" "TIER 2" "cut labeled Tier 2"
has "$out" "surgical-cut.sh" "surgical-cut command relayed"
has "$out" '--discard-content' "the consent flag is quoted in the relayed command"
has "$out" "routes=zero-base,surgical-cut" "CLEAN_SUMMARY routes both"
after=$(ls "$WORK" | sort)
[ "$before" = "$after" ] && ok "report-only: nothing written" || no "the driver wrote files"

echo
echo "== 3. rot source: diagnose named, zero-base withheld =="
out=$(bash "$SC/clean.sh" "$FIX/rot.ts" 2>&1); rc=$?
[ "$rc" -eq 10 ] && ok "rot -> findings exit 10" || no "rot exit $rc"
has "$out" "diagnose.sh" "timeline defects route to diagnose.sh"
hasnt "$out" "TIER 1 (structural): scripts/zero-base.sh" "zero-base NOT offered on a rotten timeline"

echo
echo "== 4. deep is opt-in =="
out=$(bash "$SC/clean.sh" "$WORK/splice.ts" 2>&1)
has "$out" "deep passes skipped" "no --deep -> dim-scan skipped"
has "$out" "deep=no" "CLEAN_SUMMARY deep=no"
out=$(bash "$SC/clean.sh" "$WORK/splice.ts" --deep 2>&1); rc=$?
has "$out" "mid-stream resolution change" "--deep surfaces the dimension change as a finding"
has "$out" "deep=yes" "CLEAN_SUMMARY deep=yes"
[ "$rc" -eq 10 ] && ok "spliced --deep -> exit 10" || no "spliced --deep exit $rc"

echo
echo "clean: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

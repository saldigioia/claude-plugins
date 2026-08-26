#!/usr/bin/env bash
# 68-zero-base.sh — 1.15 Phase 2: the zero-base re-wrap + the prediction
# contract.
#
# Pins:
#   1. THE REBASE: a fat-offset TS (custom PIDs + PMT) zero-bases to a start
#      near the floor, byte-identical (verify-source OK inside the run), with
#      the announced floor doctrine and ZB_SUMMARY carrying the numbers;
#   2. LAYOUT PRESERVATION: non-default stream PIDs and the PMT pid survive
#      the re-wrap (the case-file -streamid/-mpegts_pmt_start_pid recipe);
#   3. THE PREDICTION CONTRACT is announced (predicted == observed printed);
#   4. REFUSALS, nothing written: non-mpegts (matroska) -> exit 2 naming the
#      remux ladder; timeline rot (the constructed rot fixture) -> exit 2
#      naming diagnose.sh (zero-base is not a timeline repair); multi-program
#      -> exit 2 naming the isolate-program route; source==output -> exit 2.
#
# Standalone: bash tests/regression.d/68-zero-base.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"; FIX="$TESTS/fixtures"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
ff () { ffmpeg -nostdin -hide_banner -loglevel error "$@"; }

echo "== fixtures =="
S="$WORK/shifted.ts"
ff -f lavfi -i "testsrc2=s=320x240:r=25" -f lavfi -i "sine=1000" -t 4 \
   -c:v libx264 -g 25 -bf 2 -pix_fmt yuv420p -c:a mp2 \
   -output_ts_offset 25 -streamid 0:3050 -streamid 1:3051 \
   -mpegts_pmt_start_pid 305 -f mpegts "$S"
ST=$(ffprobe -v error -show_entries format=start_time -of default=nw=1:nk=1 "$S" | head -1)
awk "BEGIN{exit !(($ST) > 20)}" || { echo "fixture start_time not shifted ($ST)"; exit 2; }
if [ ! -f "$FIX/rot.ts" ]; then
  echo "== regenerating missing fixture: rot.ts =="
  bash "$TESTS/make-fixtures.sh" rot.ts || { echo "fixture build failed"; exit 2; }
fi
ff -y -i "$WORK/shifted.ts" -map 0 -c copy "$WORK/side.mkv"
ff -f lavfi -i "testsrc2=s=160x120:r=25" -f lavfi -i "sine=1000:r=48000" \
   -f lavfi -i "testsrc2=s=320x240:r=25" -f lavfi -i "sine=500:r=48000" -t 2 \
   -map 0:v -map 1:a -map 2:v -map 3:a -c:v mpeg2video -b:v 1M -c:a mp2 -pix_fmt yuv420p \
   -program title=P1:program_num=1:st=0:st=1 -program title=P2:program_num=2:st=2:st=3 \
   -f mpegts "$WORK/twoprog.ts"

echo
echo "== 1+2+3. the rebase: floor announced, prediction reconciled, PIDs preserved =="
out=$(bash "$SC/zero-base.sh" "$S" "$WORK/zb.ts" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "zero-base exit 0" || no "zero-base exit 0 (got $rc)"
has "$out" "FLOOR:" "the floor is announced BEFORE the build"
has "$out" "refused on doctrine" "exact-zero refusal stated up front"
has "$out" "observed nudges=" "prediction contract reconciled in the log"
has "$out" ">> OK" "verify-source battery ran and passed inside the run"
line=$(printf '%s\n' "$out" | grep '^ZB_SUMMARY ') || true
[ -n "$line" ] && ok "ZB_SUMMARY emitted" || no "ZB_SUMMARY missing"
gp () { printf '%s\n' "$line" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -1; }
so=$(gp start_out); pn=$(gp predicted_nudges); on=$(gp observed_nudges)
awk "BEGIN{exit !(($so) < 0.5)}" && ok "start_time rebased to near zero ($ST -> $so)" \
  || no "start_time not rebased: $so"
[ "$pn" = "$on" ] && ok "predicted_nudges == observed_nudges ($pn)" || no "prediction breach shipped ($pn != $on)"
pids=$(ffprobe -v error -show_entries stream=id -of csv=p=0 "$WORK/zb.ts" 2>/dev/null | sort -u | grep . | paste -sd, -)
case "$pids" in *0xbea*|*0xbeb*) ok "custom stream PIDs preserved (3050/3051 = $pids)";; *) no "PIDs not preserved: $pids";; esac
pmt=$(ffprobe -v error -show_entries program=pmt_pid -of csv=p=0 "$WORK/zb.ts" 2>/dev/null | head -1 | tr -d ,)
[ "$pmt" = 305 ] && ok "PMT pid preserved (305)" || no "PMT pid not preserved: $pmt"
[ -f "$S" ] && ok "source untouched" || no "source deleted"

echo
echo "== 4. refusals: nothing written, the right route named =="
out=$(bash "$SC/zero-base.sh" "$WORK/side.mkv" "$WORK/nope1.ts" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "matroska -> exit 2 (pre-flight)" || no "matroska rc=$rc (want 2)"
has "$out" "remux.sh" "non-mpegts refusal names the remux ladder"
[ ! -f "$WORK/nope1.ts" ] && ok "matroska refusal writes nothing" || no "matroska refusal wrote a file"
out=$(bash "$SC/zero-base.sh" "$FIX/rot.ts" "$WORK/nope2.ts" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "timeline rot -> exit 2 (zero-base is not a timeline repair)" || no "rot rc=$rc (want 2)"
has "$out" "diagnose.sh" "rot refusal routes to diagnose.sh"
[ ! -f "$WORK/nope2.ts" ] && ok "rot refusal writes nothing" || no "rot refusal wrote a file"
out=$(bash "$SC/zero-base.sh" "$WORK/twoprog.ts" "$WORK/nope3.ts" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "multi-program -> exit 2" || no "multi-program rc=$rc (want 2)"
has "$out" "-map 0:p:" "multi-program refusal names the isolate-program route"
bash "$SC/zero-base.sh" "$S" "$S" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "source==output -> exit 2" || no "source==output rc=$rc"

echo
echo "zero-base: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

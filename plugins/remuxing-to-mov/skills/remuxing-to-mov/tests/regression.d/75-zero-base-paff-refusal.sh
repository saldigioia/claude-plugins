#!/usr/bin/env bash
# 75-zero-base-paff-refusal.sh — TIERS.md T3.3: zero-base WARNS about a
# field-coded source and builds; it no longer refuses one at pre-flight.
#
# WHAT THIS TEST USED TO ASSERT, and why it changed. From 1.15.2 (Item C) to
# 1.15.20 this file pinned a REFUSAL: a pair-timestamped PAFF source exited 2
# with nothing written, because a measured field run had spent 23.68 GB to
# reach a hard stop for a prize of 40 ms on a start_time players rebase away.
# The measurement was real and it is still quoted below. The INFERENCE — that
# the outcome was therefore known and the attempt could be skipped — is the
# one this plugin retired on 2026-08-29, after the same reasoning refused a
# 25 GB capture across three sessions that it turns out could be converted.
#
# So the prediction stays and the refusal goes: the warning is printed with its
# measurement, the build is attempted, and the mux-confession stop plus
# verify-source.sh judge the artifact that exists. An operator who wants the
# old answer without the build asks for it: --preflight-only.
#
# NOTHING DOWNSTREAM IS LOOSENED, and §4 is what pins that: the confession
# stop still refuses to bless an invented timeline.
#
# Pins:
#   1. a pair-timestamped PAFF source is WARNED about, not refused;
#   2. the warning carries the measurement it rests on, and says it is not a refusal;
#   3. the build is actually attempted (the floor, the pre-pass, the scan all run);
#   4. an invented timeline is still NOT blessed — the artifact is kept as .part;
#   5. --preflight-only still answers without building, and now reports the warning;
#   6. the full-timestamp control (68-zero-base.sh) still builds cleanly.
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
echo "== 1. the field-coded profile WARNS and proceeds =="
out=$(PF_PKT_FILE="$WORK/pair.csv" bash "$SC/zero-base.sh" "$S" "$WORK/o.ts" 2>&1); rc=$?
has "$out" "WARNING (not a refusal)" "the profile is announced as a warning, in those words"
has "$out" "pair-timestamped PAFF" "…naming the measured profile"
has "$out" "Timestamps are unset" "…and the measured hard-stop class it may hit"
has "$out" "23.68 GB" "…with the field measurement that motivated the old refusal"
has "$out" "pairfill-paff.sh" "the QuickTime route is still named"
has "$out" "--preflight-only" "…and so is the way to get this verdict without building"
[ "$rc" -ne 2 ] && ok "it is not a pre-flight refusal any more (rc=$rc, not 2)" || no "still refusing at pre-flight (rc=2)"

echo
echo "== 2. the build was actually attempted =="
has "$out" "FLOOR" "the floor announcement ran (the pre-flight no longer short-circuits)"
has "$out" "whole-file health scan" "the whole-file ts-health scan ran"
case "$out" in
  *"prediction pre-pass"*|*"predicted"*) ok "the prediction pre-pass ran" ;;
  *) no "the prediction pre-pass did not run" ;;
esac

echo
echo "== 3. the verdict is about the artifact, not a forecast =="
case "$rc" in
  0)  ok "the build completed and was blessed (rc=0) — the forecast was wrong, and now we know" ;;
  1)  ok "the build was attempted and NOT blessed (rc=1) — the forecast was right, and now it is evidence" ;;
  10) ok "the build was attempted and landed REVIEW (rc=10)" ;;
  *)  no "unexpected rc=$rc from an attempted build" ;;
esac
hasnt "$out" "refusing at pre-flight" "no pre-flight refusal language survives on this path"

echo
echo "== 4. an invented timeline is still NOT blessed (nothing downstream loosened) =="
case "$out" in
  *"HARD STOP"*)
    hasnt "$out" ">> DONE" "a confessed timeline is never reported DONE"
    has "$out" "NOT blessed" "…and the report says the output was not blessed" ;;
  *)
    ok "(this fixture's build did not trip the confession stop — §4's lane does not apply)" ;;
esac

echo
echo "== 5. --preflight-only still answers without building, and carries the warning =="
out=$(PF_PKT_FILE="$WORK/pair.csv" bash "$SC/zero-base.sh" "$S" --preflight-only 2>&1); rc=$?
has "$out" "ZB_PREFLIGHT" "the machine row is emitted"
has "$out" "warn=yes" "…flagging that this source carries a warning"
has "$out" "ZB_PREFLIGHT_WARN" "…and naming it, so a caller (clean.sh) can relay it"
found=$(find "$WORK" -name 'nope*' -o -name '*.part*' | head -1)
[ -z "$found" ] && ok "--preflight-only wrote nothing" || no "--preflight-only left bytes: $found"

echo
echo "zero-base-paff-refusal: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

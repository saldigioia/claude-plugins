#!/usr/bin/env bash
# 83-c7-mov-review-passthrough.sh — CHECKUP-2026-08-27 C7 / WO-1.15.4:
# mov.sh must SURVIVE a child's exit 10 — remux.sh's sanctioned REVIEW, whose
# own text says "verify gates (f)/(g) judge audio. Building on; exit will say
# 10" — and still run verify, print MOV_SUMMARY and its own verdict line.
#
# Pre-fix (measured via the RTM_MUX_LOG_APPEND hook): remux.sh direct rc=10
# correct; through mov.sh the bare builder call under set -e died at the call
# site — rc=10 with NO verify, NO playability check, NO MOV_SUMMARY, NO
# verdict line, trim_cleanup skipped. A REVIEW artifact shipped with the whole
# gate battery silently skipped.
#
# The injected child REVIEW: an audio-attributed DTS-nudge confession
# ([aost#…] Non-monotonic DTS — the ms-quantization class), which remux.sh
# classifies MC_AUDSUB and exits 10 after blessing the complete artifact.
# The AAC source rides mov.sh's MODE=copy arm -> remux.sh (the hooked child).
#
# Pins: 1. control — remux.sh direct still exits 10 on the same injection;
# 2. through mov.sh: rc=10 AND "-- verify --" ran AND MOV_SUMMARY printed AND
# the ">> REVIEW" verdict line closes the run; the builder-REVIEW floor is
# announced (an OK verify cannot outrank the child's own 10).
#
# Standalone: bash tests/regression.d/83-c7-mov-review-passthrough.sh
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

echo "== fixture: AAC TS (mov.sh MODE=copy -> remux.sh) + audio-confession log =="
S="$WORK/aac.ts"
ff -f lavfi -i testsrc2=s=320x240:r=25 -f lavfi -i sine=440 -t 3 \
   -c:v libx264 -g 25 -pix_fmt yuv420p -c:a aac -f mpegts "$S" || { echo "mint failed"; exit 2; }
printf '[aost#0:1 @ 0x7f8] Non-monotonic DTS; previous 100, current 90; changing to 101\n' > "$WORK/aud.log"

echo
echo "== 1. control: remux.sh direct exits 10 (sanctioned REVIEW) on the injection =="
o=$(RTM_MUX_LOG_APPEND="$WORK/aud.log" bash "$SC/remux.sh" "$S" "$WORK/direct.mov" 2>&1); rc=$?
{ [ "$rc" -eq 10 ] && [ -f "$WORK/direct.mov" ]; } \
  && ok "remux direct: audio confession -> blessed artifact + exit 10" \
  || no "remux direct wrong (rc=$rc; the injection did not arm)"
has "$o" "exit will say 10" "remux's own text promises the 10"

echo
echo "== 2. through mov.sh: the 10 continues into the gate battery =="
o=$(RTM_MUX_LOG_APPEND="$WORK/aud.log" bash "$SC/mov.sh" "$S" "$WORK/m.mov" 2>&1); rc=$?
[ "$rc" -eq 10 ] && ok "mov.sh exits 10" || no "mov.sh rc=$rc (want 10)"
has "$o" "builder exited 10" "the sanctioned REVIEW is announced, not died on"
has "$o" "-- verify --" "verify RAN (pre-fix: verify ran 0)"
has "$o" "MOV_SUMMARY" "MOV_SUMMARY printed (pre-fix: absent)"
has "$o" ">> REVIEW" "mov.sh's own verdict line closes the run (pre-fix: none)"
[ -f "$WORK/m.mov" ] && ok "the REVIEW artifact is at OUT" || no "artifact missing"
# the floor: verify said OK on this clean copy, but the builder's 10 stands
has "$o" "builder's own REVIEW (exit 10) stands" "an OK verify cannot outrank the child's 10"
hasnt "$o" ">> DONE" "never DONE over a builder REVIEW"

echo
echo "== 3. no regression: the unhooked build is still DONE, exit 0 =="
o=$(bash "$SC/mov.sh" "$S" "$WORK/clean.mov" 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && case "$o" in *">> DONE"*) true;; *) false;; esac; } \
  && ok "clean AAC copy -> DONE exit 0" || no "clean path regressed (rc=$rc)"

echo
echo "c7-mov-review-passthrough: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

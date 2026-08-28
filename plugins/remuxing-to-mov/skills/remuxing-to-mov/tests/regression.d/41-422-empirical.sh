#!/usr/bin/env bash
# 41-422-empirical.sh — work-order 4.1: the 4:2:2 refusal demoted to an
# empirical post-build playability check.
#
# The 1.8.0–1.10.0 backhaul gate refused mpeg2video/h264 + yuv422p at every
# .mov-writing entry point (exit 11, nothing built), claiming "AVFoundation/
# QuickTime cannot decode 4:2:2". FALSIFIED on the bench 2026-08-13 (macOS
# 26.6.1, ffmpeg 8.1.2): both refused classes fully decode — qlmanage
# thumbnail AND avconvert whole-file (50/50 frames) — as do 10-bit 4:2:2,
# 10-bit 4:4:4, and HEVC Rext 4:2:2. And the exact 8-bit predicate let the
# ACTUAL 10-bit contribution profiles (yuv422p10le, AVC-Intra class) bypass
# the gate entirely: over-broad and under-broad at once, with the whole
# deliverable as the cost of being wrong. 1.11 demotes the verdict to
# prove-don't-guess: announce the profile (yuv422p*, all bit depths), build,
# then run playable-check.sh on the OUTPUT — fail/unverifiable -> 10 REVIEW,
# a passing build stays 0 DONE.
#
# Asserted:
#   1. every F5 fixture (m2v422.mov, m2v422.ts, h264_422.ts, h264_422_10.ts,
#      hevc_422_10.mov) BUILDS through mov.sh with the contribution advisory
#      and the additive MOV_PLAYABILITY machine line, and never a MOV_REFUSED.
#      On a macOS bench with qlmanage: exit 0 + verdict=ok (the verdict is a
#      property of the OS it ran on — Ground Rule 6; this pins TODAY's bench).
#      Elsewhere: exit 10 + verdict=skip + the explicit "playability
#      unverified on this platform" REVIEW note (announced downgrade).
#   2. the 4:2:0 control (m2v420.ts) still builds DONE with NO advisory and
#      NO MOV_PLAYABILITY line — the empirical check runs only when the
#      contribution profile made it due, so ordinary builds pay nothing.
#   3. grep-audit: no scripts/*.sh retains a pix_fmt-based refusal — no
#      "profile=qt-undecodable" machine line anywhere, and no exit/return-11
#      statement within reach of a live (non-comment) yuv422p predicate.
#      (The 1.10.0 "no side door builds it" property inverts: no side door
#      REFUSES either.)
#
# Standalone: bash tests/regression.d/41-422-empirical.sh
# Exit 0 = all assertions pass; 1 = a regression; 2 = env failure.
# Regenerates missing fixtures via make-fixtures.sh. Scratch goes to mktemp
# (auto-cleaned); the repo tree is never written to.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"; FIX="$TESTS/fixtures"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }

. "$TESTS/lib-harness.sh"   # grepq/grepqe + rtm_strip_comments: one definition (tests/lib-harness.sh)
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
hasnt () { case "$1" in *"$2"*) no "$3 [unexpected: $2]";; *) ok "$3";; esac; }

F5="m2v422.mov m2v422.ts h264_422.ts h264_422_10.ts hevc_422_10.mov"
for f in $F5 m2v420.ts; do
  if [ ! -f "$FIX/$f" ]; then
    echo "== regenerating missing fixture: $f =="
    bash "$TESTS/make-fixtures.sh" "$f" || { echo "fixture build failed: $f"; exit 2; }
  fi
  [ -f "$FIX/$f" ] || { echo "fixture $f still missing after make-fixtures"; exit 2; }
done

# the bench split: verdicts self-date their OS (Ground Rule 6). A macOS bench
# with qlmanage must prove ok + DONE; anywhere else the honest answer is
# skip + REVIEW, and this suite asserts THAT instead of pretending.
if [ "$(uname -s)" = Darwin ] && command -v qlmanage >/dev/null 2>&1; then BENCH=mac; else BENCH=other; fi
echo "== 1. every F5 fixture builds + gets the empirical verdict (bench: $BENCH) =="

run_f5 () { # run_f5 FIXTURE EXPECTED_VC/PIX
  local name="$1" prof="$2" o rc
  o=$(bash "$SC/mov.sh" "$FIX/$name" "$WORK/${name%.*}.out.mov" 2>&1); rc=$?
  if [ "$BENCH" = mac ]; then
    { [ "$rc" -eq 0 ] && [ -f "$WORK/${name%.*}.out.mov" ]; } \
      && ok "$name: builds DONE (rc=0) on this bench" \
      || { no "$name: rc=$rc, want 0 (bench decodes 4:2:2 — falsified refusal must not resurface)"
           printf '%s\n' "$o" | grep -E '^>>|MOV_PLAYABILITY|MOV_REFUSED' | sed 's/^/   /'; }
    has "$o" "verdict=ok" "$name: MOV_PLAYABILITY verdict=ok on this bench"
  else
    { [ "$rc" -eq 10 ] && [ -f "$WORK/${name%.*}.out.mov" ]; } \
      && ok "$name: builds + honest REVIEW (rc=10) off-macOS" \
      || no "$name: rc=$rc, want 10 (artifact + announced unverified-platform REVIEW)"
    has "$o" "verdict=skip" "$name: MOV_PLAYABILITY verdict=skip off-macOS"
    has "$o" "playability unverified on this platform" "$name: the unverified-platform note is explicit"
  fi
  has "$o" "contribution profile $prof — playability will be verified post-build" \
      "$name: advisory announces $prof"
  has "$o" "MOV_PLAYABILITY os=" "$name: machine line present"
  hasnt "$o" "MOV_REFUSED" "$name: no MOV_REFUSED anywhere"
}
run_f5 m2v422.mov     "mpeg2video/yuv422p"
run_f5 m2v422.ts      "mpeg2video/yuv422p"
run_f5 h264_422.ts    "h264/yuv422p"
run_f5 h264_422_10.ts "h264/yuv422p10le"      # bypassed the old exact-match gate
run_f5 hevc_422_10.mov "hevc/yuv422p10le"     # Rext: outside the old codec list

echo
echo "== 2. the 4:2:0 control pays nothing (check runs only when due) =="
o=$(bash "$SC/mov.sh" "$FIX/m2v420.ts" "$WORK/ctl.mov" 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [ -f "$WORK/ctl.mov" ]; } \
  && ok "m2v420.ts control still builds DONE (rc=0)" || no "control broken (rc=$rc)"
hasnt "$o" "contribution profile" "control: no advisory on 4:2:0"
hasnt "$o" "MOV_PLAYABILITY" "control: no playability pass on 4:2:0 (only-when-due)"

echo
echo "== 3. grep-audit: no pix_fmt-based refusal (exit-11) path survives anywhere =="
# comment-stripped + basenames: an un-stripped grep is satisfied by a comment
# recording that 1.11 REMOVED this line (measured FALSE-POSITIVE 2026-08-28,
# tests/mutation-audit.sh case P13).
qtu=""
for _f in "$SC"/*.sh; do
  rtm_strip_comments "$_f" | grepq "profile=qt-undecodable" && qtu="$qtu $(basename "$_f")"
done
[ -z "$qtu" ] && ok "no script emits MOV_REFUSED profile=qt-undecodable" \
  || no "qt-undecodable refusal line still present in: $qtu"
# shape audit: a live (non-comment) yuv422p line followed within 8 lines by an
# exit/return-11 STATEMENT (line-anchored — prose mentions of 'exit 11' in
# echo text are messaging, not control flow) is the old refusal pattern.
shape_bad=0
for f in "$SC"/*.sh; do
  hit=$(awk '
    { t=$0; sub(/^[[:space:]]*/,"",t) }
    t !~ /^#/ && t ~ /yuv422p/ { last=NR }
    t ~ /^(exit|return)[[:space:]]+11([^0-9]|$)/ { if (last && NR-last<=8) print FILENAME": line "NR }
  ' "$f")
  [ -n "$hit" ] && { echo "   refusal shape: $hit"; shape_bad=1; }
done
[ "$shape_bad" -eq 0 ] && ok "no exit/return-11 within reach of a live yuv422p predicate in scripts/*.sh" \
  || no "a pix_fmt-refusal shape survives (above)"

for f in $F5 m2v420.ts; do
  [ -f "$FIX/$f" ] || no "fixture $f vanished during the run"
done
ok "sources untouched"

echo
echo "422-empirical: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

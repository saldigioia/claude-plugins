#!/usr/bin/env bash
# 54-probe-advisories.sh — work-order 5.4 carry-forward (folded in by 6.3): the
# two named-limit advisory surfaces probe.sh shipped hand-verified but without
# regression coverage, because 5.4's file list excluded tests/. The fixture
# recipes come straight from references/known-limits.md (the 5.4 deliverable).
#
# The two surfaces under test (probe.sh, the WO 5.4 advisory block):
#   * MULTI-PROGRAM TS: every route maps -map 0:v:0 = the first video in
#     PAT/PMT order, the other programs' VIDEO is never mapped (silently —
#     the KEEP/DROP manifest covers audio only) while every program's AUDIO
#     survives keep-all. The advisory exists so the session knows the mux is
#     CHOOSING a program, not taking "the" video.
#   * 33-BIT PTS WRAP HORIZON: MPEG-TS PTS wraps every ~26.5 h; ffmpeg unwraps
#     ONE rollover, >=2 (~53 h) is the named limitation. The advisory fires
#     at >24 h so a long capture gets told before the mux, not after.
#
# NOT covered here, stated honestly (the regression.sh SYNTHESIS-LIMIT
# tradition): the mid-stream SPS/resolution-change class from the same 5.4
# pass has NO warning surface to pin — known-limits.md records it as
# "detect-and-warn candidate, not implemented" (nothing catches it today;
# the measured splice build is documented there). When that scan lands, its
# fixture recipe is already written down; a test pinning the ABSENCE of a
# feature would be noise, so none is added.
#
# Asserted:
#   1. a constructed 2-program TS (the known-limits reproduce recipe): probe's
#      human mode prints the NOTE with the real program count and the
#      -map 0:p:N route out; exit 0 (advisory, never a verdict change).
#   2. the advisory's factual basis re-measured (the known-limits claims):
#      a default remux of that TS lands the FIRST PAT program's video
#      (320x240) with BOTH programs' audio (keep-all crosses programs), and
#      the same streams declared in the REVERSED program order flip the
#      winner to 640x480 — declared order decides, nothing editorial.
#      If a future ffmpeg reorders demuxed streams, this catches the drift
#      and the advisory text needs re-measuring, not deleting.
#   3. a >24 h source (a 3 s mp4 stretched via -itsscale — cheap, no 24 h
#      encode): probe prints the wrap-horizon NOTE naming ~26.5 h and the
#      verify.sh gate-(d) proof route; exit 0.
#   4. controls: a short single-program file prints NEITHER advisory (the
#      notes fire only when due).
#
# Standalone: bash tests/regression.d/54-probe-advisories.sh
# Exit 0 = all assertions pass; 1 = a regression; 2 = env failure.
# All fixtures are minted here in mktemp scratch (auto-cleaned); the shared
# tests/fixtures corpus and the repo tree are never written to.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
FFE () { ffmpeg -nostdin -y -v error "$@"; }

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
hasnt () { case "$1" in *"$2"*) no "$3 [unexpected: $2]";; *) ok "$3";; esac; }
vwidth () { ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=nw=1:nk=1 "$1" 2>/dev/null | awk 'NR==1'; }
nauds () { ffprobe -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 "$1" 2>/dev/null | grep -c . || true; }

# fixtures (the known-limits.md reproduce recipes, minted into scratch)
# two programs, P1(320x240)+P2(640x480), each with its own AAC — and the same
# four streams declared in the reversed program order for the flip proof
FFE -f lavfi -i "testsrc2=s=320x240:r=25:d=3" -f lavfi -i "sine=frequency=1000:d=3" \
    -f lavfi -i "testsrc2=s=640x480:r=25:d=3" -f lavfi -i "sine=frequency=500:d=3" \
    -map 0:v -map 1:a -map 2:v -map 3:a -c:v mpeg2video -b:v 1M -c:a aac \
    -program title=P1:program_num=1:st=0:st=1 -program title=P2:program_num=2:st=2:st=3 \
    -f mpegts "$WORK/twoprog.ts" \
  || { echo "cannot mint the 2-program TS (mpeg2video/aac missing?)"; exit 2; }
FFE -f lavfi -i "testsrc2=s=320x240:r=25:d=3" -f lavfi -i "sine=frequency=1000:d=3" \
    -f lavfi -i "testsrc2=s=640x480:r=25:d=3" -f lavfi -i "sine=frequency=500:d=3" \
    -map 0:v -map 1:a -map 2:v -map 3:a -c:v mpeg2video -b:v 1M -c:a aac \
    -program title=P2:program_num=2:st=2:st=3 -program title=P1:program_num=1:st=0:st=1 \
    -f mpegts "$WORK/twoprog_rev.ts" \
  || { echo "cannot mint the reversed-order TS"; exit 2; }
# >24 h without a 24 h encode: stretch a 3 s clip's timestamps 40000x (~33 h)
FFE -f lavfi -i "testsrc2=s=160x120:r=25:d=3" -c:v libx264 -preset ultrafast \
    -g 25 -pix_fmt yuv420p "$WORK/short.mp4" \
  || { echo "cannot mint short.mp4 (libx264 missing?)"; exit 2; }
FFE -itsscale 40000 -i "$WORK/short.mp4" -c copy "$WORK/long.mp4" \
  || { echo "cannot stretch via -itsscale"; exit 2; }

echo "== 1. multi-program TS: the advisory names the count and the route out =="
out=$(bash "$SC/probe.sh" "$WORK/twoprog.ts" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "probe exits 0 (advisory, not a verdict change)" || no "probe rc=$rc on the 2-program TS"
has "$out" "NOTE 2 programs in this mux" "NOTE fires with the real program count"
has "$out" "FIRST video in PAT/PMT order wins" "NOTE states the selection rule"
has "$out" "-map 0:p:N" "NOTE names the isolate-a-program route out"
has "$out" "references/known-limits.md" "NOTE points at the measured write-up"

echo
echo "== 2. the advisory's factual basis holds (known-limits measurements) =="
out=$(bash "$SC/remux.sh" "$WORK/twoprog.ts" "$WORK/fwd.mov" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "default remux of the 2-program TS builds (rc=0)" \
  || { no "fwd remux rc=$rc"; printf '%s\n' "$out" | tail -4 | sed 's/^/   /'; }
[ "$(vwidth "$WORK/fwd.mov")" = 320 ] \
  && ok "first PAT program's video wins (320x240)" \
  || no "fwd video width=$(vwidth "$WORK/fwd.mov"), want 320 (PAT order no longer decides?)"
[ "$(nauds "$WORK/fwd.mov")" -eq 2 ] \
  && ok "keep-all crosses programs: BOTH programs' audio lands (2 tracks)" \
  || no "fwd audio tracks=$(nauds "$WORK/fwd.mov"), want 2 (keep-all lost a program's audio)"
bash "$SC/remux.sh" "$WORK/twoprog_rev.ts" "$WORK/rev.mov" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "reversed-order remux builds (rc=0)" || no "rev remux rc=$rc"
[ "$(vwidth "$WORK/rev.mov")" = 640 ] \
  && ok "reversed declaration flips the winner (640x480) — declared order decides" \
  || no "rev video width=$(vwidth "$WORK/rev.mov"), want 640 (re-measure the advisory's basis)"

echo
echo "== 3. wrap horizon: a >24 h source gets the 33-bit advisory =="
out=$(bash "$SC/probe.sh" "$WORK/long.mp4" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "probe exits 0 on the long source" || no "probe rc=$rc on long.mp4"
has "$out" "(>24 h): 33-bit PTS wraps at ~26.5 h" "NOTE names the wrap horizon past 24 h"
has "$out" "unwraps ONE rollover" "NOTE states the one-rollover repair limit"
has "$out" "verify.sh gate (d)" "NOTE routes to the timeline proof, not a promise"

echo
echo "== 4. controls: neither advisory fires when not due =="
out=$(bash "$SC/probe.sh" "$WORK/short.mp4" 2>&1) || true
hasnt "$out" "programs in this mux" "single-program short file: no program NOTE"
hasnt "$out" "33-bit PTS wraps" "3 s short file: no wrap NOTE"

echo
echo "probe-advisories: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

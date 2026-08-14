#!/usr/bin/env bash
# 25-seam-check-ffmpeg9.sh — Phase 2 fix round: seam-check.sh must survive the
# ffmpeg-9 bench and never die silently when its scene scan fails.
#
# Pins the 2026-08-14 bench break: homebrew moved ffmpeg 8.1.2 -> 9.0.1
# mid-work-order, and ffmpeg 9 removed the long-deprecated global -vsync
# option. seam-check.sh's scene scan passed `-vsync passthrough` — the
# plugin's ONLY -vsync occurrence — so the extraction pass died "Unrecognized
# option 'vsync'", the error was swallowed by `|| true`, sc.txt was never
# written, and the `read < <(awk ...)` EOF'd under set -e: an opaque rc=1
# with NO verdict and NO diagnostic (suite section 15 fell 234/237). Two
# fixes under test:
#   - `-fps_mode passthrough` (the per-stream replacement, ffmpeg >= 5.1, so
#     valid on both the old 8.1.2 bench and 9.0.1) in place of -vsync;
#   - the silent-death guard: a scene scan that produces no usable sc.txt now
#     prints a named diagnostic and exits 1 DELIBERATELY (contract FAIL),
#     instead of dying bare (house rule: every failure announces itself).
#
# Asserted here:
#   1. a clean all-IDR continuous join -> rc=0, the SEAMS CLEAN verdict, and a
#      real scene-score line (proves the scan itself ran on this bench — the
#      exact thing the -vsync removal broke);
#   2. no LIVE `-vsync` occurrence anywhere in scripts/ — comment-only WHY
#      mentions exempt (pins the sweep: a prior agent verified the other
#      ffmpeg-9 removals — -async, -map_channel, -deinterlace, -vol, -sameq —
#      are absent too; this stops a future backport reintroducing the option);
#   3. a hostile (non-media) input -> rc=1 AND the named scene-scan diagnostic,
#      never the old silent set -e death, never a bogus analyzed verdict.
#
# Standalone: bash tests/regression.d/25-seam-check-ffmpeg9.sh
# Exit 0 = all assertions pass; 1 = a regression; 2 = env/fixture failure.
# Fixtures are minted here in mktemp scratch (auto-cleaned); the repo tree and
# the shared tests/fixtures corpus are never written to.
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
FFE () { ffmpeg -nostdin -y -v error "$@"; }

echo "== 1. clean continuous join: the scene scan works on this bench =="
# All-IDR clip split + copy-concat -> the segments abut with no overlap however
# -ss/-to round (same rationale as suite section 15's clean-join fixture).
CIDR="$WORK/cidr.mp4"
FFE -f lavfi -i testsrc2=s=160x120:r=25 -t 2 -c:v libx264 -g 1 -keyint_min 1 \
    -x264opts scenecut=0 -pix_fmt yuv420p "$CIDR" \
  || { echo "fixture build failed (libx264 missing?)"; exit 2; }
FFE -ss 0 -to 1.0 -i "$CIDR" -c copy "$WORK/sa.mp4"
FFE -ss 1.0 -i "$CIDR" -c copy "$WORK/sb.mp4"
printf "file '%s'\nfile '%s'\n" "$WORK/sa.mp4" "$WORK/sb.mp4" > "$WORK/cj.txt"
FFE -f concat -safe 0 -i "$WORK/cj.txt" -c copy "$WORK/cjoin.mp4"
sadur=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$WORK/sa.mp4" 2>/dev/null)
out=$(bash "$SC/seam-check.sh" "$WORK/cjoin.mp4" "${sadur:-1.0}" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "clean join -> exit 0 (DONE)" || no "clean join -> exit 0 (got $rc)"
has "$out" "SEAMS CLEAN" "verdict line delivered (SEAMS CLEAN)"
# the analysis line differs by branch (tiny peak vs. legit-cut PSNR triage) —
# either proves sc.txt was written AND read, i.e. the scan really ran:
case "$out" in
  *"peak scene score"*|*"peak change @"*) ok "scene scores computed (sc.txt written and read)";;
  *) no "scene scores computed [missing: peak scene score / peak change @]";;
esac

echo
echo "== 2. the removed option is gone from scripts/ (backport pin) =="
# Comment-only lines are exempt: the house-style WHY block at the fix site
# names -vsync by design. The pin targets executable text — any line that is
# not a pure comment. (A trailing-comment mention after live code still flags;
# fail-safe in the right direction.)
sweep=$(grep -rn -e '-vsync' "$SC" 2>/dev/null | grep -v -e ':[0-9][0-9]*:[[:space:]]*#' || true)
if [ -n "$sweep" ]; then
  no "no live -vsync anywhere in scripts/ (ffmpeg 9 removed it)"
  printf '%s\n' "$sweep" | sed 's/^/   /'
else
  ok "no live -vsync anywhere in scripts/ (ffmpeg 9 removed it)"
fi

echo
echo "== 3. hostile input: the guard announces, never a silent death =="
# A non-media file: the scene scan cannot produce sc.txt. Before the guard,
# seam-check died bare at the read — rc=1 with no verdict and no diagnostic.
printf 'this is not a movie, it is a text file wearing a .mov extension\n' > "$WORK/garbage.mov"
out=$(bash "$SC/seam-check.sh" "$WORK/garbage.mov" 1.0 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "hostile input -> deliberate exit 1 (contract FAIL)" || no "hostile input -> exit 1 (got $rc)"
has   "$out" "seam-check: scene scan failed" "named diagnostic printed (no silent death)"
has   "$out" "cannot analyze"                "diagnostic says analysis was impossible"
hasnt "$out" "SEAM PROBLEM"                  "no bogus analyzed verdict (guard exits before it)"
hasnt "$out" "SEAMS CLEAN"                   "no false clean verdict on an unanalyzable input"

echo
echo "seam-check-ffmpeg9: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

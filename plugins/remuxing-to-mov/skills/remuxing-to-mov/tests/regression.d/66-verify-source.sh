#!/usr/bin/env bash
# 66-verify-source.sh — 1.15 Phase 1: the source-domain verification battery.
#
# Pins the four properties verify-source.sh exists to prove (the feed.ts case
# file's battery as a unit):
#   1. IDENTITY: a plain same-container re-wrap (TS->TS -c copy) verifies OK —
#      per-stream hashes match, census identical, zero drops, exit 0;
#   2. FILTERED REFERENCE: a deterministic bsf cut (noise=drop by video packet
#      index + audio PTS threshold, -copyts + -output_ts_offset) verifies OK
#      when the verifier is handed the IDENTICAL filters — the hash equality
#      proves the mux added/altered/reordered nothing, and the expected census
#      is MEASURED from the filtered source (framecrc pass), never trusted;
#   3. TAMPER: an output with ONE extra packet dropped beyond the declared
#      plan FAILs (hash mismatch + census mismatch — exit 1), and the same cut
#      verified WITHOUT filters FAILs too (a cut is not an identity);
#   4. CONTRACT: MP4-family outputs are refused toward verify.sh (exit 2);
#      cross-pins (--expect-vdrop) and duration arithmetic hold.
#
# Standalone: bash tests/regression.d/66-verify-source.sh
# Exit 0 = all assertions pass; 1 = a regression; 2 = env failure.
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

# the noise bsf is the cut mechanism under test — without it there is nothing to pin
ffmpeg -hide_banner -bsfs 2>/dev/null | grep -qw noise || { echo "this ffmpeg lacks the noise bsf"; exit 2; }

echo "== fixtures =="
S="$WORK/src.ts"
ff -f lavfi -i "testsrc2=s=320x240:r=25" -f lavfi -i "sine=1000" -t 4 \
   -c:v libx264 -g 25 -bf 2 -pix_fmt yuv420p -c:a mp2 -f mpegts "$S"
# 2nd keyframe = the deterministic cut address (packet index + pts ticks),
# read from a census exactly as the doctrine prescribes — never seeked
read -r KIDX KPTS < <(ffprobe -v error -select_streams v:0 -show_entries packet=pts,flags -of csv=p=0 "$S" | \
  awk -F, 'index($2,"K"){n++; if(n==2){print NR-1, $1; exit}}')
[ -n "${KIDX:-}" ] && [ -n "${KPTS:-}" ] || { echo "fixture has no 2nd keyframe"; exit 2; }
FIRST_VPTS=$(ffprobe -v error -select_streams v:0 -read_intervals '%+#1' -show_entries packet=pts -of csv=p=0 "$S" | head -1 | tr -d ,)
TRIM=$(awk "BEGIN{printf \"%.3f\", ($KPTS-($FIRST_VPTS))/90000}")
OFF=$(awk "BEGIN{printf \"%.3f\", -($KPTS)/90000 + 0.08}")
FV="noise=drop=lt(n\,$KIDX)"; FA="noise=drop=lt(pts\,$KPTS)"
ff -y -copyts -i "$S" -map 0 -c copy -bsf:v "$FV" -bsf:a "$FA" \
   -output_ts_offset "$OFF" -muxdelay 0 -muxpreload 0 -f mpegts "$WORK/cut.ts"
ff -y -i "$S" -map 0 -c copy -muxdelay 0 -muxpreload 0 -f mpegts "$WORK/rewrap.ts"
ff -y -copyts -i "$S" -map 0 -c copy -bsf:v "noise=drop=lt(n\,$KIDX)+eq(n\,$((KIDX+20)))" -bsf:a "$FA" \
   -output_ts_offset "$OFF" -muxdelay 0 -muxpreload 0 -f mpegts "$WORK/tampered.ts"
ff -y -i "$S" -map 0:v:0 -c copy -movflags +faststart -f mov "$WORK/out.mov"
echo "  (cut address: video packet $KIDX, pts $KPTS ticks; trim ${TRIM}s)"

echo
echo "== 1. identity: plain TS->TS re-wrap verifies OK =="
out=$(bash "$SC/verify-source.sh" "$S" "$WORK/rewrap.ts" 2>&1); rc=$?
has "$out" ">> OK" "identity re-wrap -> OK"
[ "$rc" -eq 0 ] && ok "identity exit 0" || no "identity exit 0 (got $rc)"
has "$out" "hash=match" "SRCV_SUMMARY reports hash=match"
has "$out" "v_drop=0" "zero video drops on identity"

echo
echo "== 2. filtered reference: the declared cut verifies OK =="
out=$(bash "$SC/verify-source.sh" "$S" "$WORK/cut.ts" \
        --filter-v "$FV" --filter-a "$FA" --trim-head "$TRIM" --expect-vdrop "$KIDX" 2>&1); rc=$?
has "$out" ">> OK" "declared cut -> OK"
[ "$rc" -eq 0 ] && ok "declared cut exit 0" || no "declared cut exit 0 (got $rc)"
has "$out" "MEASURED from the filtered source" "expected census measured, not trusted"
has "$out" "v_drop=$KIDX" "video drop count matches the plan"

echo
echo "== 3. tamper + undeclared cut both FAIL =="
out=$(bash "$SC/verify-source.sh" "$S" "$WORK/tampered.ts" \
        --filter-v "$FV" --filter-a "$FA" --trim-head "$TRIM" 2>&1); rc=$?
has "$out" ">> FAIL" "one extra dropped packet -> FAIL"
[ "$rc" -eq 1 ] && ok "tamper exit 1" || no "tamper exit 1 (got $rc)"
out=$(bash "$SC/verify-source.sh" "$S" "$WORK/cut.ts" 2>&1); rc=$?
has "$out" ">> FAIL" "cut verified WITHOUT its filters -> FAIL (a cut is not an identity)"
[ "$rc" -eq 1 ] && ok "undeclared cut exit 1" || no "undeclared cut exit 1 (got $rc)"

echo
echo "== 4. contract: MP4-family refused toward verify.sh; wrong cross-pin FAILs =="
out=$(bash "$SC/verify-source.sh" "$S" "$WORK/out.mov" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "MP4-family output -> exit 2" || no "MP4-family output rc=$rc (want 2)"
has "$out" "verify.sh" "refusal names verify.sh as the route"
out=$(bash "$SC/verify-source.sh" "$S" "$WORK/cut.ts" \
        --filter-v "$FV" --filter-a "$FA" --trim-head "$TRIM" --expect-vdrop $((KIDX+1)) 2>&1); rc=$?
has "$out" ">> FAIL" "wrong --expect-vdrop cross-pin -> FAIL"
# the ~1.0s trim hides inside the default 1.5s tolerance — tighten the knob to
# pin both the arithmetic and that RTM_SRCV_DUR_TOL is really wired
out=$(RTM_SRCV_DUR_TOL=0.5 bash "$SC/verify-source.sh" "$S" "$WORK/cut.ts" \
        --filter-v "$FV" --filter-a "$FA" 2>&1); rc=$?
hasnt "$out" ">> OK" "cut without --trim-head -> duration arithmetic refuses a silent trim (tol 0.5)"
[ "$rc" -eq 1 ] && ok "missing trim declaration exit 1" || no "missing trim exit 1 (got $rc)"

echo
echo "verify-source: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

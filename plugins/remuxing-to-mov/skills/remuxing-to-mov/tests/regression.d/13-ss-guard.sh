#!/usr/bin/env bash
# 13-ss-guard.sh — work-order 1.3: --ss origin documented + empty-cut guard.
#
# Pins the measured defect: dual-track.sh --ss is relative to the container's
# start_time, NOT absolute stream PTS. On a start_time=1372.69 capture, passing
# the observed keyframe PTS 1374.27 seeked past EOF and ffmpeg wrote an EMPTY
# file with exit 0 — silent success on nothing. (On other sources the same
# mistake instead died in pass 2 with a baffling "Stream map '' matches no
# streams", littering the .dtcut.tmp.mov behind.) Now the copy-cut pass is
# followed by a guard: the cut must be non-empty AND carry >= 1 video packet,
# else exit 1 (FAIL, contract code) naming the origin:
#   -ss beyond end of file? (--ss is relative to start_time=<val>, not absolute PTS)
# and the partial cut temp must not survive (atomic-output rule).
#
# Asserted here, on the m2v420.ts fixture (MP2 audio -> the dual-track class):
#   1. ACCEPTANCE: --ss <duration+100> exits 1 with the origin message, and
#      NOTHING survives — no OUT, no .part, no .dtcut.tmp.mov litter;
#   2. the message names the file's real start_time (origin spelled out);
#   3. control: a valid --ss still builds (rc 0) with >= 1 video packet and
#      the dual-track shape (PCM access + MP2 original) intact.
#
# Standalone: bash tests/regression.d/13-ss-guard.sh
# Exit 0 = all assertions pass; 1 = a regression; 2 = env/fixture failure.
# Regenerates its fixture via make-fixtures.sh when missing. Scratch goes to
# mktemp (auto-cleaned); the repo tree is never written to.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"; FIX="$TESTS/fixtures"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }

# fixture: regenerate when missing (media never ships in git)
if [ ! -f "$FIX/m2v420.ts" ]; then
  echo "== regenerating missing fixture: m2v420.ts =="
  bash "$TESTS/make-fixtures.sh" m2v420.ts || { echo "fixture build failed"; exit 2; }
fi

dur=$(ffprobe -v error -show_entries format=duration   -of default=nw=1:nk=1 "$FIX/m2v420.ts" 2>/dev/null | head -1)
st=$( ffprobe -v error -show_entries format=start_time -of default=nw=1:nk=1 "$FIX/m2v420.ts" 2>/dev/null | head -1)
[ -n "$dur" ] && [ -n "$st" ] || { echo "cannot probe the fixture"; exit 2; }
past=$(awk "BEGIN{printf \"%.0f\", $dur+100}")

echo "== 1. acceptance: --ss $past (duration+100) FAILs with the origin message, writes nothing =="
out=$(bash "$SC/dual-track.sh" "$FIX/m2v420.ts" "$WORK/eof.mov" --ss "$past" 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "past-EOF --ss exits 1 (FAIL, contract code)" \
  || no "past-EOF --ss rc=$rc, want 1 (pre-1.3 this could be a silent 0 on an empty file)"
has "$out" "-ss beyond end of file?" "guard names the suspicion"
has "$out" "not absolute PTS" "guard states the origin rule"
has "$out" "start_time=$st" "guard reports the file's real start_time ($st)"
[ ! -f "$WORK/eof.mov" ] && ok "no output written" || no "past-EOF --ss left an output file"
[ ! -f "$WORK/eof.mov.part" ] && ok "no .part survives (atomic rule)" || no "a .part survived the guard"
[ ! -f "$WORK/eof.dtcut.tmp.mov" ] && ok "no cut-temp litter survives" || no "the .dtcut.tmp.mov litter survived"
leftover=$(ls "$WORK" 2>/dev/null | grep -c . || true)
[ "${leftover:-0}" -eq 0 ] && ok "workdir empty after the refused cut" \
  || no "guard left $leftover file(s) behind: $(ls "$WORK" | paste -sd, -)"

echo
echo "== 2. control: a valid --ss still builds the dual-track =="
out=$(bash "$SC/dual-track.sh" "$FIX/m2v420.ts" "$WORK/cut.mov" --ss 1 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "valid --ss 1 builds (rc=0)" || no "valid --ss rc=$rc — the guard must not over-fire"
[ -s "$WORK/cut.mov" ] && ok "output written and non-empty" || no "no/empty output on a valid cut"
npkt=$(ffprobe -v error -select_streams v:0 -show_entries packet=dts -of csv=p=0 \
         -read_intervals '%+#1' "$WORK/cut.mov" 2>/dev/null | grep -c . || true)
[ "${npkt:-0}" -ge 1 ] && ok "output carries video packets" || no "valid cut has no video packets"
acods=$(ffprobe -v error -select_streams a -show_entries stream=codec_name -of default=nw=1:nk=1 "$WORK/cut.mov" 2>/dev/null | grep . | paste -sd, -)
case "$acods" in pcm_*,mp2) ok "dual-track shape intact (audio=$acods)";; *) no "dual-track shape wrong: $acods";; esac
[ ! -f "$WORK/cut.dtcut.tmp.mov" ] && ok "cut temp cleaned up on success" || no "cut temp survived a successful build"

echo
echo "ss-guard: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

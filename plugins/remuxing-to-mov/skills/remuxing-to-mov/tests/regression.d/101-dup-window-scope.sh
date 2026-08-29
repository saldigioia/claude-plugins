#!/usr/bin/env bash
# 101-dup-window-scope.sh — WO-1.15.21 B1: a windowed number may not be
# printed as an absolute one, and the whole-file census the refusal points at
# has to actually exist.
#
# WHY (field-measured 2026-08-28). derive-dts.sh's pre-flight printed
# `duplicate-PTS values=0` from a 5,000-packet HEAD window while the whole-file
# truth was 10, and its refusal named scripts/diagnose.sh as the place to go —
# where there was no whole-file duplicate census to find. So the operator was
# told "none" by a scan that had not looked, and sent to a tool that could not
# answer. A window is entitled to say "none here". It is never entitled to say
# "none", and absence is the one claim a sample is worst at.
#
# Pins:
#   1. the windowed line SCOPES every number it prints, at the point of print;
#   2. a windowed zero explicitly says it is not a whole-file zero;
#   3. diagnose's whole-file census reports the count, the values and the
#      coded positions of duplicates the window never saw;
#   4. …and the STRADDLE count — how many duplicates bracket an unstamped run,
#      which is the one line that says "the holes and the repeated timestamps
#      are one discontinuity event, not two";
#   5. the census runs on EVERY diagnose path, including the ones that reach a
#      verdict and exit early (it used to sit below them);
#   6. no false positive: a clean file reports zero, and says so.
#
# Standalone: bash tests/regression.d/101-dup-window-scope.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
command -v python3 >/dev/null || { echo "SKIP: python3 absent"; echo "dup-window-scope: 0 passed, 0 failed"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
hasnt () { case "$1" in *"$2"*) no "$3 [unexpected: $2]";; *) ok "$3";; esac; }
ff () { ffmpeg -nostdin -y -v error "$@"; }

echo "== 0. fixture: holes early, duplicate display slots LATE =="
B="$WORK/base.ts"
ff -f lavfi -i testsrc2=s=160x120:r=25 -t 16 -c:v libx264 -g 25 -bf 2 -pix_fmt yuv420p -f mpegts "$B" \
  || { echo "fixture mint failed"; exit 2; }
NPK=$(ffprobe -v error -select_streams v:0 -show_entries packet=pts -of csv=p=0 "$B" | grep -c . || true)
[ "${NPK:-0}" -ge 200 ] || { echo "SKIP: only ${NPK:-0} video packets minted"; echo "dup-window-scope: 0 passed, 0 failed"; exit 0; }
# two stale timestamps in the TAIL, each bracketing an unstamped run: the
# 2024-VMA signature (a packet carried a value across a discontinuity).
LATE1=$((NPK - 40)); LATE2=$((NPK - 20))
H1=$((LATE1 - 3)); H2=$((LATE1 - 2)); H3=$((LATE2 - 3))
S="$WORK/dup-late.ts"
python3 "$TESTS/sparse-mint.py" "$B" "$S" 900000 1800 "$H1,$H2,$H3" \
  --dups "$((LATE1 - 6)):$LATE1,$((LATE2 - 6)):$LATE2" >/dev/null \
  || { echo "SKIP: the fixture could not be shaped here"; echo "dup-window-scope: 0 passed, 0 failed"; exit 0; }
# prove the fixture IS the shape this test is about, rather than assuming it
read -r WHOLE_DUP WHOLE_NA < <(ffprobe -v error -select_streams v:0 -show_entries packet=pts -of csv=p=0 "$S" 2>/dev/null | \
  awk -F, 'NF{ if($1=="N/A"||$1==""){na++;next} c[$1]++; if(c[$1]>1) d++ } END{print d+0, na+0}')
[ "${WHOLE_DUP:-0}" -ge 1 ] && ok "the fixture carries $WHOLE_DUP duplicate-PTS packet(s) whole-file" \
  || { no "the fixture carries no duplicates — nothing to test"; echo "dup-window-scope: $pass passed, $fail failed"; exit 1; }
[ "${WHOLE_NA:-0}" -ge 1 ] && ok "…and $WHOLE_NA unstamped packet(s) for them to straddle" || no "no unstamped packets minted"

echo
echo "== 1. the windowed line scopes every number it prints =="
# a window narrow enough to sit entirely before the duplicates
o=$(PF_SCAN_WINDOW=40 bash "$SC/derive-dts.sh" "$S" "$WORK/x.mov" 2>&1) || true
has "$o" "packets=" "the windowed census line is printed"
w=$(printf '%s\n' "$o" | grep -m1 'duplicate-PTS values=' || true)
case "$w" in
  *"(in window)"*) ok "the duplicate count is scoped at the point of print" ;;
  "")              no "the windowed census line was not printed at all" ;;
  *)               no "the duplicate count prints unscoped: $w" ;;
esac
case "$(printf '%s\n' "$o" | grep -m1 'N/A-PTS=' || true)" in
  *"(in window)"*) ok "the unstamped count is scoped too" ;;
  *)               no "the unstamped count prints unscoped" ;;
esac

echo
echo "== 2. a windowed zero says it is not a whole-file zero =="
# a window over the clean head: 0 duplicates there, 2 in the file
o=$(PF_SCAN_WINDOW=40 bash "$SC/derive-dts.sh" "$S" "$WORK/y.mov" 2>&1) || true
case "$o" in
  *"duplicate-PTS values=0 (in window)"*)
    has "$o" "is not 0 in the file" "a windowed zero explicitly disclaims the absolute claim" ;;
  *) ok "(this window saw duplicates — the zero-disclaimer lane does not apply here)" ;;
esac

echo
echo "== 3. diagnose's whole-file census finds what the window could not =="
d=$(bash "$SC/diagnose.sh" "$S" 2>&1)
has "$d" "DIAG_PTS_CENSUS" "the machine census row is emitted"
cd_dup=$(printf '%s\n' "$d" | sed -n 's/.*DIAG_PTS_CENSUS .*dup_packets=\([0-9]*\).*/\1/p' | head -1)
cd_na=$(printf '%s\n' "$d" | sed -n 's/.*DIAG_PTS_CENSUS .*nopts=\([0-9]*\).*/\1/p' | head -1)
[ "${cd_dup:-x}" = "${WHOLE_DUP}" ] && ok "the census duplicate count ($cd_dup) is the whole-file truth" \
  || no "census says dup_packets=${cd_dup:-none}, the file has $WHOLE_DUP"
[ "${cd_na:-x}" = "${WHOLE_NA}" ] && ok "the census unstamped count ($cd_na) is the whole-file truth" \
  || no "census says nopts=${cd_na:-none}, the file has $WHOLE_NA"
has "$d" "values:" "the census names the duplicated values"
has "$d" "later holders at coded:" "…and their coded positions"

echo
echo "== 4. the straddle finding: holes and duplicates as ONE event =="
st=$(printf '%s\n' "$d" | sed -n 's/.*DIAG_PTS_CENSUS .*straddle=\([0-9]*\).*/\1/p' | head -1)
[ -n "$st" ] && ok "the straddle count is reported (straddle=$st)" || no "no straddle count in the census row"
if [ "${st:-0}" -gt 0 ]; then
  has "$d" "ONE discontinuity event" "…and the finding is stated in words, not left to be re-derived"
fi

echo
echo "== 5. the census runs before any early-exit verdict =="
# diagnose's ladder exits early on several routes; a census that only prints on
# the paths reaching the bottom is one the operator cannot rely on.
pos_census=$(printf '%s\n' "$d" | grep -n 'DIAG_PTS_CENSUS' | head -1 | cut -d: -f1)
pos_verdict=$(printf '%s\n' "$d" | grep -n '>> VERDICT' | head -1 | cut -d: -f1)
if [ -n "$pos_census" ] && [ -n "$pos_verdict" ]; then
  [ "$pos_census" -lt "$pos_verdict" ] && ok "the census is printed before the verdict it informs" \
    || no "the census printed AFTER the verdict (line $pos_census vs $pos_verdict)"
else
  [ -n "$pos_census" ] && ok "the census printed (this fixture reaches no early verdict)" || no "no census printed"
fi
has "$d" "DIAG_POC_CAPABILITY" "the POC capability probe is reported too"

echo
echo "== 6. no false positive: a clean file reports zero =="
d=$(bash "$SC/diagnose.sh" "$B" 2>&1)
has "$d" "DIAG_PTS_CENSUS packets=" "the census runs on a clean file too"
has "$d" "dup_packets=0" "…and reports zero duplicates"
hasnt "$d" "ONE discontinuity event" "no straddle finding is announced on a clean file"

echo
echo "dup-window-scope: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

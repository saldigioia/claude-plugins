#!/usr/bin/env bash
# 87-disk-preflight.sh — WO-1.15.6 / CHECKUP-2026-08-27 F11: free disk space
# was checked nowhere; a 24 GB build could burn an hour to an ENOSPC exit-1
# whose truncated .part then read like a different defect. Now every builder's
# writer pre-flight includes one df-based check: free bytes on OUT's volume
# (and the staging volume, where one exists — rebuild-paff's WORK) must be >=
# the source's size, else REFUSE exit 2 pre-flight, nothing written.
#
# Pins are relationships: the threshold IS the source size (free just below
# refuses, just above proceeds — computed from the fixture, never a literal);
# the refusal names the arithmetic, the machine row, and the operator knob;
# RTM_DISK_CHECK=0 skips ANNOUNCED; a broken meter never refuses (EMPTY !=
# ABSENT applies to refusals too). Hook: RTM_DISK_FREE_KB injects the reading.
#
# Standalone: bash tests/regression.d/87-disk-preflight.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
ff () { ffmpeg -nostdin -y -v error "$@"; }

echo "== 0. fixture =="
S="$WORK/src.ts"
ff -f lavfi -i testsrc2=s=160x120:r=25 -t 1 -c:v libx264 -g 25 -bf 0 -pix_fmt yuv420p -f mpegts "$S" \
  || { echo "fixture mint failed"; exit 2; }
SRCB=$(wc -c < "$S" | tr -d ' ')
[ "${SRCB:-0}" -gt 2048 ] || { echo "fixture too small to split the threshold"; exit 2; }
LOW_KB=$(( SRCB / 1024 - 1 ))          # strictly below the source size
HIGH_KB=$(( SRCB / 1024 + 64 ))        # comfortably above it

echo
echo "== 1. free < source -> REFUSED exit 2, nothing written, arithmetic named =="
o=$(RTM_DISK_FREE_KB="$LOW_KB" bash "$SC/remux.sh" "$S" "$WORK/o1.mov" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "insufficient free space refuses pre-flight (exit 2)" || no "refusal rc=$rc, want 2"
has "$o" "RTM_DISK" "machine row emitted"
has "$o" "verdict=refused" "machine row says refused"
has "$o" "need=$SRCB" "the need side of the arithmetic is the SOURCE size ($SRCB)"
has "$o" "RTM_DISK_CHECK=0" "the refusal names the operator knob for the smaller-output classes"
has "$o" "ENOSPC" "the refusal names the measured cost story"
if ls "$WORK"/o1.mov "$WORK"/o1.part* >/dev/null 2>&1; then no "refused run wrote something"; else ok "nothing written"; fi
[ -d "$WORK/o1.mov.lock" ] && no "lock left behind after the disk refusal" || ok "writer lock released on the disk refusal"

echo
echo "== 2. the threshold IS the source size: free just above it proceeds =="
o=$(RTM_DISK_FREE_KB="$HIGH_KB" bash "$SC/remux.sh" "$S" "$WORK/o2.mov" 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [ -f "$WORK/o2.mov" ]; } \
  && ok "free just above source size builds (rc=0) — the refusal is the relationship, not a mood" \
  || no "just-above-threshold build rc=$rc"

echo
echo "== 3. RTM_DISK_CHECK=0 skips ANNOUNCED (the cut/trim classes) =="
o=$(RTM_DISK_CHECK=0 RTM_DISK_FREE_KB=1 bash "$SC/remux.sh" "$S" "$WORK/o3.mov" 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [ -f "$WORK/o3.mov" ]; } && ok "knob honored: build proceeds (rc=0)" || no "knob build rc=$rc"
has "$o" "disk pre-flight skipped" "the skip announces itself (never silent)"

echo
echo "== 4. a broken meter never refuses (EMPTY != ABSENT applies to refusals) =="
o=$(RTM_DISK_FREE_KB=broken bash "$SC/remux.sh" "$S" "$WORK/o4.mov" 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [ -f "$WORK/o4.mov" ]; } \
  && ok "unmeasurable free space proceeds announced (a broken meter is not a full disk)" \
  || no "broken-meter run rc=$rc"
has "$o" "could not measure" "the unverified pass announces itself"

echo
echo "== 5. no hooks: the real df path builds clean =="
o=$(bash "$SC/remux.sh" "$S" "$WORK/o5.mov" 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [ -f "$WORK/o5.mov" ]; } && ok "real df measurement passes on this bench (rc=0)" \
  || no "real-df build rc=$rc"

echo
echo "== 6. rebuild-paff checks its STAGING volume too =="
psrc=$(cat "$SC/rebuild-paff.sh")
has "$psrc" 'rtm_writer_preflight "$OUT" "$IN" "$WORK"' "rebuild-paff passes its WORK staging dir to the pre-flight"
o=$(RTM_DISK_FREE_KB="$LOW_KB" bash "$SC/rebuild-paff.sh" "$S" "$WORK/o6.mov" 25 25000 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "rebuild-paff refuses before the TMPDIR extraction (exit 2)" || no "rebuild refusal rc=$rc, want 2"
[ -f "$WORK/o6.mov" ] && no "refused rebuild wrote an output" || ok "refused rebuild wrote no output"

echo
echo "disk-preflight: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

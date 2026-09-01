#!/usr/bin/env bash
# 87-disk-preflight.sh — WO-1.15.6 / CHECKUP-2026-08-27 F11; CONVERTED 1.17.2.
# Free disk space was checked nowhere; a 24 GB build could burn an hour to an
# ENOSPC exit-1 whose truncated .part then read like a different defect. F11
# added a df-based pre-flight REFUSAL: free bytes on OUT's volume (and the
# staging volume, where one exists — rebuild-paff's WORK) >= source size.
#
# 1.17.2 demoted the refusal to WARN + PROCEED by TIERS.md's own
# classification test (row (d): an ENOSPC is loud, the .part is kept, the
# census FAILs honestly — nothing irreversible), after the field report that
# the gate had become a hard size ceiling: on macOS/APFS, df's Avail EXCLUDES
# purgeable space the OS reclaims on demand, so a volume Finder shows as
# hundreds-of-GB free can read a few GB to df, and every source larger than
# that reading was refused. RTM_DISK_CHECK=strict restores the refusal (for
# unattended batches); =0 skips announced, as before.
#
# Pins are relationships: the threshold IS the source size (free just below
# warns, just above stays silent — computed from the fixture, never a
# literal); the warning names the arithmetic, the meter caveat, the machine
# row, and both knob values; strict refuses with nothing written; a broken
# meter never refuses OR warns (EMPTY != ABSENT applies to refusals too).
# Hook: RTM_DISK_FREE_KB injects the reading.
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
hasnt () { case "$1" in *"$2"*) no "$3 [present: $2]";; *) ok "$3";; esac; }
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
echo "== 1. DEFAULT: free < source -> WARN + PROCEED, build verified (1.17.2) =="
o=$(RTM_DISK_FREE_KB="$LOW_KB" bash "$SC/remux.sh" "$S" "$WORK/o1.mov" 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [ -f "$WORK/o1.mov" ]; } \
  && ok "low free space builds anyway by default (rc=0) — warn, never refuse" \
  || no "default low-space build rc=$rc (want 0, built)"
has "$o" "RTM_DISK" "machine row emitted"
has "$o" "verdict=warn" "machine row says warn"
has "$o" "need=$SRCB" "the need side of the arithmetic is the SOURCE size ($SRCB)"
has "$o" "purgeable" "the warning names the conservative-meter caveat (APFS purgeable space)"
has "$o" "RTM_DISK_CHECK=strict" "the warning names the strict knob for unattended batches"
has "$o" "RTM_DISK_CHECK=0" "the warning names the skip knob for the smaller-output classes"
has "$o" "ENOSPC" "the warning names the measured cost story"
hasnt "$o" "verdict=refused" "no refusal row on the default path"

echo
echo "== 2. STRICT: free < source -> REFUSED exit 2, nothing written =="
o=$(RTM_DISK_CHECK=strict RTM_DISK_FREE_KB="$LOW_KB" bash "$SC/remux.sh" "$S" "$WORK/o2.mov" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "strict mode refuses pre-flight (exit 2)" || no "strict refusal rc=$rc, want 2"
has "$o" "verdict=refused" "machine row says refused"
has "$o" "RTM_DISK_CHECK=strict" "the refusal names the mode that caused it"
if ls "$WORK"/o2.mov "$WORK"/o2.part* >/dev/null 2>&1; then no "refused run wrote something"; else ok "nothing written"; fi
[ -d "$WORK/o2.mov.lock" ] && no "lock left behind after the strict refusal" || ok "writer lock released on the strict refusal"

echo
echo "== 3. the threshold IS the source size: free just above it stays silent =="
o=$(RTM_DISK_FREE_KB="$HIGH_KB" bash "$SC/remux.sh" "$S" "$WORK/o3.mov" 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [ -f "$WORK/o3.mov" ]; } \
  && ok "free just above source size builds (rc=0)" || no "just-above-threshold build rc=$rc"
hasnt "$o" "RTM_DISK verdict" "no RTM_DISK row when free space suffices — the warn is the relationship, not a mood"

echo
echo "== 4. RTM_DISK_CHECK=0 skips ANNOUNCED (the cut/trim classes) =="
o=$(RTM_DISK_CHECK=0 RTM_DISK_FREE_KB=1 bash "$SC/remux.sh" "$S" "$WORK/o4.mov" 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [ -f "$WORK/o4.mov" ]; } && ok "knob honored: build proceeds (rc=0)" || no "knob build rc=$rc"
has "$o" "disk pre-flight skipped" "the skip announces itself (never silent)"

echo
echo "== 5. a broken meter never refuses OR warns (EMPTY != ABSENT) =="
o=$(RTM_DISK_FREE_KB=broken bash "$SC/remux.sh" "$S" "$WORK/o5.mov" 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [ -f "$WORK/o5.mov" ]; } \
  && ok "unmeasurable free space proceeds announced (a broken meter is not a full disk)" \
  || no "broken-meter run rc=$rc"
has "$o" "could not measure" "the unverified pass announces itself"
hasnt "$o" "verdict=warn" "…and does not fabricate a low-space warning from no reading"

echo
echo "== 6. no hooks: the real df path builds clean =="
o=$(bash "$SC/remux.sh" "$S" "$WORK/o6.mov" 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [ -f "$WORK/o6.mov" ]; } && ok "real df measurement passes on this bench (rc=0)" \
  || no "real-df build rc=$rc"

echo
echo "== 7. rebuild-paff checks its STAGING volume too =="
psrc=$(cat "$SC/rebuild-paff.sh")
has "$psrc" 'rtm_writer_preflight "$OUT" "$IN" "$WORK"' "rebuild-paff passes its WORK staging dir to the pre-flight"
o=$(RTM_DISK_CHECK=strict RTM_DISK_FREE_KB="$LOW_KB" bash "$SC/rebuild-paff.sh" "$S" "$WORK/o7.mov" 25 25000 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "strict rebuild-paff refuses before the TMPDIR extraction (exit 2)" || no "strict rebuild refusal rc=$rc, want 2"
[ -f "$WORK/o7.mov" ] && no "refused rebuild wrote an output" || ok "refused rebuild wrote no output"

echo
echo "disk-preflight: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

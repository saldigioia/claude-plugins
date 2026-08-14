#!/usr/bin/env bash
# 53-qt-groups.sh — work-order 5.3: the alternate-group post-pass (qt-groups.sh).
#
# The gap: with the keep-every-track default (WO 3.3) a multi-language .mov
# needs all audio tkhds sharing one nonzero alternate_group (one track enabled)
# to drive QuickTime's language menu. ffmpeg 9.0.1 movenc writes group=1 itself
# (measured 2026-08-14), so FRESH builds are conformant — the post-pass exists
# for retrofits: 8.x-era builds and group-scrubbed files carrying group=0.
# qt-groups.sh patches exactly 2 bytes per audio tkhd and blesses the output
# only after five proofs (byte-diff bound, video MD5, per-stream audio MD5,
# independent MP4Box parse, verify.sh). Full avenue log: the dead ends and the
# working MP4Box recipe live in references/alternate-group.md.
#
# Asserted:
#   0. bench claim: a fresh ffmpeg-9.x multi-audio build already carries a
#      shared nonzero group -> qt-groups NO-OPS on it (rc=0, writes nothing).
#   1. retrofit (the real job): `MP4Box -group-clean` mints the group=0 shape;
#      qt-groups -> rc=0, output written, QTG_SUMMARY patched=3 group=1, and an
#      INDEPENDENT reader (MP4Box -info) sees Alternate Group ID 1 on exactly
#      the 3 audio tracks; video essence MD5 unchanged; source untouched.
#   2. idempotence: a second pass over the patched output no-ops (rc=0).
#   3. REVIEW honesty: group=0 AND two enabled audio tracks (minted with
#      MP4Box -enable) -> patched output lands but rc=10 with enabled=2 in the
#      summary — the enable bits are the operator's call, never flipped here.
#   4. guards: a .ts (no moov) -> rc=2, nothing written; output path == input
#      path -> rc=2 (the source is never edited in place).
#
# Standalone: bash tests/regression.d/53-qt-groups.sh
# Exit 0 = all assertions pass; 1 = a regression; 2 = env failure.
# Needs MP4Box (fixture minting + the script's own parse proof). Without it
# the ONE honest assertion left is the announced refusal — asserted, then skip.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"; FIX="$TESTS/fixtures"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
vmd5 () { ffmpeg -nostdin -v error -i "$1" -map 0:v -c copy -f md5 - 2>/dev/null; }
agid () { MP4Box -noprog -info "$1" 2>&1 | grep -cx "Alternate Group ID $2"; }

if ! command -v MP4Box >/dev/null 2>&1; then
  # no MP4Box: qt-groups must refuse up front (rc=2) — assert that, then skip
  o=$(bash "$SC/qt-groups.sh" "$FIX/multilang.ts" "$WORK/x.mov" 2>&1); rc=$?
  { [ "$rc" -eq 2 ] && case "$o" in *"MP4Box not found"*) true;; *) false;; esac; } \
    && ok "no MP4Box on bench -> announced refusal (rc=2)" \
    || no "no-MP4Box refusal broken (rc=$rc, want 2 + 'MP4Box not found')"
  echo "  (skip: MP4Box absent — grouping proofs untestable on this bench)"
  echo "qt-groups: $pass passed, $fail failed"
  exit $((fail > 0 ? 1 : 0))
fi

# fixture: regenerate when missing (media never ships in git)
if [ ! -f "$FIX/multilang.ts" ]; then
  bash "$TESTS/make-fixtures.sh" multilang.ts || { echo "fixture build failed"; exit 2; }
fi
[ -f "$FIX/multilang.ts" ] || { echo "multilang.ts still missing"; exit 2; }

# base .mov: plain movenc multi-audio copy (the tkhd shape is codec-independent,
# and a raw -c copy is what an 8.x-era or third-party file looks like anyway)
ML="$WORK/ml.mov"
ffmpeg -nostdin -v error -i "$FIX/multilang.ts" -map 0:v -map 0:a -c copy \
  -movflags +faststart "$ML" 2>/dev/null || { echo "base .mov build failed"; exit 2; }

echo "== 0. fresh ffmpeg-9.x build: already grouped -> no-op, writes nothing =="
o=$(bash "$SC/qt-groups.sh" "$ML" "$WORK/noop.mov" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "conformant input -> rc=0" || no "conformant input rc=$rc (want 0)"
has "$o" "patched=0 out=none" "QTG_SUMMARY says patched=0 out=none"
[ ! -f "$WORK/noop.mov" ] && ok "no output written on a no-op" || no "no-op wrote an output"

echo
echo "== 1. retrofit: group-scrubbed file -> patched, proven, independently visible =="
G0="$WORK/g0.mov"; cp "$ML" "$G0"
MP4Box -noprog -group-clean "$G0" >/dev/null 2>&1 || { echo "group-clean mint failed"; exit 2; }
[ "$(agid "$G0" 1)" -eq 0 ] || { echo "mint sanity: groups not zeroed"; exit 2; }
SRC_SUM=$(cksum "$G0")
o=$(bash "$SC/qt-groups.sh" "$G0" "$WORK/grouped.mov" 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [ -f "$WORK/grouped.mov" ]; } \
  && ok "retrofit -> rc=0, output written" \
  || { no "retrofit rc=$rc (want 0 + output)"; printf '%s\n' "$o" | tail -6 | sed 's/^/   /'; }
has "$o" "QTG_SUMMARY date=" "summary self-dates (ground rule 6)"
has "$o" "audio=3 enabled=1 group=1 patched=3" "summary: 3 patched into group 1, one enabled"
has "$o" "proof (a) byte-diff" "byte-diff bound proof ran"
has "$o" "proof (e) verify.sh: green" "verify.sh proof ran green"
[ "$(agid "$WORK/grouped.mov" 1)" -eq 3 ] \
  && ok "independent reader: Alternate Group ID 1 on exactly 3 tracks" \
  || no "MP4Box sees $(agid "$WORK/grouped.mov" 1) grouped tracks, want 3"
[ "$(vmd5 "$ML")" = "$(vmd5 "$WORK/grouped.mov")" ] \
  && ok "video essence MD5 unchanged through mint+patch" || no "video essence MD5 drifted"
[ "$SRC_SUM" = "$(cksum "$G0")" ] && ok "source untouched" || no "the SOURCE changed"

echo
echo "== 2. idempotence: the patched output no-ops on a second pass =="
o=$(bash "$SC/qt-groups.sh" "$WORK/grouped.mov" "$WORK/again.mov" 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [ ! -f "$WORK/again.mov" ]; } \
  && ok "second pass -> rc=0, writes nothing" || no "second pass rc=$rc (want 0, no output)"

echo
echo "== 3. REVIEW: two enabled audio tracks -> grouped output, rc=10, never auto-fixed =="
R2="$WORK/r2.mov"; cp "$ML" "$R2"
MP4Box -noprog -group-clean -enable 3 "$R2" >/dev/null 2>&1 || { echo "enable mint failed"; exit 2; }
o=$(bash "$SC/qt-groups.sh" "$R2" "$WORK/r2out.mov" 2>&1); rc=$?
{ [ "$rc" -eq 10 ] && [ -f "$WORK/r2out.mov" ]; } \
  && ok "2-enabled retrofit -> rc=10 REVIEW, output still written" \
  || no "2-enabled retrofit rc=$rc (want 10 + output)"
has "$o" "enabled=2" "summary reports enabled=2 (the operator's call, not ours)"

echo
echo "== 4. guards =="
o=$(bash "$SC/qt-groups.sh" "$FIX/multilang.ts" "$WORK/ts.mov" 2>&1); rc=$?
{ [ "$rc" -eq 2 ] && [ ! -f "$WORK/ts.mov" ]; } \
  && ok "a .ts (no moov) -> rc=2, nothing written" || no "non-ISOBMFF rc=$rc (want 2)"
o=$(bash "$SC/qt-groups.sh" "$ML" "$ML" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "output==input -> rc=2 (never in place)" || no "in-place rc=$rc (want 2)"

echo
echo "qt-groups: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# 105-declared-vs-stored.sh — gate (h): does the container's sample table
# describe the coded structure it is sitting on?
#
# WHY (measured 2026-08-29). A plain `ffmpeg -c copy` of a field-coded (PAFF)
# source writes one MOV sample per coded FIELD. ISO/IEC 14496-15 requires both
# fields of a complementary field pair to live in ONE sample, and players time
# playback off samples — so the container claims ~50/s while the decoder emits
# ~25/s, and the file stutters in QuickTime and IINA. The essence is
# bit-identical to the source, so every gate this plugin had before 1.16.0
# passed it. Measured on the 2024 VMA capture: 433k samples over 216,631
# frames, and `verify.sh` said ">> OK (lossless proven; timeline scrub-clean)".
#
# The defect needs no exotic tool. THE OBVIOUS COMMAND PRODUCES IT.
#
# §1 is the unit lane over canned trace_headers logs and always runs: the
# 14496-15 sample arithmetic is text-in/text-out, and real PAFF cannot be
# minted by libx264 (which does MBAFF, not PAFF). §2 is the end-to-end lane
# and needs a real field-coded source; it announces a SKIP without one.
#
# Standalone: bash tests/regression.d/105-declared-vs-stored.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"; FIX="$TESTS/fixtures"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
. "$SC/lib-probe.sh"
. "$SC/lib-paff.sh"

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
hasnt () { case "$1" in *"$2"*) no "$3 [unexpected: $2]";; *) ok "$3";; esac; }
ff () { ffmpeg -nostdin -y -v error "$@"; }

# One canned picture in trace_headers' own shape. field<0 omits field_pic_flag
# entirely, which is what a progressive SPS actually emits.
pic () {  # $1 nal, $2 frame_num, $3 field_pic_flag (-1 = absent), $4 bottom
  printf '[trace_headers @ 0x1] 3           nal_unit_type    0 = %s\n' "$1"
  printf '[trace_headers @ 0x1] 8           first_mb_in_slice    1 = 0\n'
  printf '[trace_headers @ 0x1] 17          frame_num    0 = %s\n' "$2"
  if [ "$3" -ge 0 ]; then
    printf '[trace_headers @ 0x1] 1           field_pic_flag    0 = %s\n' "$3"
    [ "$3" -eq 1 ] && printf '[trace_headers @ 0x1] 1           bottom_field_flag    0 = %s\n' "$4"
  fi
  printf '[trace_headers @ 0x1] 5           pic_order_cnt_lsb    0 = %s\n' "$2"
}
census () { PF_TRACE_FILE="$1" pf_trace_census x; }

echo "== 1. unit lane: the 14496-15 sample arithmetic on canned headers =="

# (a) four clean complementary pairs -> four samples, not eight
{ for n in 0 1 2 3; do pic 1 "$n" 1 0; pic 1 "$n" 1 1; done; } > "$WORK/pairs.log"
eval "$(census "$WORK/pairs.log")"
[ "${PC_PICS:-0}" -eq 8 ]    && ok "8 coded field pictures counted" || no "PC_PICS=${PC_PICS:-} want 8"
[ "${PC_PAIRS:-0}" -eq 4 ]   && ok "4 complementary field pairs recognised" || no "PC_PAIRS=${PC_PAIRS:-} want 4"
[ "${PC_SINGLES:-0}" -eq 0 ] && ok "no unpaired fields" || no "PC_SINGLES=${PC_SINGLES:-} want 0"
[ "${PC_EXPECT:-0}" -eq 4 ]  && ok "the structure implies 4 samples, not 8 (14496-15)" || no "PC_EXPECT=${PC_EXPECT:-} want 4"

# (b) a frame-coded stream: every picture is already one sample
{ for n in 0 1 2 3 4; do pic 1 "$n" -1 0; done; } > "$WORK/frames.log"
eval "$(census "$WORK/frames.log")"
[ "${PC_EXPECT:-0}" -eq 5 ] && ok "a progressive stream implies one sample per picture" || no "PC_EXPECT=${PC_EXPECT:-} want 5"
[ "${PC_PAIRS:-0}" -eq 0 ]  && ok "…and no pairs are invented for it" || no "PC_PAIRS=${PC_PAIRS:-} want 0"

# (c) an UNPAIRED field is its own sample — never silently folded into a pair
{ pic 1 0 1 0; pic 1 0 1 1; pic 1 1 1 0; pic 1 2 1 0; pic 1 2 1 1; } > "$WORK/orphan.log"
eval "$(census "$WORK/orphan.log")"
[ "${PC_PAIRS:-0}" -eq 2 ]   && ok "two real pairs found around the orphan" || no "PC_PAIRS=${PC_PAIRS:-} want 2"
[ "${PC_SINGLES:-0}" -eq 1 ] && ok "the unpaired top field is counted as its own sample" || no "PC_SINGLES=${PC_SINGLES:-} want 1"
[ "${PC_EXPECT:-0}" -eq 3 ]  && ok "the structure implies 3 samples (2 pairs + 1 single)" || no "PC_EXPECT=${PC_EXPECT:-} want 3"

# (d) frame_num is load-bearing: two adjacent opposite-parity fields from
#     DIFFERENT frames are not a complementary pair and must not be merged.
{ pic 1 0 1 0; pic 1 7 1 1; } > "$WORK/mismatch.log"
eval "$(census "$WORK/mismatch.log")"
[ "${PC_PAIRS:-0}" -eq 0 ]   && ok "opposite-parity fields with different frame_num are NOT paired" || no "PC_PAIRS=${PC_PAIRS:-} want 0"
[ "${PC_EXPECT:-0}" -eq 2 ]  && ok "…so they imply two samples, not one" || no "PC_EXPECT=${PC_EXPECT:-} want 2"

echo
echo "== 2. no false positive: a progressive build passes gate (h) =="
P="$WORK/prog.ts"
ff -f lavfi -i testsrc2=s=160x120:r=25 -t 2 -c:v libx264 -g 25 -pix_fmt yuv420p -f mpegts "$P" \
  || { echo "fixture mint failed"; exit 2; }
ff -i "$P" -map 0:v:0 -c copy -tag:v avc1 "$WORK/prog.mov"
o=$(bash "$SC/verify.sh" "$P" "$WORK/prog.mov" 2>&1)
has "$o" "VERIFY_LEDGER gate=h verdict=pass" "a progressive copy passes gate (h)"
has "$o" "VERIFY_LEDGER gate=k verdict=pass" "…and gate (k): its display order matches its own POC"

echo
echo "== 3. end-to-end: the 2026-08-28 counter-example must FAIL gate (h) =="
# Real PAFF cannot be minted here (libx264 does MBAFF, not PAFF), so this lane
# needs a field-coded source. Point RTM_PAFF_SOURCE at one, or mint the house
# fixture: bash tests/make-fixtures.sh paff.ts
PAFF="${RTM_PAFF_SOURCE:-$FIX/paff.ts}"
if [ ! -s "$PAFF" ]; then
  echo "  SKIP: no field-coded source — set RTM_PAFF_SOURCE=/path/to/paff.ts, or"
  echo "        RTM_PAFF_SOURCE=... bash tests/make-fixtures.sh paff.ts"
else
  python3 "$TESTS/mint-counterexamples.py" --out "$WORK/ce" --paff "$PAFF" >/dev/null 2>&1
  CE="$WORK/ce/field-per-sample.mov"; CESRC="$WORK/ce/field-per-sample.src.ts"
  if [ ! -s "$CE" ]; then
    no "the counter-example could not be minted from $PAFF"
  else
    dec=$(ffprobe -v error -select_streams v:0 -show_entries packet=pts -of csv=p=0 "$CE" | grep -c . || true)
    o=$(bash "$SC/verify.sh" "$CESRC" "$CE" 2>&1)
    # the whole point: the ESSENCE is fine and the CONTAINER is not
    has "$o" "VERIFY_LEDGER gate=b verdict=pass" "the essence is bit-identical — (b) passes, as it did in the field"
    has "$o" "VERIFY_LEDGER gate=h verdict=fail" "gate (h) FAILs the field-per-sample build"
    has "$o" "declared $dec samples" "…naming the declared sample count"
    has "$o" "14496-15" "…and the rule it is enforcing"
    has "$o" ">> FAIL" "the run's verdict is FAIL"
    # Gate (k) does NOT double-indict here, and that is correct: the source is
    # the same field structure, so it reads off-lattice by the same amount and
    # the source baseline (the doctrine gates (c)/(e) already run on) calls it
    # inherited. The container-level defect — one sample per FIELD — is gate
    # (h)'s to catch, and it does. A gate that fired here too would be counting
    # a property of the SOURCE as damage done by the remux.
    case "$o" in
      *"VERIFY_LEDGER gate=k verdict=fail"*)
        no "gate (k) indicted the remux for a lattice property its source shares" ;;
      *"VERIFY_LEDGER gate=k verdict="*)
        ok "gate (k) does not double-indict an inherited lattice property" ;;
      *) no "gate (k) filed no row at all" ;;
    esac
  fi
fi

echo
echo "declared-vs-stored: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

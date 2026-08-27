#!/usr/bin/env bash
# 77-poc-capability.sh — WO-1.15.3 Item 1: the POC gate's capability is
# knowable at pre-flight, and the build never asks.
#
# Pre-round measured (2026-08-27, this bench): a pic_order_cnt_type=2 source
# (x264 -bf 0) hands the junction model's POC-lattice gate ZERO extractable
# rows — knowable from a 40-frame head probe in seconds — yet pairfill ran the
# ENTIRE mux plus a whole-file output parse to reach a foregone UNPROVEN,
# exit 1, .part retained (field-recorded on the 23.68 GB job: ~55 min mux +
# 26 min parse). The 1.15.2 Item C precedent (zero-base's 23.68 GB build to a
# foregone hard-stop) applies verbatim: refuse at pre-flight, exit 3, nothing
# written. NO bypass flag (1.15.2 Defect-B lesson: a gate waived into
# UNPROVEN-by-default is no gate); the manual route and the auto.sh driver
# consequence are named in the refusal instead.
#
# Pins are relationships, never bench literals: PCAP_MAXLSB == 1<<(l2+4) at
# two points; capable=no => PCAP_WHY nonempty; the type-2 refusal exits 3
# with NOTHING written and names both the manual route and where auto.sh
# legally goes next (flattening rebuild / Rung 3-DERIVE — neither POC-gated).
#
# Standalone: bash tests/regression.d/77-poc-capability.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"
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
PF="$SC/pairfill-paff.sh"

echo "== 1. unit lane: pf_poc_capability on canned head-trace logs =="
# type-0 shape: SPS carries poc_type 0 + log2_max (=2), 5 first-slice
# pictures each with a pic_order_cnt_lsb; ONE non-first slice with its own
# lsb must not double-count (the gate extraction's pend discipline).
cat > "$WORK/head_t0.log" <<'LOG'
[trace_headers @ 0x1] 41          pic_order_cnt_type                                          1 = 0
[trace_headers @ 0x1] 42          log2_max_pic_order_cnt_lsb_minus4                         011 = 2
[trace_headers @ 0x1] 7           nal_unit_type                                           00101 = 5
[trace_headers @ 0x1] 8           first_mb_in_slice                                           1 = 0
[trace_headers @ 0x1] 5           pic_order_cnt_lsb                                  0000000000 = 0
[trace_headers @ 0x1] 8           first_mb_in_slice                                         010 = 40
[trace_headers @ 0x1] 5           pic_order_cnt_lsb                                  0000000000 = 0
[trace_headers @ 0x1] 7           nal_unit_type                                           00001 = 1
[trace_headers @ 0x1] 8           first_mb_in_slice                                           1 = 0
[trace_headers @ 0x1] 5           pic_order_cnt_lsb                                  0000000100 = 4
[trace_headers @ 0x1] 8           first_mb_in_slice                                           1 = 0
[trace_headers @ 0x1] 5           pic_order_cnt_lsb                                  0000000010 = 2
[trace_headers @ 0x1] 8           first_mb_in_slice                                           1 = 0
[trace_headers @ 0x1] 5           pic_order_cnt_lsb                                  0000001000 = 8
[trace_headers @ 0x1] 8           first_mb_in_slice                                           1 = 0
[trace_headers @ 0x1] 5           pic_order_cnt_lsb                                  0000000110 = 6
LOG
eval "$(pf_poc_capability "$WORK/head_t0.log")"
[ "${PCAP_OK:-no}" = yes ] && ok "type-0 log: PCAP_OK=yes" || no "type-0 log: PCAP_OK=${PCAP_OK:-unset}, want yes"
[ "${PCAP_WHY:--}" = - ] && ok "capable log: PCAP_WHY is the '-' placeholder" || no "capable log: PCAP_WHY=${PCAP_WHY:-unset}"
[ "${PCAP_POC_TYPE:--1}" = 0 ] && ok "type-0 log: PCAP_POC_TYPE=0" || no "PCAP_POC_TYPE=${PCAP_POC_TYPE:-unset}, want 0"
[ "${PCAP_PICS:-0}" = 5 ] && ok "5 coded pictures (first_mb_in_slice==0 only)" || no "PCAP_PICS=${PCAP_PICS:-unset}, want 5"
[ "${PCAP_LSB_ROWS:-0}" = 5 ] && ok "5 lsb rows (non-first slice does not double-count)" || no "PCAP_LSB_ROWS=${PCAP_LSB_ROWS:-unset}, want 5"
[ "${PCAP_MAXLSB:-0}" -eq $((1 << (2 + 4))) ] 2>/dev/null \
  && ok "PCAP_MAXLSB == 1<<(l2+4) at l2=2 (${PCAP_MAXLSB:-unset})" || no "PCAP_MAXLSB=${PCAP_MAXLSB:-unset}, want $((1 << (2 + 4)))"
# the relationship at a second point: l2=4
sed 's/log2_max_pic_order_cnt_lsb_minus4                         011 = 2/log2_max_pic_order_cnt_lsb_minus4                         011 = 4/' \
  "$WORK/head_t0.log" > "$WORK/head_t0b.log"
eval "$(pf_poc_capability "$WORK/head_t0b.log")"
[ "${PCAP_MAXLSB:-0}" -eq $((1 << (4 + 4))) ] 2>/dev/null \
  && ok "PCAP_MAXLSB == 1<<(l2+4) at l2=4 (${PCAP_MAXLSB:-unset})" || no "PCAP_MAXLSB=${PCAP_MAXLSB:-unset}, want $((1 << (4 + 4)))"

# type-2 shape: poc_type 2, NO log2_max (spec-conditional on type 0 — measured
# absent on the x264 -bf 0 mint), pictures but zero lsb rows.
cat > "$WORK/head_t2.log" <<'LOG'
[trace_headers @ 0x1] 41          pic_order_cnt_type                                        011 = 2
[trace_headers @ 0x1] 7           nal_unit_type                                           00101 = 5
[trace_headers @ 0x1] 8           first_mb_in_slice                                           1 = 0
[trace_headers @ 0x1] 7           nal_unit_type                                           00001 = 1
[trace_headers @ 0x1] 8           first_mb_in_slice                                           1 = 0
[trace_headers @ 0x1] 8           first_mb_in_slice                                           1 = 0
LOG
eval "$(pf_poc_capability "$WORK/head_t2.log")"
[ "${PCAP_OK:-yes}" = no ] && ok "type-2 log: PCAP_OK=no" || no "type-2 log: PCAP_OK=${PCAP_OK:-unset}, want no"
[ "${PCAP_WHY:-}" = poc_type ] && ok "type-2 log: PCAP_WHY=poc_type" || no "PCAP_WHY=${PCAP_WHY:-unset}, want poc_type"
{ [ -n "${PCAP_WHY:-}" ] && [ "${PCAP_WHY:-}" != - ]; } \
  && ok "capable=no => PCAP_WHY nonempty (the relationship pin)" || no "capable=no with empty/placeholder PCAP_WHY"
[ "${PCAP_POC_TYPE:--1}" = 2 ] && ok "type-2 log: PCAP_POC_TYPE=2 (named in the refusal)" || no "PCAP_POC_TYPE=${PCAP_POC_TYPE:-unset}, want 2"
[ "${PCAP_LSB_ROWS:-9}" = 0 ] && ok "type-2 log: zero lsb rows" || no "PCAP_LSB_ROWS=${PCAP_LSB_ROWS:-unset}, want 0"
[ "${PCAP_MAXLSB:-9}" = 0 ] && ok "type-2 log: PCAP_MAXLSB=0 (no SPS value to carry)" || no "PCAP_MAXLSB=${PCAP_MAXLSB:-unset}, want 0"

# empty log: the old "parsed no coded picture" refusal folds into no_pictures
: > "$WORK/head_empty.log"
eval "$(pf_poc_capability "$WORK/head_empty.log")"
[ "${PCAP_OK:-yes}" = no ] && ok "empty log: PCAP_OK=no" || no "empty log: PCAP_OK=${PCAP_OK:-unset}"
[ "${PCAP_WHY:-}" = no_pictures ] && ok "empty log: PCAP_WHY=no_pictures" || no "PCAP_WHY=${PCAP_WHY:-unset}, want no_pictures"

echo
echo "== 2. fixtures: the appendix mint (x264 -bf 3 -> type 0; -bf 0 -> type 2) =="
ff -f lavfi -i testsrc2=r=25:s=320x240:d=2 -c:v libx264 -bf 3 -g 25 -pix_fmt yuv420p -f mpegts "$WORK/poc0.ts" \
  || { echo "poc0 mint failed"; exit 2; }
ff -f lavfi -i testsrc2=r=25:s=320x240:d=2 -c:v libx264 -bf 0 -g 25 -pix_fmt yuv420p -f mpegts "$WORK/poc2.ts" \
  || { echo "poc2 mint failed"; exit 2; }
# one 2-run junction in an otherwise strictly-alternating scan (test 65's shape)
cat > "$WORK/scan_run2.csv" <<'CSV'
0,0
N/A,N/A
3600,3600
N/A,N/A
N/A,N/A
7200,7200
N/A,N/A
10800,10800
N/A,N/A
14400,14400
CSV

echo
echo "== 3. junction path on a type-2 source: refused at PRE-FLIGHT, exit 3, nothing written =="
# PF_SETTS_OK=yes pins past precondition 1 hermetically on any bench; the
# refusal under test is the capability pre-flight, which comes after it.
o=$(PP_SCAN_FILE="$WORK/scan_run2.csv" PF_SETTS_OK=yes \
    bash "$PF" "$WORK/poc2.ts" "$WORK/j2.mov" --rate 50 2>&1); rc=$?
[ "$rc" -eq 3 ] && ok "type-2 junction source -> exit 3 (pre-flight refusal)" \
  || no "type-2 junction source rc=$rc, want 3 (pre-round measured: rc=1 AFTER the whole build)"
has "$o" "JUNCTION MODEL REFUSED: pic_order_cnt_type=2" "refusal names the measured pic_order_cnt_type"
has "$o" "pic_order_cnt_lsb" "refusal names the missing syntax element"
has "$o" "UNPROVEN" "refusal states the foregone verdict the build would reach"
has "$o" "Nothing was built" "refusal states nothing was built"
has "$o" "references/timeline-repair.md" "refusal names the manual route (unproven, by hand)"
has "$o" "auto.sh" "refusal names the driver consequence (Item 1 step 6)"
has "$o" "rebuild" "refusal names the PF_REORDER=no fallthrough (flattening rebuild)"
has "$o" "3-DERIVE" "refusal names the reorder+derive escalation (Rung 3-DERIVE)"
has "$o" "PP_POC_CAPABILITY ok=no why=poc_type" "machine row emitted on the refusal path"
hasnt "$o" "-- muxing" "the mux never started"
if ls "$WORK"/j2* >/dev/null 2>&1; then no "refusal wrote something (ls: $(ls "$WORK"/j2*))"
else ok "nothing written by pairfill (no output, no .part)"; fi
# NO bypass: the refusal must not name an attestation/waiver route (Defect-B lesson)
hasnt "$o" "RTM_PRECOND_ATTEST" "no attestation bypass on the capability refusal"
hasnt "$o" "I attest" "no attestation string offered"

echo
echo "== 4. hermetic hook: PF_HEAD_TRACE_FILE drives the pre-flight, not the file =="
o=$(PP_SCAN_FILE="$WORK/scan_run2.csv" PF_SETTS_OK=yes PF_HEAD_TRACE_FILE="$WORK/head_t2.log" \
    bash "$PF" "$WORK/poc0.ts" "$WORK/j3.mov" --rate 50 2>&1); rc=$?
{ [ "$rc" -eq 3 ] && case "$o" in *"pic_order_cnt_type=2"*) true;; *) false;; esac; } \
  && ok "canned type-2 head log refuses a type-0 file (hook drives the verdict)" \
  || no "PF_HEAD_TRACE_FILE hook not honored (rc=$rc)"

echo
echo "== 5. type-0 source: the pre-flight ANNOUNCES capability and lets the build proceed =="
o=$(PP_SCAN_FILE="$WORK/scan_run2.csv" PF_SETTS_OK=yes \
    bash "$PF" "$WORK/poc0.ts" "$WORK/j4.mov" --rate 50 2>&1); rc=$?
has "$o" "PP_POC_CAPABILITY ok=yes" "type-0: capability machine row says ok=yes"
has "$o" "poc_type=0" "type-0: the announce names the measured poc_type"
[ "$rc" -ne 3 ] && ok "type-0 source is not refused by the pre-flight (rc=$rc)" \
  || no "type-0 source refused at pre-flight (rc=3)"
if pf_setts_probe 'if(lt(PTS\,-8000000000000000000)\,NEXT_PTS\,PTS)'; then
  o=$(PP_SCAN_FILE="$WORK/scan_run2.csv" bash "$PF" "$WORK/poc0.ts" "$WORK/j5.mov" --rate 50 2>&1); rc=$?
  { [ "$rc" -eq 0 ] && [ -f "$WORK/j5.mov" ]; } \
    && ok "capable ffmpeg: type-0 junction build still runs end-to-end (rc=0)" \
    || no "capable ffmpeg: type-0 junction build rc=$rc"
  has "$o" "PP_POC_LATTICE on_slot=" "capable ffmpeg: POC gate still evaluates the type-0 build"
  has "$o" " off=0" "capable ffmpeg: every picture on its slot"
else
  echo "  (SKIP: this setts lacks NEXT_PTS — the end-to-end half needs a capable ffmpeg;"
  echo "   the pre-flight mechanics were pinned hermetically above.)"
fi

echo
echo "== 6. driver-route consequence: asserted, not assumed (auto.sh) =="
asrc=$(cat "$SC/auto.sh")
has "$asrc" 'if [ "${PF_REORDER:-no}" = no ]; then' "auto.sh: the PF_REORDER=no arm exists"
has "$asrc" "attempt 3" "auto.sh: ...and falls through to the flattening rebuild (attempt 3)"
has "$asrc" "attempt_derive" "auto.sh: the reorder+derive arm escalates to Rung 3-DERIVE"
has "$asrc" "WO-1.15.3" "auto.sh: the per-profile consequence of pairfill's exit-3 pre-flight is documented in-line"

echo
echo "poc-capability: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# 76-poc-lattice-wrap.sh — 1.15.2 Defect D: pf_poc_lattice must unwrap
# pic_order_cnt_lsb before fitting the presentation lattice.
#
# The unit-test lane's first resident: pf_poc_lattice is a pure function over
# a CSV table (idr,poc,pts), so the wrap case needs NO media fixture, no
# libx264 and no mux — which is precisely why the defect survived a
# media-fixture-shaped suite. pic_order_cnt_lsb is POC modulo
# MaxPicOrderCntLsb; the un-unwrapped 1.14.0–1.15.1 fit was sound only while
# IDR interval < wrap period, a precondition broadcast long-IDR open-GOP
# violates as the NORM (field source: 24 IDR sequences x ~73 wraps ->
# false-FAIL at 3,179/451,071 on a provably correct build; the survivors are
# each sequence's pre-first-wrap head — 1.15.1 measured PL_ON=256 on the
# synthetic table below, the wrap period 512/2 exactly).
#
# Pins (relationships, never bench-measured literals — table row counts are
# input-determined and fair game):
#   1. wrapping table (M=512, ~7 wraps, correct PTS by construction):
#      PL_OFF == 0 and PL_ON == PL_TOTAL — red on 1.15.1 (PL_OFF=1744);
#   2. pre-unwrapped control: still all on-slot (the fix touches nothing
#      that was already sound);
#   3. NEGATIVE control — one picture genuinely off-lattice must STILL fail
#      (PL_OFF == 1): the row that stops the fix degrading into always-pass;
#   4. the SPS path: an explicit MaxPicOrderCntLsb argument returns the same
#      verdicts as per-sequence inference on all three tables.
#
# Standalone: bash tests/regression.d/76-poc-lattice-wrap.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }

. "$SC/lib-probe.sh"
. "$SC/lib-paff.sh"

# one IDR sequence, MaxPicOrderCntLsb=512, POC step 2, half=1800, 2000
# pictures: the timeline is RIGHT by construction, only the lsb wraps
awk 'BEGIN{ M=512; half=1800; base=126000
            for(i=0;i<2000;i++){ poc=(2*i)%M; pts=base+2*i*half
              printf "%d,%d,%d\n", (i==0?1:0), poc, pts } }' > "$WORK/wrap.csv"
# control: identical timeline, POC already whole -> must pass
awk 'BEGIN{ half=1800; base=126000
            for(i=0;i<2000;i++){ printf "%d,%d,%d\n", (i==0?1:0), 2*i, base+2*i*half } }' > "$WORK/ok.csv"
# negative control: POC whole, one picture genuinely off-lattice -> must fail
awk 'BEGIN{ half=1800; base=126000
            for(i=0;i<2000;i++){ pts=base+2*i*half; if(i==900) pts+=900
              printf "%d,%d,%d\n", (i==0?1:0), 2*i, pts } }' > "$WORK/bad.csv"

echo "== 1. wrapping lsb, correct timeline -> every picture on-slot =="
eval "$(pf_poc_lattice "$WORK/wrap.csv")"
{ [ "${PL_OFF:-1}" = 0 ] && [ "${PL_ON:-0}" = "${PL_TOTAL:-x}" ] && [ "${PL_TOTAL:-0}" = 2000 ]; } \
  && ok "wrap table: on_slot == total ($PL_ON/$PL_TOTAL), off=0" \
  || no "wrap table misjudged (on=$PL_ON total=$PL_TOTAL off=$PL_OFF — 1.15.1 measured on=256)"

echo "== 2. pre-unwrapped control -> still on-slot =="
eval "$(pf_poc_lattice "$WORK/ok.csv")"
{ [ "${PL_OFF:-1}" = 0 ] && [ "${PL_ON:-0}" = "${PL_TOTAL:-x}" ]; } \
  && ok "whole-POC control unchanged ($PL_ON/$PL_TOTAL on-slot)" \
  || no "whole-POC control regressed (on=$PL_ON total=$PL_TOTAL off=$PL_OFF)"

echo "== 3. NEGATIVE control: one off-lattice picture must still FAIL =="
eval "$(pf_poc_lattice "$WORK/bad.csv")"
[ "${PL_OFF:-0}" = 1 ] \
  && ok "off-by-900-ticks picture still caught (off=$PL_OFF) — discrimination intact" \
  || no "negative control lost: off=$PL_OFF (an unwrap that always passes is no gate)"

echo "== 4. SPS-supplied MaxPicOrderCntLsb agrees with inference =="
sps_ok=1
for t in wrap ok bad; do
  eval "$(pf_poc_lattice "$WORK/$t.csv" 512)"
  case "$t:$PL_OFF" in wrap:0|ok:0|bad:1) : ;; *) sps_ok=0; echo "   $t with M=512: off=$PL_OFF";; esac
done
[ "$sps_ok" -eq 1 ] && ok "explicit M=512 verdicts match inference on all three tables" \
  || no "SPS path diverges from inference"

echo
echo "poc-lattice-wrap: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

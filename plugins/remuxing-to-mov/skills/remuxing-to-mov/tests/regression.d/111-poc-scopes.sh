#!/usr/bin/env bash
# 111-poc-scopes.sh — gate (k) judges presentation order PER SPS ACTIVATION.
#
# WHY. A broadcast capture spanning a program change carries more than one SPS,
# and `log2_max_pic_order_cnt_lsb` can differ between them. The §8.2.1.1 unwrap
# is modular arithmetic, so a single global MaxPicOrderCntLsb unwraps part of
# the file with the wrong modulus. Measured 2026-08-29 on the 2024 VMA
# deliverable: under one (wrong) value, 215,949 of 216,631 pictures read
# "off-lattice" on a build every other gate proved correct.
#
# 1.16.1 made that UNPROVEN rather than an accusation — the honest answer, and
# a refusal to judge the very captures this plugin exists for. This round makes
# it evaluable: each SPS activation opens its own POC scope carrying its own
# modulus, the unwrap never carries lsb state across a scope boundary, and the
# gate aggregates per-scope results.
#
# NO BAR IS LOWERED. A scope that cannot be fit is UNPROVEN — named, with its
# measurement — and the other scopes are still reported. "Unprovable" never
# becomes "assumed".
#
# §1 and §4 are unit lanes over canned tables and always run. §2/§3/§5 mint
# real two-SPS media with libx264 (`-bf` selects log2_max_pic_order_cnt_lsb:
# bf=3 -> 2, bf=8 -> 3, bf=0 -> pic_order_cnt_type 2 with no lsb at all).
#
# Standalone: bash tests/regression.d/111-poc-scopes.sh
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
l2_of () { ffmpeg -nostdin -hide_banner -nostats -i "$1" -map 0:v:0 -c copy -bsf:v trace_headers \
             -f null - 2>&1 | grep log2_max_pic_order_cnt_lsb_minus4 | awk '{print $NF}' | sort -u | tr '\n' ' '; }

echo "== 1. unit lane: the lattice checker scopes on an l2 CHANGE, not just IDR =="
# 4-column table: idr,poc,l2,pts. Two scopes, DIFFERENT moduli, each internally
# correct on its own lattice. Under one global modulus the second scope reads
# off-lattice; per scope, both are on-slot.
{
  # scope A: l2=2 (MaxPocLsb 64), poc step 2, half 1800, no wrap
  awk 'BEGIN{ for(i=0;i<40;i++) printf "%d,%d,2,%d\n", (i==0?1:0), 2*i, 1000+2*i*1800 }'
  # scope B: l2=5 (MaxPocLsb 512), same shape, NOT preceded by an IDR — the
  # SPS activation alone must open the scope
  awk 'BEGIN{ for(i=0;i<40;i++) printf "0,%d,5,%d\n", 2*i, 900000+2*i*1800 }'
} > "$WORK/scopes.csv"
eval "$(pf_poc_lattice "$WORK/scopes.csv")"
[ "${PL_TOTAL:-0}" -eq 80 ] && ok "all 80 rows judged" || no "PL_TOTAL=${PL_TOTAL:-} want 80"
[ "${PL_OFF:-1}" -eq 0 ] && ok "both scopes on-slot under their OWN modulus (off=0)" \
  || no "PL_OFF=${PL_OFF:-} — the l2 change did not open a new scope"
[ "${PL_SEQS:-0}" -ge 2 ] && ok "the l2 change opened a scope (seqs=${PL_SEQS:-})" || no "seqs=${PL_SEQS:-}, want >=2"

echo
echo "== 2. a torn scope is still caught (the gate keeps its teeth) =="
{
  awk 'BEGIN{ for(i=0;i<40;i++) printf "%d,%d,2,%d\n", (i==0?1:0), 2*i, 1000+2*i*1800 }'
  # scope B: POC says one order, the timestamps say another
  awk 'BEGIN{ for(i=0;i<40;i++){ p=2*i; t=(i%2? 900000+2*i*1800+9000 : 900000+2*i*1800)
              printf "0,%d,5,%d\n", p, t } }'
} > "$WORK/torn.csv"
eval "$(pf_poc_lattice "$WORK/torn.csv")"
[ "${PL_OFF:-0}" -gt 0 ] && ok "a scope whose timestamps contradict its POC is off-lattice (off=$PL_OFF)" \
  || no "the torn scope was not caught (off=${PL_OFF:-})"
[ "${PL_OFF:-0}" -lt "${PL_TOTAL:-0}" ] && ok "…and the CLEAN scope is still reported on-slot" \
  || no "a torn scope condemned the clean one too (off=$PL_OFF of $PL_TOTAL)"

echo
echo "== 3. legacy 3-column tables (idr,poc,pts) are unchanged =="
awk 'BEGIN{ half=1800; base=1000; for(i=0;i<200;i++) printf "%d,%d,%d\n", (i==0?1:0), 2*i, base+2*i*half }' > "$WORK/legacy.csv"
eval "$(pf_poc_lattice "$WORK/legacy.csv" 512)"
{ [ "${PL_TOTAL:-0}" -eq 200 ] && [ "${PL_OFF:-1}" -eq 0 ]; } \
  && ok "a 3-column table still judges exactly as before (200 on-slot)" \
  || no "legacy table broke: total=${PL_TOTAL:-} off=${PL_OFF:-}"

echo
echo "== 4. an unfittable scope is UNPROVEN by name, and the others still report =="
{
  awk 'BEGIN{ for(i=0;i<40;i++) printf "%d,%d,2,%d\n", (i==0?1:0), 2*i, 1000+2*i*1800 }'
  # scope B: every picture the same POC — no interval can be fit from it
  awk 'BEGIN{ for(i=0;i<12;i++) printf "0,7,5,%d\n", 900000+i*1800 }'
} > "$WORK/nofit.csv"
eval "$(pf_poc_lattice "$WORK/nofit.csv")"
[ "${PL_NOFIT:-0}" -ge 1 ] && ok "the unfittable scope is counted as UNPROVEN (nofit=$PL_NOFIT)" \
  || no "PL_NOFIT=${PL_NOFIT:-} — an unfittable scope was not reported as unproven"
[ "${PL_ON:-0}" -ge 40 ] && ok "…and the fittable scope is still reported on-slot (on=$PL_ON)" \
  || no "the fittable scope was lost (on=${PL_ON:-})"
# THE LIST VALUE MUST SURVIVE `eval`. PL_NOFIT_AT names several scopes, and an
# eval-ed assignment that meets an unquoted separator runs the rest as a
# command — measured 2026-08-29 as "2: command not found", which killed verify
# mid-gate and took two unrelated bench assertions with it.
{
  awk 'BEGIN{ for(i=0;i<8;i++)  printf "%d,7,2,%d\n", (i==0?1:0), 1000+i*1800 }'
  awk 'BEGIN{ for(i=0;i<8;i++)  printf "0,9,5,%d\n", 900000+i*1800 }'
  awk 'BEGIN{ for(i=0;i<8;i++)  printf "0,3,7,%d\n", 1900000+i*1800 }'
} > "$WORK/multinofit.csv"
mlat=$(pf_poc_lattice "$WORK/multinofit.csv")
case "$mlat" in *"PL_NOFIT_AT='"*) ok "PL_NOFIT_AT is quoted for eval";; *) no "PL_NOFIT_AT is emitted unquoted: $(printf '%s' "$mlat" | grep NOFIT_AT)";; esac
( eval "$mlat" ) >/dev/null 2>&1 && ok "a multi-scope PL_NOFIT_AT evals cleanly" \
  || no "eval of the lattice output failed — a list value is running as a command"
eval "$mlat"
[ "${PL_NOFIT:-0}" -eq 3 ] && ok "all three unfittable scopes are named (nofit=$PL_NOFIT)" || no "nofit=${PL_NOFIT:-} want 3"

echo
echo "== 5. end to end: a real two-SPS capture is EVALUATED, not declined =="
ff -f lavfi -i "testsrc2=s=160x120:r=25" -t 2 -c:v libx264 -g 25 -bf 3 -pix_fmt yuv420p -f mpegts "$WORK/p1.ts"
ff -f lavfi -i "mandelbrot=s=160x120:r=25" -t 2 -c:v libx264 -g 25 -bf 8 -pix_fmt yuv420p -f mpegts "$WORK/p2.ts"
cat "$WORK/p1.ts" "$WORK/p2.ts" > "$WORK/twosps.ts"
nl2=$(l2_of "$WORK/twosps.ts")
case "$(printf '%s' "$nl2" | wc -w | tr -d ' ')" in
  0|1) echo "  SKIP: this libx264 minted one SPS shape ($nl2) — no two-SPS fixture here" ;;
  *)
    ok "the fixture carries more than one log2_max_pic_order_cnt_lsb ($nl2)"
    ff -i "$WORK/twosps.ts" -map 0:v:0 -c copy -tag:v avc1 "$WORK/twosps.mov"
    o=$(bash "$SC/verify.sh" "$WORK/twosps.ts" "$WORK/twosps.mov" 2>&1)
    hasnt "$o" "VERIFY_LEDGER gate=k verdict=unproven" "gate (k) no longer declines a multi-SPS capture"
    has "$o" "VERIFY_LEDGER gate=k verdict=pass" "…it evaluates it, and a faithful copy passes"
    # and the teeth, on the same media: PTS=DTS on a reordered stream
    if ffmpeg -nostdin -hide_banner -bsfs 2>/dev/null | grep -qw setts; then
      ff -i "$WORK/twosps.ts" -map 0:v:0 -c copy -bsf:v setts=pts=DTS -tag:v avc1 "$WORK/torn.mov"
      o=$(bash "$SC/verify.sh" "$WORK/twosps.ts" "$WORK/torn.mov" 2>&1)
      has "$o" "VERIFY_LEDGER gate=k verdict=fail" "a constant-rate restamp of the SAME media FAILs gate (k)"
    else
      echo "  (skip: this ffmpeg has no setts bsf — the torn variant needs it)"
    fi ;;
esac

echo
echo "poc-scopes: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

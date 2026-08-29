#!/usr/bin/env bash
# 113-poc-type2-scopes.sh — an extractor emits a row for every picture it saw.
#
# THE DEFECT CLASS IS III.1, ONE LAYER DOWN. `pic_order_cnt_type = 2` streams
# carry no `pic_order_cnt_lsb` at all, so the POC extractor emitted NOTHING for
# those pictures. Downstream, gate (k) compared row count to packet count, saw
# them disagree, and reported UNPROVEN with a "count" symptom — an ABSENCE
# produced by the extractor reading as a fact about the FILE. Measured
# 2026-08-29 on a mixed type-0/type-2 capture: `POC rows=50, timestamped
# packets=100`.
#
# The row is not a guess. For type 2 the spec DEFINES display order to equal
# decode order, so the picture's presentation position is fully derivable — it
# is emitted with a provenance marker saying where it came from, never left as
# a gap for a counter to trip over.
#
# NO BAR MOVES. A type-2 scope is judged by ITS OWN rule (presentation must
# advance with decode order), not exempted. `pic_order_cnt_type = 1` is still
# unsupported, and such a scope is UNPROVEN by index with its picture count —
# exactly like an unfittable one.
#
# Standalone: bash tests/regression.d/113-poc-type2-scopes.sh
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

echo "== 1. unit lane: a type-2 scope is judged by decode order, not exempted =="
# 5-column table: idr,poc,l2,src,pts. src=t2 marks a row whose position was
# DERIVED from decode order (the spec's own rule for pic_order_cnt_type 2).
awk 'BEGIN{ for(i=0;i<30;i++) printf "%d,%d,,t2,%d\n", (i==0?1:0), i, 1000+i*3600 }' > "$WORK/t2ok.csv"
eval "$(pf_poc_lattice "$WORK/t2ok.csv")"
[ "${PL_TOTAL:-0}" -eq 30 ] && ok "all 30 type-2 rows judged" || no "PL_TOTAL=${PL_TOTAL:-} want 30"
[ "${PL_OFF:-1}" -eq 0 ]    && ok "a type-2 scope whose presentation advances with decode order is on-slot" \
  || no "PL_OFF=${PL_OFF:-} — a correct type-2 scope was condemned"
[ "${PL_NOFIT:-1}" -eq 0 ]  && ok "…and it is EVALUATED, not counted unfittable" || no "PL_NOFIT=${PL_NOFIT:-} want 0"

echo
echo "== 2. …and it has teeth: a type-2 scope out of decode order FAILs =="
awk 'BEGIN{ for(i=0;i<30;i++){ t=1000+i*3600; if(i%2) t-=7200; printf "%d,%d,,t2,%d\n", (i==0?1:0), i, t } }' > "$WORK/t2torn.csv"
eval "$(pf_poc_lattice "$WORK/t2torn.csv")"
[ "${PL_OFF:-0}" -gt 0 ] && ok "presentation that does not advance with decode order is off-slot (off=$PL_OFF)" \
  || no "a torn type-2 scope was not caught (off=${PL_OFF:-})"
[ "${PL_NOFIT:-1}" -eq 0 ] && ok "…and it is reported as JUDGED-and-wrong, not as unfittable" || no "a torn type-2 scope was filed as unfittable"

echo
echo "== 3. pic_order_cnt_type 1 stays UNPROVEN by index, with its count =="
{
  awk 'BEGIN{ for(i=0;i<20;i++) printf "%d,%d,2,lsb,%d\n", (i==0?1:0), 2*i, 1000+2*i*1800 }'
  awk 'BEGIN{ for(i=0;i<12;i++) printf "0,0,,none,%d\n", 900000+i*1800 }'
} > "$WORK/t1.csv"
eval "$(pf_poc_lattice "$WORK/t1.csv")"
[ "${PL_NOFIT:-0}" -ge 1 ] && ok "the unsupported scope is counted unproven (nofit=$PL_NOFIT)" \
  || no "PL_NOFIT=${PL_NOFIT:-} — an unsupported scope was judged anyway"
[ "${PL_NOFIT_PICS:-0}" -eq 12 ] && ok "…with its exact picture count (12)" || no "PL_NOFIT_PICS=${PL_NOFIT_PICS:-} want 12"
[ "${PL_ON:-0}" -ge 20 ] && ok "…and the type-0 scope beside it is still reported on-slot" || no "PL_ON=${PL_ON:-} want >=20"

echo
echo "== 4. the extractor emits a row for every picture it saw (III.1) =="
ff -f lavfi -i "testsrc2=s=160x120:r=25" -t 2 -c:v libx264 -g 25 -bf 3 -pix_fmt yuv420p -f mpegts "$WORK/t0.ts"
ff -f lavfi -i "mandelbrot=s=160x120:r=25" -t 2 -c:v libx264 -g 25 -bf 0 -pix_fmt yuv420p -f mpegts "$WORK/t2.ts"
cat "$WORK/t0.ts" "$WORK/t2.ts" > "$WORK/mixed.ts"
types=$(ffmpeg -nostdin -hide_banner -nostats -i "$WORK/mixed.ts" -map 0:v:0 -c copy -bsf:v trace_headers \
        -f null - 2>&1 | awk '{for(i=1;i<=NF;i++) if($i=="pic_order_cnt_type"){print $NF; break}}' | sort -u | tr '\n' ' ')
case "$types" in
  *0*2*|*2*0*) ok "the fixture mixes pic_order_cnt_type 0 and 2 ($types)" ;;
  *) echo "  SKIP: this libx264 minted only poc_type $types — no mixed fixture here"
     echo "poc-type2-scopes: $pass passed, $fail failed"; exit $([ "$fail" -eq 0 ] && echo 0 || echo 1) ;;
esac
npkt=$(ffprobe -v error -select_streams v:0 -show_entries packet=pts -of csv=p=0 "$WORK/mixed.ts" | grep -c . || true)
eval "$(pf_trace_census "$WORK/mixed.ts" "$WORK/poc.csv" "$WORK/sps" 2>/dev/null)"
nrow=$(grep -c . "$WORK/poc.csv" 2>/dev/null || true)
[ "${nrow:-0}" -eq "${PC_PICS:-0}" ] \
  && ok "one POC row per coded picture ($nrow of ${PC_PICS:-0}) — no picture emits nothing" \
  || no "the extractor emitted $nrow rows for ${PC_PICS:-0} pictures — an absence it created"
# provenance is the LAST column, so the marker ends the row
nt2=$(grep -c ',t2$' "$WORK/poc.csv" || true)
nlsb=$(grep -c ',lsb$' "$WORK/poc.csv" || true)
[ "${nt2:-0}" -gt 0 ]  && ok "type-2 rows carry their provenance marker ($nt2 rows)" || no "no ,t2 rows emitted"
[ "${nlsb:-0}" -gt 0 ] && ok "…and type-0 rows carry theirs ($nlsb rows)" || no "no ,lsb rows emitted"
[ $(( nt2 + nlsb )) -eq "${nrow:-0}" ] && ok "every row is accounted for by a provenance marker" \
  || no "$(( nt2 + nlsb )) marked rows of $nrow — some row carries no provenance"
# and the modulus column is EMPTY on a type-2 row: MaxPicOrderCntLsb is only
# defined for pic_order_cnt_type 0, and carrying the previous SPS's value into
# a type-2 scope would publish a modulus that does not apply there
grep -q '^[01],[0-9]*,,t2$' "$WORK/poc.csv" \
  && ok "type-2 rows publish no MaxPicOrderCntLsb (it is undefined for them)" \
  || no "a type-2 row carries a modulus that does not apply to it"

echo
echo "== 5. end to end: the mixed capture is EVALUATED, not declined on a count =="
ff -i "$WORK/mixed.ts" -map 0:v:0 -c copy -tag:v avc1 "$WORK/mixed.mov"
o=$(bash "$SC/verify.sh" "$WORK/mixed.ts" "$WORK/mixed.mov" 2>&1)
hasnt "$o" "VERIFY_LEDGER gate=k verdict=unproven" "gate (k) no longer declines a mixed-type capture"
hasnt "$o" "POC rows=$((npkt / 2))" "…and the count-disagreement symptom is gone"
has "$o" "VERIFY_LEDGER gate=k verdict=pass" "it evaluates it, and a faithful copy passes"

echo
echo "poc-type2-scopes: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

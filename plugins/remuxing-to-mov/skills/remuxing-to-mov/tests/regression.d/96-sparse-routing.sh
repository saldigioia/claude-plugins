#!/usr/bin/env bash
# 96-sparse-routing.sh — WO-1.15.20 S1/S2/S3: the sparse-unstamped class routes
# to one place, and every router agrees on it.
#
# THE CLASS (2024-VMA capture, 25.38 GB): reorder pyramid, half_ts=no, and
# PTS-complete EXCEPT 24 isolated unstamped packets in 424,645 — 5.65e-5, three
# clusters, two with stride 2. Too few by four orders of magnitude to be
# pairfill's ~0.5 pair signature; not zero, which is the only thing the derive
# gate used to accept.
#
# WHAT THIS SUITE PINS
#   §1 the sparse profile routes to Rung 3-DERIVE from diagnose.sh AND from
#      auto.sh, with the SAME verdict — pre-round, diagnose sent this profile
#      to pairfill (its fallback branch) while auto.sh refused it outright, so
#      the two tools gave contradictory routing for one measurement.
#   §2 THE SIXTH DEFECT (S1): that fallback promised "its own gates refuse
#      (exit 3) if the shape is not the pair class". MEASURED FALSE — pairfill's
#      shape checks WARN and build. An operator following the verdict got a
#      ~26.8 GB build and a post-write timeline-gate rejection, on the promise
#      the tool would refuse first. No route may be printed on the strength of
#      a refusal that does not exist.
#   §3 the band ABOVE the sparse bound still has no rung, and both tools say so
#      in the same terms (the NO-AUTOMATIC-ROUTE verdict F9 introduced, with
#      its retired "no rung composes" claim gone — one DOES now).
#   §4 the S0 rung-1 skip: a copy rung cannot survive unstamped packets, so the
#      ladder decides that from the probe instead of writing full-length to
#      rediscover it (27.2 GB, twice, on the field capture).
#   §5 S3, the evidence-scope mismatch: PF_NOPTS_FRAC is a 240-packet HEAD
#      WINDOW with quantum 1/240, and printed alone it read a whole-file
#      5.65e-5 as 0.004 — a 70x overread that pushed the file across a routing
#      cutoff. The raw counts and the window are printed beside it now.
#
# Injection is the house hook pattern (test 64): PF_PKT_FILE feeds pf_detect's
# coded-rate/nopts column, PF_PKT_TICKS_FILE feeds pf_reorder_scan's pyramid.
# Nothing here writes a byte of media — routing is decided before any build.
#
# Standalone: bash tests/regression.d/96-sparse-routing.sh
# Exit 0 = all assertions pass; 1 = a regression; 2 = env failure.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ff () { ffmpeg -nostdin -y -v error "$@"; }

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
hasnt () { case "$1" in *"$2"*) no "$3 [unexpected: $2]";; *) ok "$3";; esac; }

MKV="$WORK/reord.mkv"
ff -f lavfi -i testsrc2=s=320x240:r=30000/1001 -t 3 -c:v libx264 -g 30 -bf 8 \
   -x264opts b-pyramid=normal:b-adapt=0 -pix_fmt yuv420p "$MKV" || { echo "MKV mint failed"; exit 2; }

# --- the injected columns ----------------------------------------------------
# SPARSE: 240 rows (pf_coded_rate's window), 2 unstamped -> 2/240 = 0.008.
# Nonzero, so PTS-completeness is absent; well inside the 0.01 sparse bound;
# nowhere near the 0.35 floor of the pair signature. Written as a RELATIONSHIP
# — two holes in the window is the smallest nonzero fraction that window can
# express, which is exactly the resolution problem §5 is about.
awk 'BEGIN{for(i=0;i<240;i++){ if(i==100||i==102) print "N/A,N/A";
      else printf "%.6f,%.6f\n", i*0.033367, i*0.033367 }}' > "$WORK/sparse.csv"
# ABOVE THE BAND: 24 of 240 = 0.1 — past the sparse bound, far below 0.35.
awk 'BEGIN{for(i=0;i<240;i++){ if(i%10==0) print "N/A,N/A";
      else printf "%.6f,%.6f\n", i*0.033367, i*0.033367 }}' > "$WORK/midband.csv"
# the SAME sparse fraction at ~2x the container frame rate, so the ratio test
# reads paff=yes (H1). The F9 rung-1 skip lives on the PAFF arm of the ladder,
# which is the arm the 2024-VMA capture takes.
awk 'BEGIN{for(i=0;i<240;i++){ if(i==100||i==102) print "N/A,N/A";
      else printf "%.6f,%.6f\n", i*0.016683, i*0.016683 }}' > "$WORK/sparse_paff.csv"
# the understated pyramid (test 64's column): reorder=yes, dts_short=yes
awk 'BEGIN{for(i=0;i<60;i++){p=i*17; if(i==2)p=8*17; else if(i==8)p=2*17; printf "%d,%d\n", p, i*17-34}}' > "$WORK/pyr.csv"

echo "== 1. the sparse profile: diagnose and auto route to the SAME rung =="
D=$(PF_PKT_FILE="$WORK/sparse.csv" PF_PKT_TICKS_FILE="$WORK/pyr.csv" PF_PPF_IN=2 \
      bash "$SC/diagnose.sh" "$MKV" 2>&1)
A=$(PF_PKT_FILE="$WORK/sparse.csv" PF_PKT_TICKS_FILE="$WORK/pyr.csv" PF_PPF_IN=2 \
      bash "$SC/auto.sh" "$MKV" "$WORK/dry.mov" --dry-run 2>&1)
has   "$D" "derive-dts.sh"  "diagnose routes the sparse class to Rung 3-DERIVE"
has   "$A" "3-DERIVE"       "auto.sh plans the same rung for the same measurement"
has   "$D" "sparse-unstamped" "…and diagnose names the class it measured"
has   "$D" "pre-pass"       "…and says the rung stamps the holes before deriving"
hasnt "$D" "pairfill-paff.sh" "diagnose does NOT route the sparse class to pairfill"
hasnt "$A" "pair-fill"      "auto.sh does not fall through to pair-fill either"

echo
echo "== 2. the sixth defect: no route printed on a refusal that does not exist =="
# pairfill's shape checks are warnings that proceed. The word "refuse" must not
# appear attached to an exit-3 claim about pairfill's SHAPE anywhere in the
# routing prose — the refusals it really has are codec, rate-map, alternation.
hasnt "$D" "its own gates refuse (exit 3) if the shape is not the pair class" \
      "the false exit-3 promise is gone from the routing verdict"
P=$(PF_PKT_FILE="$WORK/sparse.csv" bash "$SC/pairfill-paff.sh" "$MKV" "$WORK/pf.mov" 2>&1); prc=$?
case "$prc" in 3) ok "pairfill refuses this input for a reason it REALLY has (exit 3)";;
  *) no "pairfill exit $prc — the suite's premise (it warns and proceeds on shape) needs re-measuring";; esac
hasnt "$P" "half_ts=yes" "pairfill agrees the pair signature is absent here"

echo
echo "== 3. above the sparse bound: no rung, and both tools say the same thing =="
D2=$(PF_PKT_FILE="$WORK/midband.csv" PF_PKT_TICKS_FILE="$WORK/pyr.csv" PF_PPF_IN=2 \
       bash "$SC/diagnose.sh" "$MKV" 2>&1)
A2=$(PF_PKT_FILE="$WORK/midband.csv" PF_PKT_TICKS_FILE="$WORK/pyr.csv" PF_PPF_IN=2 \
       bash "$SC/auto.sh" "$MKV" "$WORK/dry2.mov" --dry-run 2>&1)
has   "$D2" "NO AUTOMATIC ROUTE" "diagnose declines to route the mid-band profile"
hasnt "$D2" "scripts/pairfill-paff.sh \"" "…and offers no pairfill command for it"
# the claim F9 shipped and this round retired: a rung DOES compose fill -> derive
hasnt "$D2" "no rung composes" "the retired 'no rung composes' claim is gone"
hasnt "$A2" "no rung composes" "…from auto.sh's verdict too"

echo
echo "== 4. S0: the copy rung is decided from the probe, never written to discover =="
# nopts>0 means the muxer must invent timing for those packets and the
# confession gate then refuses the output — knowable before the first byte.
# This needs a profile whose FIRST rung is the copy (no pyramid injection, so
# probe does not recommend 3-derive outright); the ladder then reaches the
# reorder branch where the skip lives. No PyAV, so the derive escalation stops
# at its bootstrap and nothing is ever built.
mkdir -p "$WORK/nodata"
S0=$(PF_PKT_FILE="$WORK/sparse_paff.csv" CLAUDE_PLUGIN_DATA="$WORK/nodata"        bash "$SC/auto.sh" "$MKV" "$WORK/s0.mov" 2>&1)
has "$S0" "skipping Rung" "auto.sh skips the copy rung on an unstamped-packet source"
has "$S0" "refusal is predetermined" "…and says why the write would have been wasted"
hasnt "$S0" "attempting Rung 0" "…so the copy rung is never attempted at all"
has "$S0" "nopts_frac=0.008" "…and the skip quotes the measurement that decided it"
ls "$WORK"/s0.mov* >/dev/null 2>&1 && no "a skipped-copy run still wrote an artifact" || ok "nothing written"
ls "$WORK"/dry.mov* >/dev/null 2>&1 && no "--dry-run wrote an artifact" || ok "nothing written (--dry-run)"

echo
echo "== 4b. the plan labels what it measured (Article II.3) =="
# widening the derive route to the sparse class made a flat "(PTS-complete)"
# false for every profile that arrives with holes in it
has  "$A" "(sparse-unstamped" "the sparse profile is labelled sparse, not complete"
C=$(PF_PKT_TICKS_FILE="$WORK/pyr.csv" PF_PPF_IN=2 bash "$SC/auto.sh" "$MKV" "$WORK/c.mov" --dry-run 2>&1)
has  "$C" "nopts_frac=0.000 (PTS-complete)" "…and a genuinely complete column still reads complete"

echo
echo "== 5. S3: the fraction prints its own resolution =="
PR=$(PF_PKT_FILE="$WORK/sparse.csv" PF_PKT_TICKS_FILE="$WORK/pyr.csv" PF_PPF_IN=2 \
       bash "$SC/probe.sh" "$MKV" 2>&1)
has "$PR" "untimestamped packets: 2/240" "probe prints the raw counts, not just the fraction"
has "$PR" "head window" "…and names the window they were measured over"
has "$PR" "whole-file count decided at the rung" "…and says who decides authoritatively"

echo
echo "sparse-routing: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

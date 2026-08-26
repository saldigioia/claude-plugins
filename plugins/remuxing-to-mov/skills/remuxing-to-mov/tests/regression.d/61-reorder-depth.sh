#!/usr/bin/env bash
# 61-reorder-depth.sh — Phase 1 "measure right": the units defect and the four
# gates that inherited it.
#
# THE INCIDENT. A 54.6 GB MKV capture of the 2023 VMAs is ordinary interlaced
# broadcast: field-coded H.264, one packet per FIELD. Matroska stores no DTS,
# ever, so ffmpeg reconstructs it — using a FRAME-unit reorder depth
# (has_b_frames) applied as a PACKET delay. On field packets that is short by
# exactly 2x, and 163,859 "non-monotonic DTS" events appeared out of nothing.
# The SPS is CORRECT (max_num_reorder_frames=2 frames = 4 fields, conforming).
# There is no defect in the stream. The defect is in ffmpeg's units — and then
# in every gate downstream that read the reconstructed column as if it were a
# source property.
#
# Pinned here, one section per work item:
#   1. P1.1 unit-aware depth: the real incident's tick shape classifies
#      match-field at D=4 with ppf=2 (the SPS is right); a progressive
#      B-pyramid of the same geometry classifies match-frame; the late-sps
#      class classifies UNKNOWN and never `understated` (unknown != zero); and
#      the understated arm is still reachable, so the narrowing did not delete
#      the non-conformance verdict.
#   1a. F3 the WHOLE matrix, D against decl AND expected — including the band
#      `decl < D < expected`, which used to classify `none` and print nothing,
#      routing a file that needs DTS derivation to the class meaning "no
#      reorder worth mentioning". Plus PF_DTS_SHORT, the routing discriminant.
#   2. P1.2 both ratio hypotheses: a container declaring the FIELD rate selects
#      PAFF via H2 with the winning hypothesis announced, and the adversarial
#      true-progressive case (same ~1x ratio) stays paff=no — discriminated by
#      the ESSENCE probe, never the ratio, with the reason announced.
#   3. P1.4 presentation vs coded gap census: on a reorder pyramid carrying
#      exactly ONE real 2-frame gap the coded arm reports dozens and the
#      presentation arm reports 1 — and the tolerance-budget consumers spend
#      the presentation number, so the phantom budget can no longer widen
#      gate (f). gap.ts's LEGITIMATE ~4 s budget must be untouched.
#   4. P1.6 gate (g) in both directions: noisy-video/clean-audio -> REVIEW with
#      the source-baseline delta printed (v1.13.0 FAILed this: it counted every
#      stderr line of the whole invocation and charged it to each audio track);
#      genuinely broken audio -> still FAIL. Plus F2/F9: the baseline is matched
#      by PROPERTY, not by ordinal — a source with 2 audio tracks and an output
#      holding two copies of source a:0 (the dual-track shape) used to draw
#      opposite verdicts on byte-identical tracks, the FAIL side unwaivable.
#      The old pin could not see it: it passed the SAME file as source and
#      output, where the identity mapping is trivially right.
#      Plus P1c, three ways the same gate could be wrong in EITHER direction:
#      (a3) zero source audio is CERTAINTY, not doubt — the output's audio is
#      new by construction, so it FAILs (it had been demoted to REVIEW/exit 0,
#      carrying a note that claimed a candidate set which never existed);
#      (b2) ambiguity must not DISCARD a decisive delta — when the most
#      forgiving candidate still leaves a positive delta, damage is proven
#      whichever candidate is right, and the exit code goes back to 1 (the
#      delta<=0 half of the F2 rule is pinned unchanged beside it); (c2) the
#      title->a:0 provenance shortcut is DELETED — it reintroduced the ordinal
#      assumption and false-FAILed a byte-identical -c copy of a dual-track
#      master.
#   5. P1.5 coded-rate lead bias: the pyramid window reads 59.94, not 59.44.
#   6. F8 one window, at the LARGER of the two figures it reconciled — a gate's
#      evidence is never reduced to settle a naming argument.
#
# Standalone: bash tests/regression.d/61-reorder-depth.sh
# Exit 0 = all assertions pass; 1 = a regression; 2 = env/fixture failure.
# Regenerates its fixtures via make-fixtures.sh when missing. Scratch goes to
# mktemp (auto-cleaned); the repo tree is never written to. Timestamp shapes
# ride the house injection hooks (PF_PKT_TICKS_FILE / PF_PKT_FILE /
# DISC_DTS_FILE + the P1.1 PF_DECL_DEPTH_IN / PF_PPF_IN), because a real
# pair-timestamped field-coded capture cannot be minted by libx264 in a sandbox
# — the SYNTHESIS LIMIT stated at the top of tests/regression.sh.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"; FIX="$TESTS/fixtures"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
. "$SC/lib-paff.sh"

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
hasnt () { case "$1" in *"$2"*) no "$3 [unexpected: $2]";; *) ok "$3";; esac; }
ff () { ffmpeg -nostdin -hide_banner -loglevel error -y "$@"; }
numin () { awk "BEGIN{exit !($1 >= $2 && $1 <= $3)}"; }   # numin VAL LO HI

need=""
for f in late-sps.ts gap.ts m2v420.ts aac.ts; do [ -f "$FIX/$f" ] || need="$need $f"; done
if [ -n "$need" ]; then
  echo "== regenerating missing fixtures:$need =="
  # shellcheck disable=SC2086  # word splitting is the point
  bash "$TESTS/make-fixtures.sh" $need || { echo "fixture build failed"; exit 2; }
fi

# ---------------------------------------------------------------------------
echo "== 1. P1.1: the reorder depth, measured in the unit the packets are in =="
# THE INCIDENT'S OWN TICK SHAPE. Coded order, as FIELD PAIRS:
#   (0,17) (133,150) (67,83) (33,50) (100,117)
# i.e. a five-frame B-pyramid (presentation offsets 0,4,2,1,3 at ~33 ticks per
# frame) where every frame is TWO coded pictures ~17 ticks apart. Ten packets
# per pyramid, repeated to fill the window. D = max(coded index - presentation
# rank) = 4 coded pictures = the declared 2 FRAMES x 2 pictures/frame.
awk 'BEGIN{ n=split("0 17 133 150 67 83 33 50 100 117", a, " "); base=0
  for(rep=0; rep<20; rep++){
    for(i=1;i<=n;i++) printf "%d,%d\n", a[i]+base, base + (i-1)*17 - 34
    base += 167 } }' > "$WORK/field.ticks"
eval "$(PF_PKT_TICKS_FILE="$WORK/field.ticks" PF_DECL_DEPTH_IN=2 PF_PPF_IN=2 \
        PF_DTS_SOURCE_IN=reconstructed pf_reorder_scan DUMMY)"
[ "${PF_DEPTH_PICS:-x}" = 4 ] && ok "field pyramid -> D=4 coded pictures (the incident's measured depth)" \
  || no "field pyramid depth is ${PF_DEPTH_PICS:-?}, want 4"
[ "${PF_PPF:-x}" = 2 ] && ok "and 2 coded pictures per frame" || no "ppf=${PF_PPF:-?}, want 2"
[ "${PF_DEPTH_EXPECTED:-x}" = 4 ] && ok "expected = declared 2 frames x 2 = 4" || no "expected=${PF_DEPTH_EXPECTED:-?}"
[ "${PF_DEPTH_CLASS:-x}" = match-field ] \
  && ok "-> PF_DEPTH_CLASS=match-field: the SPS is correct and this stream CONFORMS" \
  || no "class=${PF_DEPTH_CLASS:-?}, want match-field"
[ "${PF_DTS_SOURCE:-x}" = reconstructed ] && ok "DTS provenance carried through as reconstructed" || no "dts source=${PF_DTS_SOURCE:-?}"
nt=$(pf_depth_note "$PF_DEPTH_CLASS" "$PF_DEPTH_PICS" "$PF_DECL_DEPTH" "$PF_PPF" "$PF_DEPTH_EXPECTED" "$PF_DEPTH_TS")
has "$nt" "SPS is CORRECT" "the announcement says the stream conforms (the reader is short, not the source)"
has "$nt" "can only UNDERSTATE" "and states that a windowed sample can only understate the depth"

# the SAME pyramid geometry, one packet per FRAME: match-frame
awk 'BEGIN{ n=split("0 4 2 1 3", a, " ")
  for(rep=0; rep<40; rep++) for(i=1;i<=n;i++)
    printf "%d,%d\n", (a[i]+rep*5)*3003, (rep*5+i-1)*3003 - 6006 }' > "$WORK/frame.ticks"
eval "$(PF_PKT_TICKS_FILE="$WORK/frame.ticks" PF_DECL_DEPTH_IN=2 PF_PPF_IN=1 \
        PF_DTS_SOURCE_IN=carried pf_reorder_scan DUMMY)"
{ [ "${PF_DEPTH_PICS:-x}" = 2 ] && [ "${PF_DEPTH_CLASS:-x}" = match-frame ]; } \
  && ok "same pyramid at 1 picture/frame -> D=2, class=match-frame (ordinary progressive)" \
  || no "progressive pyramid: D=${PF_DEPTH_PICS:-?} class=${PF_DEPTH_CLASS:-?}, want 2/match-frame"

# understated must stay REACHABLE — the narrowing must not delete the
# non-conformance verdict, only stop unknowns from wearing it
eval "$(PF_PKT_TICKS_FILE="$WORK/frame.ticks" PF_DECL_DEPTH_IN=0 PF_PPF_IN=1 pf_reorder_scan DUMMY)"
[ "${PF_DEPTH_CLASS:-x}" = understated ] \
  && ok "a stream presenting deeper than it declares is still called understated" \
  || no "understated arm unreachable (class=${PF_DEPTH_CLASS:-?})"

# a stream with no reorder at all
awk 'BEGIN{for(i=0;i<50;i++) printf "%d,%d\n", i*3003, i*3003}' > "$WORK/flat.ticks"
eval "$(PF_PKT_TICKS_FILE="$WORK/flat.ticks" PF_DECL_DEPTH_IN=0 PF_PPF_IN=1 pf_reorder_scan DUMMY)"
{ [ "${PF_DEPTH_PICS:-x}" = 0 ] && [ "${PF_DEPTH_CLASS:-x}" = none ]; } \
  && ok "flat PTS==DTS -> D=0, class=none" || no "flat: D=${PF_DEPTH_PICS:-?} class=${PF_DEPTH_CLASS:-?}"

echo
echo "== 1a. F3: the WHOLE D-vs-decl-vs-expected matrix, band included =="
# THE BAND THAT WAS MISSING. `decl < D < expected` classified as `none` — the
# class meaning "no reorder worth mentioning" — and pf_depth_note had no `none`
# arm, so it printed NOTHING at all. Observed on the pre-F3 tree: D=3 decl=2
# ppf=2 expected=4 -> none, silently. ffmpeg applies has_b_frames PACKETS of
# delay, so ANY D above the declared depth leaves a reconstructed DTS column
# short: that file needs exactly the derivation the D==expected case needs.
# The rule keys on the MECHANISM, so the band belongs to match-field.
# Shapes below are coded-order PTS permutations; D = max(coded index -
# presentation rank), so a block "3 4 5 0 1 2" travels 3 positions and gives
# D=3, "2 3 0 1" gives D=2, and so on.
mkshape () {   # mkshape FILE "coded order within a block" BLOCKLEN
  awk -v ord="$2" -v bl="$3" 'BEGIN{ n=split(ord,o," ")
    for(rep=0;rep<20;rep++) for(k=1;k<=n;k++)
      printf "%d,%d\n", (rep*bl+o[k])*17, (rep*bl+k-1)*17 - bl*17 }' > "$1"
}
mkshape "$WORK/d1.ticks" "1 0"             2
mkshape "$WORK/d2.ticks" "2 3 0 1"         4
mkshape "$WORK/d3.ticks" "3 4 5 0 1 2"     6
mkshape "$WORK/d5.ticks" "5 6 7 8 9 0 1 2 3 4" 10
# cell SHAPE DECL PPF WANT_D WANT_CLASS WANT_SHORT
cell () {
  eval "$(PF_PKT_TICKS_FILE="$1" PF_DECL_DEPTH_IN="$2" PF_PPF_IN="$3" pf_reorder_scan DUMMY)"
  local lbl="D=${PF_DEPTH_PICS} decl=$2 ppf=$3 expected=${PF_DEPTH_EXPECTED}"
  { [ "${PF_DEPTH_PICS:-x}" = "$4" ] && [ "${PF_DEPTH_CLASS:-x}" = "$5" ] \
    && [ "${PF_DTS_SHORT:-x}" = "$6" ]; } \
    && ok "$lbl -> $5, dts_short=$6" \
    || no "$lbl -> class=${PF_DEPTH_CLASS:-?} dts_short=${PF_DTS_SHORT:-?} (want $5 / $6, D wanted $4)"
}
# ppf=2 (the field-coded column): expected = 2*decl = 4
cell "$WORK/flat.ticks"  2 2 0 none        no
cell "$WORK/d1.ticks"    2 2 1 none        no
cell "$WORK/d2.ticks"    2 2 2 none        no     # D == decl: the packet delay exactly covers it
cell "$WORK/d3.ticks"    2 2 3 match-field yes    # <- THE BAND F3 ADDS (was: none, and silent)
cell "$WORK/field.ticks" 2 2 4 match-field yes    # D == expected: the VMA class, unchanged
cell "$WORK/d5.ticks"    2 2 5 understated yes
# ppf=1 (progressive): expected == decl, so the band is EMPTY and every cell
# must read exactly as it did before F3
cell "$WORK/flat.ticks"  2 1 0 none        no
cell "$WORK/d1.ticks"    2 1 1 none        no
cell "$WORK/d2.ticks"    2 1 2 match-frame no     # D == expected == decl
cell "$WORK/d3.ticks"    2 1 3 understated yes
cell "$WORK/d5.ticks"    0 1 5 understated yes
# unknown inputs never carry a verdict — but PF_DTS_SHORT survives an unknown
# ppf, because ffmpeg's delay is counted in packets whatever the ppf is
cell "$WORK/d3.ticks" unknown 2 3 unknown unknown
cell "$WORK/d3.ticks" 2 unknown 3 unknown yes
# and the routing fact is never silent in human output
eval "$(PF_PKT_TICKS_FILE="$WORK/d3.ticks" PF_DECL_DEPTH_IN=2 PF_PPF_IN=2 pf_reorder_scan DUMMY)"
nt=$(pf_depth_note "$PF_DEPTH_CLASS" "$PF_DEPTH_PICS" "$PF_DECL_DEPTH" "$PF_PPF" "$PF_DEPTH_EXPECTED" "$PF_DEPTH_TS")
has "$nt" "PF_DTS_SHORT=yes" "the band ANNOUNCES the routing discriminant (never silent)"
has "$nt" "must be DERIVED" "and says what follows from it"
eval "$(PF_PKT_TICKS_FILE="$WORK/flat.ticks" PF_DECL_DEPTH_IN=2 PF_PPF_IN=1 pf_reorder_scan DUMMY)"
nt=$(pf_depth_note "$PF_DEPTH_CLASS" "$PF_DEPTH_PICS" "$PF_DECL_DEPTH" "$PF_PPF" "$PF_DEPTH_EXPECTED" "$PF_DEPTH_TS")
has "$nt" "within the declared" "class=none now has an arm too (it used to print nothing at all)"
hasnt "$nt" "PF_DTS_SHORT=yes" "and a covered depth does not claim to be short"
# the machine surface carries the discriminant
kv=$(bash "$SC/probe.sh" "$FIX/aac.ts" --kv 2>&1)
has "$kv" "PF_DTS_SHORT=" "probe --kv emits PF_DTS_SHORT"
js=$(bash "$SC/probe.sh" "$FIX/aac.ts" --json 2>&1)
has "$js" '"dts_short"' "probe --json carries it too"

echo
echo '== 1b. unknown != zero: an unreadable SPS never routes as `understated` =='
# late-sps.ts declares has_b_frames=1 — underneath an error flood. A number a
# parser produces while screaming is not a declaration.
# shellcheck disable=SC2046  # word splitting is the point: "DEPTH NOISE"
set -- $(pf_decl_depth "$FIX/late-sps.ts"); ls_decl="$1"; ls_noise="$2"
[ "$ls_decl" = unknown ] && ok "late-sps.ts declared depth reads UNKNOWN (parse flood: $ls_noise lines)" \
  || no "late-sps.ts declared depth reads '$ls_decl' — the flood guard is not firing (noise=$ls_noise)"
[ "${ls_noise:-0}" -ge 20 ] && ok "the flood is real and measured ($ls_noise lines on one has_b_frames read)" \
  || no "expected a >=20-line flood on late-sps.ts, got $ls_noise"
# shellcheck disable=SC2046
set -- $(pf_decl_depth "$FIX/gap.ts"); cl_decl="$1"; cl_noise="$2"
{ [ "$cl_decl" = 2 ] && [ "${cl_noise:-1}" -eq 0 ]; } \
  && ok "a healthy fixture still yields a believed declaration (gap.ts: has_b_frames=2, 0 noise lines)" \
  || no "gap.ts declaration wrong: decl=$cl_decl noise=$cl_noise (the guard must not eat healthy files)"
# and the essence probe refuses to conclude on the same file: a decoder that is
# erroring is not counting (raw ratio 138/240 = 0.58 would have said "ppf=2")
[ "$(pf_ppf_probe "$FIX/late-sps.ts")" = unknown ] \
  && ok "the essence probe returns unknown on the undecodable head (never a false ppf=2)" \
  || no "essence probe concluded '$(pf_ppf_probe "$FIX/late-sps.ts")' on late-sps.ts"
[ "$(pf_ppf_probe "$FIX/gap.ts")" = 1 ] && ok "and measures 1 picture/frame on a healthy progressive fixture" \
  || no "essence probe on gap.ts read '$(pf_ppf_probe "$FIX/gap.ts")', want 1"
# the whole classifier on that file, with a DEEP pyramid injected: still unknown
eval "$(PF_PKT_TICKS_FILE="$WORK/field.ticks" pf_reorder_scan "$FIX/late-sps.ts")"
[ "${PF_DEPTH_CLASS:-x}" = unknown ] \
  && ok "late-sps class + a depth-4 shape -> class=unknown, NOT understated" \
  || no "late-sps class routed as '${PF_DEPTH_CLASS:-?}' — an unreadable SPS must never carry a verdict"
hasnt "${PF_DEPTH_CLASS:-x}" "understated" "unknown is not a non-conformance finding"
o=$(bash "$SC/diagnose.sh" "$FIX/late-sps.ts" 2>&1)
has "$o" "reorder depth:" "diagnose announces the depth in its human report"
has "$o" "NOT classified" "and says out loud that it could not classify this one"

echo
echo "== 2. P1.2: the ratio is tested against BOTH hypotheses =="
ff -f lavfi -i "testsrc2=s=160x120:r=50:duration=3" -c:v libx264 -preset ultrafast \
   -g 25 -pix_fmt yuv420p -f mpegts "$WORK/p50.ts" || { echo "cannot mint the 50p control"; exit 2; }
# H2 — the mkvmerge shape: the container declares the FIELD rate, so the coded
# rate reads ~1x it. Only the ESSENCE probe can tell this apart from 50p.
eval "$(PF_PPF_IN=2 pf_detect "$WORK/p50.ts")"
{ [ "$PF_PAFF" = yes ] && [ "$PF_RATIO_HYP" = h2 ]; } \
  && ok "field-rate-declaring container + ppf=2 -> PAFF via H2 (ratio $PF_RATIO)" \
  || no "H2 did not fire: paff=$PF_PAFF hyp=$PF_RATIO_HYP ratio=$PF_RATIO"
{ [ "$PF_FIELD_RATE" = 50 ] && [ "$PF_TIMESCALE" = 50000 ]; } \
  && ok "and PF_FIELD_RATE is the container fps itself (50 / 50000) — pairfill is no longer starved" \
  || no "H2 field rate wrong: $PF_FIELD_RATE / $PF_TIMESCALE"
nh=$(pf_hyp_note "$PF_RATIO_HYP" "$PF_RATIO" "$PF_PPF" "$PF_NOMINAL_FPS" "$PF_FIELD_RATE")
has "$nh" "H2 WINS" "the winning hypothesis is ANNOUNCED, not silent"
has "$nh" "ESSENCE probe" "and the announcement names what decided it"
# ADVERSARIAL: a true 59.94p/50p progressive feed gives the SAME ~1x ratio
eval "$(PF_PPF_IN=1 pf_detect "$WORK/p50.ts")"
{ [ "$PF_PAFF" = no ] && [ "$PF_RATIO_HYP" = none ]; } \
  && ok "true progressive at the same ~1x ratio stays paff=no (essence measured 1 picture/frame)" \
  || no "adversarial 50p misread as PAFF: paff=$PF_PAFF hyp=$PF_RATIO_HYP"
nh=$(pf_hyp_note "$PF_RATIO_HYP" "$PF_RATIO" "$PF_PPF" "$PF_NOMINAL_FPS" "$PF_FIELD_RATE")
has "$nh" "REJECTED" "and the rejection is announced with its reason"
# unknown is not yes
eval "$(PF_PPF_IN=unknown pf_detect "$WORK/p50.ts")"
[ "$PF_PAFF" = no ] && ok "ppf=unknown -> PAFF stays no (unknown is never yes)" || no "unknown ppf routed as PAFF"
nh=$(pf_hyp_note "$PF_RATIO_HYP" "$PF_RATIO" "$PF_PPF" "$PF_NOMINAL_FPS" "$PF_FIELD_RATE")
has "$nh" "could not measure pictures-per-frame" "and the report says WHY it stayed no"
has "$nh" "ratio alone may never" "naming the adversarial case the ratio cannot separate"
# H1 unchanged: a genuine 2x coded rate still decides on the ratio, no essence needed
awk 'BEGIN{for(i=0;i<240;i++) printf "%.6f,%.6f\n", i*0.02, i*0.02}' > "$WORK/x2.csv"
eval "$(PF_PKT_FILE="$WORK/x2.csv" pf_detect "$FIX/aac.ts")"
{ [ "$PF_PAFF" = yes ] && [ "$PF_RATIO_HYP" = h1 ] && [ "$PF_FIELD_RATE" = 50 ]; } \
  && ok "H1 is untouched: 50 AU/s over a 25 fps container -> PAFF, field rate 50" \
  || no "H1 regressed: paff=$PF_PAFF hyp=$PF_RATIO_HYP ratio=$PF_RATIO fr=$PF_FIELD_RATE"
# and the machine surface carries all of it
kv=$(bash "$SC/probe.sh" "$FIX/aac.ts" --kv 2>&1)
for k in PF_DEPTH_PICS PF_DECL_DEPTH PF_PPF PF_DEPTH_CLASS PF_DTS_SOURCE PF_RATIO_HYP PF_CODED_RATE_SPAN PF_RATE_METHOD; do
  has "$kv" "$k=" "probe --kv emits $k"
done
js=$(bash "$SC/probe.sh" "$FIX/aac.ts" --json 2>&1)
has "$js" '"depth_class"' "probe --json carries the depth class too"
has "$js" '"dts_source"' "probe --json carries the DTS provenance"
# append-only: nothing that existed was renamed away
for k in PF_PAFF PF_FIELD_RATE PF_TIMESCALE PF_CODED_RATE PF_NOMINAL_FPS PF_NOPTS_FRAC PF_HALF_TS PF_REORDER; do
  has "$kv" "$k=" "pre-existing field $k survives (append-only API)"
done

echo
echo "== 3. P1.4: the gap census, in the order the claim is about =="
# A reorder pyramid over presentation indices 0..99 with 50 and 51 REMOVED:
# exactly ONE real gap, two frames wide. Coded order sees the pyramid's own
# excursions as dozens of forward jumps; presentation order sees the one gap.
awk 'BEGIN{ n=0
  for(i=0;i<100;i++){ if(i==50||i==51) continue; L[n++]=i }
  o[1]=1;o[2]=5;o[3]=3;o[4]=2;o[5]=4
  for(g=0; g*5+4 < n; g++) for(k=1;k<=5;k++){ printf "%.6f\n", L[g*5+o[k]-1]*0.04 } }' > "$WORK/pyr.dts"
eval "$(DISC_DTS_FILE="$WORK/pyr.dts" DISC_FRAMEDUR_IN=0.04 disc_scan)"
[ "${DISC_P_COUNT:-x}" = 1 ] && ok "presentation arm: exactly 1 forward gap (the real one)" \
  || no "presentation arm counted ${DISC_P_COUNT:-?}, want 1"
numin "${DISC_P_MISSING:-0}" 0.07 0.09 && ok "and ~0.08s dropped = the two missing frames" \
  || no "presentation missing=${DISC_P_MISSING:-?}, want ~0.080"
[ "${DISC_COUNT:-0}" -gt 5 ] && ok "coded arm OVERCOUNTS the same window (${DISC_COUNT} gaps, ${DISC_MISSING}s) — the pyramid read as loss" \
  || no "coded arm did not overcount (${DISC_COUNT:-?}) — the fixture no longer demonstrates the defect"
awk "BEGIN{exit !(${DISC_MISSING:-0} > 10*${DISC_P_MISSING:-1})}" \
  && ok "the phantom budget is >10x the real one (${DISC_MISSING}s vs ${DISC_P_MISSING}s)" \
  || no "phantom/real ratio too small to prove the class"
# the consumers must SPEND the presentation number. Δ≈1s sits BETWEEN the two
# budgets: the coded figure would have widened the gate past it (a silent pass),
# the presentation figure must not.
ff -f lavfi -i "testsrc2=size=320x240:rate=25:duration=6" \
   -f lavfi -i "sine=frequency=440:duration=6:sample_rate=48000" \
   -map 0:v -map 1:a -c:v libx264 -preset ultrafast -g 25 -pix_fmt yuv420p \
   -c:a pcm_s16le -f mov "$WORK/clean.mov" || { echo "cannot mint the clean control"; exit 2; }
ff -i "$WORK/clean.mov" -map 0:a:0 -c copy -t 5 -f mov "$WORK/a5.mov"
ff -i "$WORK/clean.mov" -i "$WORK/a5.mov" -map 0:v:0 -map 1:a:0 -c copy -f mov "$WORK/offset.mov"
out=$(DISC_DTS_FILE="$WORK/pyr.dts" DISC_FRAMEDUR_IN=0.04 \
      bash "$SC/verify.sh" "$WORK/clean.mov" "$WORK/offset.mov" 2>&1)
has "$out" "in presentation order" "gate (f) names the presentation census as the budget's source"
has "$out" "coded-order census (dts column, comparison only)" "and prints the coded-order figure beside it, unhidden"
has "$out" "Budget spent: 0.080s" "the budget SPENT is the presentation number, not the 3.840s phantom"
has "$out" "sync REVIEW" "the 1s desync is FLAGGED — the phantom 3.8s budget no longer absorbs it"
hasnt "$out" "explained by measured source loss" "and it is NOT explained away by loss the program never suffered"
# the legitimate budget must be untouched: gap.ts really did drop ~4s
ff -i "$FIX/gap.ts" -map 0:v:0 -map 0:a:0 -c:v copy -c:a pcm_s16le -movflags +faststart -f mov "$WORK/gap.mov" \
  || { echo "gap.mov build failed"; exit 2; }
out=$(bash "$SC/verify.sh" "$FIX/gap.ts" "$WORK/gap.mov" 2>&1); rc=$?
has "$out" "explained by measured source loss" "gap.ts's REAL ~4s loss still widens gate (f) (the budget was narrowed, not deleted)"
{ [ "$rc" -eq 0 ] && case "$out" in *">> OK"*) true;; *) false;; esac; } \
  && ok "and the gappy build still reaches >> OK, exit 0" \
  || { no "gap.ts build verdict changed (rc=$rc)"; printf '%s\n' "$out" | tail -6 | sed 's/^/   /'; }
# the missing-timestamp guard: a census taken across holes buys NO tolerance
awk 'BEGIN{t=0; for(i=0;i<200;i++){ if(i%3==1) print "N/A"; else printf "%.6f\n", t; t+=0.04; if(i==100) t+=1.0 } }' > "$WORK/holes.dts"
eval "$(DISC_DTS_FILE="$WORK/holes.dts" DISC_FRAMEDUR_IN=0.04 disc_scan)"
[ "${DISC_P_NA:-0}" -gt 0 ] && ok "disc_scan counts the missing timestamps (DISC_P_NA=${DISC_P_NA})" || no "DISC_P_NA not reported"
[ "$(disc_budget_secs "${DISC_P_NA:-0}" "${DISC_P_MISSING:-0}")" = 0 ] \
  && ok "a gap census measured across holes buys 0s of tolerance (the ts-health V_NADTS rule, ported)" \
  || no "phantom budget still spendable across missing timestamps"
bn=$(disc_budget_note "${DISC_P_NA:-0}" "${DISC_P_COUNT:-0}")
has "$bn" "buy NO tolerance" "and the refusal to widen is announced, never silent"

echo
echo "== 4. P1.6: gate (g) measures AUDIO decode, both directions =="
# (a) noisy video, clean audio. Simply OPENING late-sps.ts emits hundreds of
# `-v error` parse lines before one audio sample is decoded; v1.13.0 charged
# every one of them to each audio track and set an UNWAIVABLE other_failed.
graw=$(ffmpeg -nostdin -v error -i "$FIX/late-sps.ts" -map 0:a:0 -vn -t 10 -f null - 2>&1 | grep -c .)
[ "${graw:-0}" -gt 0 ] \
  && ok "the old rule's trigger still fires here: $graw stderr line(s) on an AUDIO-ONLY bounded decode" \
  || no "late-sps.ts no longer floods on an audio-only decode — this arm proves nothing (got $graw)"
out=$(bash "$SC/verify.sh" "$FIX/late-sps.ts" "$FIX/late-sps.ts" 2>&1); rc=$?
has "$out" "a:0 source-baseline (identical bounded decode" "gate (g) runs the source baseline, exactly as (c)/(e) do"
has "$out" "delta: 0" "and prints the delta"
has "$out" "inherited/open-time noise, not a remux defect" "delta<=0 classifies as inherited, not as remux damage"
has "$out" ">> REVIEW" "verdict is REVIEW (v1.13.0 FAILed this file on open-time video notices)"
hasnt "$out" ">> FAIL" "no FAIL from lines the source reproduces one-for-one"
[ "$rc" -eq 0 ] && ok "REVIEW keeps verify's documented exit 0 (the printed verdict is the API)" || no "verify rc=$rc on a REVIEW"

# (a2) F9/F2: THE PIN ABOVE CANNOT SEE A MAPPING DEFECT. verify.sh SRC OUT with
# SRC == OUT makes the identity mapping trivially correct, so it pins "the
# mapping is the identity" — precisely the assumption the dual-track layout
# violates. dual-track.sh maps `0:a:0` TWICE, so on a source with >=2 audio
# tracks the positional map baselined output a:1 against source a:1, a
# different stream. Reproduced against the pre-F2 code: two BYTE-IDENTICAL
# output tracks drew OPPOSITE verdicts —
#     a:0  source: 2 / output: 2 / delta: 0  -> REVIEW
#     a:1  source: 0 / output: 2 / delta: 2  -> FAIL + unwaivable other_failed
# Here: source = video + a:0 DAMAGED mp2 + a:1 CLEAN mp2; output = two copies
# of source a:0. Raw ffmpeg is sanctioned test tooling for minting damage.
ff -i "$FIX/m2v420.ts" -map 0:a:0 -c copy "$WORK/f2clean.mp2" || { echo "cannot extract mp2"; exit 2; }
f2sz=$(wc -c < "$WORK/f2clean.mp2" | tr -d ' ')
cp "$WORK/f2clean.mp2" "$WORK/f2bad.mp2"
dd if=/dev/zero bs=1 count=4096 2>/dev/null | tr '\0' '\377' | \
  dd of="$WORK/f2bad.mp2" bs=1 seek=$((f2sz / 3)) conv=notrunc status=none
ff -i "$FIX/m2v420.ts" -i "$WORK/f2bad.mp2" -i "$WORK/f2clean.mp2" \
   -map 0:v:0 -map 1:a:0 -map 2:a:0 -c copy -f mpegts "$WORK/f2src.ts" \
  || { echo "cannot mint the 2-audio-track source"; exit 2; }
ff -i "$WORK/f2src.ts" -map 0:v:0 -map 0:a:0 -map 0:a:0 -c copy \
   -movflags +faststart -f mov "$WORK/f2out.mov" || { echo "cannot mint the two-copies build"; exit 2; }
# DISTINCT indices: ffprobe emits the stream section twice on a program-bearing
# container (nested under the program and at top level), so a plain line count
# reads double on any .ts — the same trap verify.sh's own census fell into.
f2n=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$WORK/f2src.ts" | LC_ALL=C sort -u | grep -c .)
[ "${f2n:-0}" -eq 2 ] && ok "fixture honesty: the source really has 2 audio tracks" \
  || no "f2 source has ${f2n:-?} audio track(s), want 2 — this pin proves nothing"
out=$(bash "$SC/verify.sh" "$WORK/f2src.ts" "$WORK/f2out.mov" 2>&1); rc=$?
hasnt "$out" ">> FAIL" "two byte-identical output tracks no longer draw an unwaivable FAIL"
has "$out" "source-baseline AMBIGUOUS" "the gate ANNOUNCES that it cannot identify its own baseline"
has "$out" "candidate source a:0 ->" "and prints the raw count of every candidate it considered"
has "$out" "candidate source a:1 ->" "…both of them, nothing hidden"
has "$out" "never an unwaivable FAIL" "with the reason: an unidentified baseline cannot prove damage"
# the two identical tracks must now be judged IDENTICALLY — that symmetry is
# the whole finding; opposite verdicts on identical bytes is the bug.
f2a=$(printf '%s\n' "$out" | grep -c 'a:0 source-baseline AMBIGUOUS')
f2b=$(printf '%s\n' "$out" | grep -c 'a:1 source-baseline AMBIGUOUS')
{ [ "${f2a:-0}" -ge 1 ] && [ "${f2b:-0}" -ge 1 ]; } \
  && ok "both copies of the same source stream are treated the same way" \
  || no "asymmetric treatment survives (a:0=$f2a a:1=$f2b)"
[ "$rc" -ne 1 ] && ok "and the run does not exit 1 on the false accusation (rc=$rc)" \
  || no "still exiting 1 on two identical tracks (rc=$rc)"
# P1c — THE PROVENANCE SHORTCUT IS GONE. g_srcmap used to short-circuit any
# output track titled "* (access)" / "* (original)" straight to source a:0,
# ahead of all four property passes, on the reasoning that dual-track.sh and
# pairfill-paff.sh build their pair from a:0 only. That is the ordinal
# assumption F2 exists to remove, wearing a title as a disguise, and it made
# the answer WORSE than the evidence it preceded (see (c2) below, which the
# shortcut FAILed). It was never latent either: ffprobe reports the QTFF
# track-name atom as TAG:name and g_asig reads it, so it fired on every
# dual-track/pairfill .mov this plugin builds.
# WHAT ITS REMOVAL COSTS HERE — measured, and the answer is nothing. The
# preserved original now resolves AMBIGUOUS (both source tracks are mp2 at the
# same rate/layout, the source carries no titles to separate them), and the
# most-forgiving-candidate rule scores the delta against source a:0 anyway —
# the very track the shortcut would have named — because a:0 is the one
# carrying the copied damage. Same verdict, reached from evidence.
if bash "$SC/dual-track.sh" "$WORK/f2src.ts" "$WORK/f2dt.mov" >/dev/null 2>&1; then
  out=$(bash "$SC/verify.sh" "$WORK/f2src.ts" "$WORK/f2dt.mov" 2>&1); rc=$?
  hasnt "$out" "dual-track provenance" "the title->a:0 shortcut is GONE (no ordinal assumption ahead of the evidence)"
  has "$out" "a:1 source-baseline AMBIGUOUS" "the preserved original is judged by the general matcher, which says so out loud"
  # RELATIONSHIP pin, not a constant (first-ever CI run, 2026-08-26): the "2"
  # this used to assert is decoder chatter measured on the macOS bench — the
  # Linux static builds count the same smear differently. What the gate owes
  # is the RELATIONSHIP: a:0's count registers (>0), and the most-forgiving
  # candidate IS that count with delta 0.
  n0=$(printf '%s\n' "$out" | sed -n 's/.*candidate source a:0 -> \([0-9][0-9]*\) decode line.*/\1/p' | head -1)
  { [ -n "${n0:-}" ] && [ "$n0" -ge 1 ]; } \
    && ok "…and prints source a:0's count ($n0 — the copied damage registers, build-measured)" \
    || no "candidate a:0 count missing/zero (got '${n0:-none}')"
  has "$out" "most forgiving candidate: ${n0:-X} / delta: 0" "the most forgiving candidate IS a:0, so the delta is the same 0 the shortcut produced"
  hasnt "$out" ">> FAIL" "a real dual-track build of this source still draws no FAIL"
  [ "$rc" -ne 1 ] && ok "and still does not exit 1 (rc=$rc) — removing the shortcut cost the verdict nothing" \
    || no "dual-track build now exits 1 (rc=$rc) — the shortcut's removal changed a verdict"
else
  echo "  (skip: dual-track.sh could not build from this fixture here)"
fi

# (a3) P1c-A — NO SOURCE AUDIO IS MAXIMAL CERTAINTY, NOT MAXIMAL DOUBT.
# g_srcmap's `none` mode was routed through the unattributed arm: g_ambig=1,
# REVIEW, exit 0 — and the machine-consumed note it emitted claimed the
# "candidate set left ambiguous by channels/rate/codec/language/title" when
# there had been no candidate set at all. When the source has ZERO audio
# streams every audio line in the output is new BY CONSTRUCTION, so the count
# is proven damage and the HEAD verdict (FAIL + unwaivable other_failed) is
# the correct one.
ff -i "$FIX/m2v420.ts" -map 0:v:0 -c copy -f mpegts "$WORK/nosrc.ts" \
  || { echo "cannot mint the video-only source"; exit 2; }
ff -i "$FIX/m2v420.ts" -i "$WORK/f2bad.mp2" -map 0:v:0 -map 1:a:0 -c copy \
   -movflags +faststart -f mov "$WORK/nosrc.mov" || { echo "cannot mint the new-audio build"; exit 2; }
nsn=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$WORK/nosrc.ts" | LC_ALL=C sort -u | grep -c .)
[ "${nsn:-1}" -eq 0 ] && ok "fixture honesty: the source really carries 0 audio tracks" \
  || no "the video-only source has ${nsn:-?} audio track(s) — this pin proves nothing"
out=$(bash "$SC/verify.sh" "$WORK/nosrc.ts" "$WORK/nosrc.mov" 2>&1); rc=$?
has   "$out" "the baseline is 0 BY CONSTRUCTION" "zero source audio -> the baseline is measured, not guessed"
has   "$out" "CERTAIN, not ambiguous" "…and the gate says so: there was never a candidate set to choose from"
hasnt "$out" "source-baseline AMBIGUOUS" "no ambiguity arm on a case with no candidates"
hasnt "$out" "candidate set left ambiguous" "and the FALSE ambiguity note is never emitted for it"
has   "$out" "new by construction" "the FAIL names the true reason (the source carries no audio to inherit from)"
has   "$out" ">> FAIL" "a positive count against an empty source is proven damage -> FAIL"
{ [ "$rc" -eq 1 ]; } && ok "and exits 1, the HEAD verdict (was REVIEW/exit 0)" || no "no-source-audio rc=$rc, want 1"
hasnt "$out" "VERIFY_SIGNATURE" "unwaivable (other_failed) — an essence defect is never waiver-eligible"

# (b2) P1c-B — AMBIGUITY MUST NOT DISCARD A DECISIVE DELTA. The ordinary
# broadcast main+SAP shape: two property-identical CLEAN source tracks, one
# damaged output track. Every candidate reads 0, so the delta is +2 whichever
# candidate is correct — damage is proven WITHOUT resolving the ambiguity. The
# gate computed that number, printed it, then threw it away because g_ambig
# short-circuited both verdict arms ahead of it: REVIEW, exit 0, on a file HEAD
# FAILed. auto.sh/batch.sh and every wrapper act on that exit code.
ff -i "$FIX/m2v420.ts" -i "$WORK/f2clean.mp2" -i "$WORK/f2clean.mp2" \
   -map 0:v:0 -map 1:a:0 -map 2:a:0 -c copy -f mpegts "$WORK/twin.ts" \
  || { echo "cannot mint the twin-track source"; exit 2; }
ff -i "$FIX/m2v420.ts" -i "$WORK/f2bad.mp2" -map 0:v:0 -map 1:a:0 -c copy \
   -movflags +faststart -f mov "$WORK/twin.mov" || { echo "cannot mint the damaged single-track build"; exit 2; }
out=$(bash "$SC/verify.sh" "$WORK/twin.ts" "$WORK/twin.mov" 2>&1); rc=$?
has "$out" "source-baseline AMBIGUOUS" "the ambiguity is still ANNOUNCED — the matcher was not weakened"
has "$out" "candidate source a:0 -> 0 decode line(s)" "every candidate's raw count is still printed (a:0)"
has "$out" "candidate source a:1 -> 0 decode line(s)" "…and a:1"
# same relationship-not-constant rule as (a) above: the delta's VALUE is
# build-measured decoder chatter; what is pinned is that it is computed,
# kept, and positive against the all-zero candidate set
d2=$(printf '%s\n' "$out" | sed -n 's|.*most forgiving candidate: 0 / delta: \([0-9][0-9]*\).*|\1|p' | head -1)
{ [ -n "${d2:-}" ] && [ "$d2" -ge 1 ]; } \
  && ok "the decisive delta is computed, kept, and positive (delta=$d2, build-measured)" \
  || no "decisive delta missing/zero (got '${d2:-none}')"
has "$out" "damage exceeds every candidate baseline" "…and NAMED as what it proves"
has "$out" "proven regardless of which source track corresponds" "with the reason: the ambiguity does not need resolving"
has "$out" ">> FAIL" "delta > 0 against EVERY candidate -> FAIL (was REVIEW)"
{ [ "$rc" -eq 1 ]; } && ok "and exits 1 again, the HEAD verdict (wrappers act on this)" || no "twin-track rc=$rc, want 1"
# the converse must hold: ambiguity with a NON-positive delta is still REVIEW
out=$(bash "$SC/verify.sh" "$WORK/f2src.ts" "$WORK/f2out.mov" 2>&1); rc=$?
has "$out" "An unidentified baseline cannot prove damage" "delta <= 0 under ambiguity keeps the F2 rule verbatim"
hasnt "$out" ">> FAIL" "…and still no FAIL there"
[ "$rc" -ne 1 ] && ok "…and still no exit 1 (rc=$rc) — the narrowing is delta-keyed, not a blanket re-arming" \
  || no "the delta<=0 ambiguity arm now exits 1 (rc=$rc)"

# (c2) P1c-C — THE CASE THE DELETED SHORTCUT GOT WRONG. A dual-track MASTER
# (a:0 = PCM access, a:1 = MP2 original) re-remuxed byte-for-byte with -c copy.
# The shortcut matched a:1's "(original)" title and hardcoded it to source a:0
# — the PCM track, which decodes clean — so a `-c copy` drew delta 2 -> FAIL +
# unwaivable other_failed. Matroska because ffmpeg's MOV muxer writes the name
# atom while ffprobe reports MKV's title directly; both feed the same g_asig
# field, and MKV keeps the fixture readable.
ff -i "$FIX/m2v420.ts" -map 0:a:0 -c:a pcm_s16le -f wav "$WORK/dtm_access.wav" \
  || { echo "cannot mint the access track"; exit 2; }
ff -i "$FIX/m2v420.ts" -i "$WORK/dtm_access.wav" -i "$WORK/f2bad.mp2" \
   -map 0:v:0 -map 1:a:0 -map 2:a:0 -c copy \
   -metadata:s:a:0 title="PCM 16-bit (access)" -metadata:s:a:0 language=eng \
   -metadata:s:a:1 title="MP2 (original)"     -metadata:s:a:1 language=eng \
   -f matroska "$WORK/dtm_src.mkv" || { echo "cannot mint the dual-track master"; exit 2; }
ff -i "$WORK/dtm_src.mkv" -map 0 -c copy -f matroska "$WORK/dtm_out.mkv" \
  || { echo "cannot mint the -c copy of the master"; exit 2; }
dtmt=$(ffprobe -v error -select_streams a:1 -show_entries stream_tags=title -of default=nw=1:nk=1 "$WORK/dtm_out.mkv" | head -1)
[ "$dtmt" = "MP2 (original)" ] && ok "fixture honesty: the copy really carries the '(original)' title the shortcut keyed on" \
  || no "the copy's a:1 title reads '$dtmt' — this pin no longer exercises the shortcut"
out=$(bash "$SC/verify.sh" "$WORK/dtm_src.mkv" "$WORK/dtm_out.mkv" 2>&1); rc=$?
has   "$out" "baseline chosen on: codec" "the property matcher, not a title, picks the baseline"
has   "$out" "identical bounded decode, source a:1" "…and it picks source a:1, the track a:1 actually came from"
hasnt "$out" "source a:0): source" "never source a:0, which the deleted shortcut hardcoded"
hasnt "$out" ">> FAIL" "a byte-identical -c copy of a dual-track master is no longer FAILed"
{ [ "$rc" -ne 1 ]; } && ok "and does not exit 1 (rc=$rc) — the false unwaivable accusation is gone" \
  || no "dual-track master copy still exits 1 (rc=$rc)"
# the single-source-track case is UNCHANGED: one candidate, no ambiguity
out=$(bash "$SC/verify.sh" "$FIX/m2v420.ts" "$WORK/f2out.mov" 2>&1)
hasnt "$out" "source-baseline AMBIGUOUS" "a 1-audio-track source still resolves to a:0 without ambiguity"
# (b) genuinely broken audio must STILL fail — the narrowing is a scoping fix,
# not a weakening. Raw ffmpeg is sanctioned test tooling for minting damage.
ff -i "$FIX/m2v420.ts" -map 0:a:0 -c copy "$WORK/a.mp2" || { echo "cannot extract mp2"; exit 2; }
asz=$(wc -c < "$WORK/a.mp2" | tr -d ' ')
cp "$WORK/a.mp2" "$WORK/bad.mp2"
dd if=/dev/zero bs=1 count=4096 2>/dev/null | tr '\0' '\377' | \
  dd of="$WORK/bad.mp2" bs=1 seek=$((asz / 3)) conv=notrunc status=none
ff -i "$FIX/m2v420.ts" -i "$WORK/bad.mp2" -map 0:v:0 -map 1:a:0 -c copy \
   -movflags +faststart -f mov "$WORK/badaud.mov" || { echo "cannot mint the broken-audio build"; exit 2; }
out=$(bash "$SC/verify.sh" "$FIX/m2v420.ts" "$WORK/badaud.mov" 2>&1); rc=$?
has "$out" "beyond the identical decode of the source" "a real audio defect is scored as the DELTA over the source"
has "$out" ">> FAIL" "truncated MP2 mid-window -> still FAIL"
[ "$rc" -eq 1 ] && ok "and still exits 1 (the dead/broken-audio class is intact)" || no "broken-audio rc=$rc, want 1"
# the clean deliverable keeps its exact pinned wording (WO 3.6 phrasing is API)
ff -i "$FIX/aac.ts" -c copy "$WORK/cross.mkv"
out=$(bash "$SC/verify.sh" "$FIX/aac.ts" "$WORK/cross.mkv" 2>&1) || true
has "$out" "tag N/A (non-QTFF); head decode clean" "a clean track still reports the unchanged one-liner (no baseline paid)"
hasnt "$out" "a:0 source-baseline" "and a clean gate never pays for a source decode (lazy baseline, gate (c)'s rule)"

echo
echo "== 5. P1.5: the coded rate no longer pays for the reorder lead =="
# 59.94 pyramid, depth 2: 79 coded groups of 3 (presentation offsets +2,+0,+1)
# covering pictures 0..236, plus ONE more coded picture (239). The window then
# ends with a 2-picture presentation LEAD — min..max spans 239 durations over
# 238 packets, which is exactly the shape that made the span method read 59.44.
awk 'BEGIN{ d=1001/60000; split("2 0 1", o, " ")
  for(g=0; g<79; g++){ b=g*3; for(k=1;k<=3;k++) printf "%.6f,%.6f\n", (b+o[k])*d, (b+k-1)*d }
  printf "%.6f,%.6f\n", 239*d, 237*d }' > "$WORK/pyr59.csv"
# shellcheck disable=SC2046  # word splitting is the point: "RATE TOTAL MISS SPANRATE METHOD"
set -- $(PF_PKT_FILE="$WORK/pyr59.csv" pf_coded_rate DUMMY)
prate="$1"; ptot="$2"; pspan="$4"; pmeth="$5"
numin "$prate" 59.90 59.99 && ok "pyramid window -> ${prate} AU/s (the true 59.94)" \
  || no "coded rate reads $prate on a true 59.94 pyramid"
numin "$pspan" 59.30 59.60 && ok "the legacy min/max-span method reads ${pspan} on the same window — the measured 59.44 bias" \
  || no "span-derived rate is $pspan; the fixture no longer reproduces the lead bias"
[ "$pmeth" = modal ] && ok "and the method is named on the output (method=$pmeth)" || no "rate method=$pmeth, want modal"
[ "${ptot:-0}" = 238 ] && ok "packet total unchanged as positional API ($ptot)" || no "positional API drifted: total=$ptot"
# the pair class must be unharmed: 240 packets, every 2nd untimestamped, ~60 AU/s
awk 'BEGIN{for(i=0;i<120;i++){printf "%.6f,%.6f\nN/A,N/A\n", i*0.033367, i*0.033367}}' > "$WORK/pair.csv"
# shellcheck disable=SC2046
set -- $(PF_PKT_FILE="$WORK/pair.csv" pf_coded_rate DUMMY)
{ numin "$1" 58 62 && [ "$2" = 240 ] && [ "$3" = 120 ]; } \
  && ok "pair-timestamped class still reads ~60 AU/s over 240 packets / 120 untimestamped ($1)" \
  || no "pair class regressed: rate=$1 total=$2 missing=$3"

echo
echo "== 6. one window, one number — and it is the LARGER one =="
# lib-paff.sh's 3000 and diagnose.sh's 5000 were two numbers for one idea. The
# first reconciliation took 3000, which SHRANK the window feeding a gate:
# diagnose step (3) produces ndup/nback and those arm the rot verdict, so the
# reconciliation quietly removed 2000 packets of evidence from a decision.
# Never reduce what a gate sees — reconcile UP.
[ "${PF_SCAN_WINDOW:-0}" = 5000 ] && ok "PF_SCAN_WINDOW is the single advisory-scan window, at the larger figure (5000)" \
  || no "PF_SCAN_WINDOW=${PF_SCAN_WINDOW:-unset}, want 5000 (never reconcile a gate's evidence downward)"
# and it really is one number: both scan sites read the variable
grep -q 'read_intervals "%+#\${PF_SCAN_WINDOW}"' "$SC/lib-paff.sh" \
  && ok "pf_reorder_scan reads the shared constant" || no "pf_reorder_scan no longer reads PF_SCAN_WINDOW"
grep -q 'read_intervals "%+#\${PF_SCAN_WINDOW}"' "$SC/diagnose.sh" \
  && ok "diagnose step (3) reads the shared constant" || no "diagnose step (3) no longer reads PF_SCAN_WINDOW"
src_d=$(cat "$SC/diagnose.sh"); src_p=$(cat "$SC/probe.sh")
hasnt "$src_d" '%+#5000' "diagnose.sh no longer hardcodes its own 5000-packet window"
has   "$src_d" 'PF_SCAN_WINDOW' "it reads the shared constant instead"
hasnt "$src_p" '5000-packet scan' "probe.sh's prose no longer quotes the retired 5000"
# the unrelated knob stays exactly where it was (scope lock)
case "$(cat "$SC/trim-to-idr.sh")" in
  *RTM_IDR_WINDOW*) ok "trim-to-idr.sh's RTM_IDR_WINDOW is untouched (a different knob entirely)";;
  *) no "RTM_IDR_WINDOW vanished from trim-to-idr.sh";;
esac

for f in late-sps.ts gap.ts m2v420.ts aac.ts; do
  [ -f "$FIX/$f" ] || no "fixture $f vanished during the run"
done
ok "sources untouched"

echo
echo "reorder-depth: $pass passed, $fail failed — depth/ppf/DTS-provenance shapes are injected (a real pair-timestamped field-coded capture is unmintable in a sandbox); the 59.44->59.94 and late-sps flood numbers are measured on this bench 2026-08-16, ffmpeg 9.0.1"
[ "$fail" -eq 0 ]

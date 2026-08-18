#!/usr/bin/env bash
# 65-junction-attest.sh — the 2026-08-18 pair: pairfill's displaced-timestamp
# JUNCTION MODEL (PP_MAXRUN==2 widening + census precondition + POC-lattice
# gate) and the attested builder-precondition override (lib-attest.sh
# precond_attest, wired into pairfill's pf-maxrun / pf-rate-map refusals and
# derive-dts's dd-depth-class refusal).
#
# SYNTHESIS LIMIT (house doctrine): a true PES-level junction — a 2-run of
# untimestamped packets whose timestamp rides the SECOND field of a pair —
# cannot be minted by libx264/mpegts in a sandbox (encoders/muxers stamp every
# packet). As with PAFF/discontinuities/transport loss elsewhere in this
# harness, the MECHANISM halves are pinned via the injection hooks:
#   (i)   the widened MAXRUN==2 branch triggers + announces on an injected
#         scan profile (PP_SCAN_FILE);
#   (ii)  the setts rule strings are exactly the documented shapes (grep pins;
#         the strict MAXRUN<=1 rule is pinned byte-identical);
#   (iii) the NEXT_PTS feature-detect refuses cleanly when this ffmpeg's setts
#         lacks it (on a 4.4 sandbox that IS the announced-refusal path; on a
#         capable ffmpeg the junction build runs end-to-end instead);
#   (iv)  the census parser is unit-pinned on canned trace_headers logs
#         (field/frame/pic_struct counts; bad pic_struct -> refusal, driven
#         through pairfill itself via PF_TRACE_FILE + PF_SETTS_OK);
#   (v)   the POC-lattice checker is unit-pinned on canned POC+PTS tables —
#         one on-lattice (pass) and one off-by-one-slot (fail).
# Attestation pins: refusal-names-the-route, wrong-string-still-refuses,
# exact-string-proceeds-with-sidecar, summary-line attested= append.
#
# Standalone: bash tests/regression.d/65-junction-attest.sh
# Exit 0 = all assertions pass; 1 = a regression; 2 = env failure.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
. "$SC/lib-paff.sh"

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
hasnt () { case "$1" in *"$2"*) no "$3 [unexpected: $2]";; *) ok "$3";; esac; }
ff () { ffmpeg -nostdin -y -v error "$@"; }

PF="$SC/pairfill-paff.sh"
ATT_MAXRUN="I attest: override pf-maxrun in pairfill-paff.sh; I have independent evidence the model is wrong for this file"
ATT_RATEMAP="I attest: override pf-rate-map in pairfill-paff.sh; I have independent evidence the model is wrong for this file"
ATT_DDCLASS="I attest: override dd-depth-class in derive-dts.sh; I have independent evidence the model is wrong for this file"

echo "== 1. static: every touched script parses =="
for s in pairfill-paff.sh lib-paff.sh lib-attest.sh derive-dts.sh; do
  bash -n "$SC/$s" && ok "bash -n $s" || no "$s does not parse"
done

echo
echo "== 2. the rules as shipped: strict byte-identical, junction exactly the documented shape =="
src=$(cat "$PF")
has "$src" 'SETTS="setts=pts=if(lt(PTS\,-8000000000000000000)\,PREV_OUTPTS+${A}\,PTS):dts=if(lt(PREV_OUTDTS\,-8000000000000000000)\,PTS-${PREROLL}\,PREV_OUTDTS+${A}+${AB}*mod(N\,2))"' \
  "strict MAXRUN<=1 rule byte-identical (the existing class pins hold)"
has "$src" 'if(lt(PTS\,-8000000000000000000)\,if(lt(PREV_INPTS\,-8000000000000000000)\,NEXT_PTS\,PREV_OUTPTS+${A})\,if(eq(PTS\,PREV_OUTPTS)\,PTS+${A}\,PTS))' \
  "junction pts rule: keep / first-of-pair +FIELD / NEXT_PTS / displaced +FIELD"
has "$src" 'dts=if(lt(DTS\,-8000000000000000000)\,if(lt(PREV_INDTS\,-8000000000000000000)\,NEXT_DTS\,PREV_OUTDTS+${A})\,if(eq(DTS\,PREV_OUTDTS)\,DTS+${A}\,DTS))' \
  "junction dts rule: same shape with DTS/PREV_INDTS/NEXT_DTS/PREV_OUTDTS"
hasnt "$src" 'PREV_OUTPTS+1800' "field interval comes from the per-file variable, never hardcoded"
# derive-dts: the attested= append is on the summary line (additive)
dsrc=$(cat "$SC/derive-dts.sh")
has "$dsrc" 'verdict=ok$DD_ATTESTED' "derive-dts summary line carries the attested= append"

echo
echo "== 3. census parser unit-pins (canned trace_headers logs, PF_TRACE_FILE) =="
# 6 pictures: 4 field (field_pic_flag 1), 1 frame by flag 0, 1 frame by ABSENT
# flag; non-first slices and pic_struct_present_flag lines must not miscount;
# pic_struct histogram 1x3 + 2x2 (all field structs, none bad).
cat > "$WORK/trace_good.log" <<'LOG'
[trace_headers @ 0x1] 157         pic_struct_present_flag                                     1 = 1
[trace_headers @ 0x1] 2           pic_struct                                                  1 = 1
[trace_headers @ 0x1] 8           first_mb_in_slice                                           1 = 0
[trace_headers @ 0x1] 12          field_pic_flag                                              1 = 1
[trace_headers @ 0x1] 2           pic_struct                                                  1 = 2
[trace_headers @ 0x1] 8           first_mb_in_slice                                           1 = 0
[trace_headers @ 0x1] 12          field_pic_flag                                              1 = 1
[trace_headers @ 0x1] 8           first_mb_in_slice                                         010 = 40
[trace_headers @ 0x1] 12          field_pic_flag                                              1 = 1
[trace_headers @ 0x1] 2           pic_struct                                                  1 = 1
[trace_headers @ 0x1] 8           first_mb_in_slice                                           1 = 0
[trace_headers @ 0x1] 12          field_pic_flag                                              1 = 1
[trace_headers @ 0x1] 2           pic_struct                                                  1 = 2
[trace_headers @ 0x1] 8           first_mb_in_slice                                           1 = 0
[trace_headers @ 0x1] 12          field_pic_flag                                              1 = 1
[trace_headers @ 0x1] 2           pic_struct                                                  1 = 1
[trace_headers @ 0x1] 8           first_mb_in_slice                                           1 = 0
[trace_headers @ 0x1] 12          field_pic_flag                                              1 = 0
[trace_headers @ 0x1] 8           first_mb_in_slice                                           1 = 0
LOG
eval "$(PF_TRACE_FILE="$WORK/trace_good.log" pf_trace_census DUMMY)"
[ "${PC_PICS:-0}" = 6 ] && ok "census: 6 coded pictures (first_mb_in_slice==0 only)" || no "census pics=$PC_PICS, want 6"
[ "${PC_FIELDS:-0}" = 4 ] && ok "census: 4 field pictures (non-first slices don't recount)" || no "census fields=$PC_FIELDS, want 4"
[ "${PC_FRAMES:-0}" = 2 ] && ok "census: 2 frame pictures (flag 0 AND flag absent both count)" || no "census frames=$PC_FRAMES, want 2"
[ "${PC_STRUCT_BAD:-9}" = 0 ] && ok "census: field structs 1/2 -> pic_struct_bad=0" || no "census bad=$PC_STRUCT_BAD, want 0"
has "${PC_STRUCT_HIST:-}" "1:3" "census histogram counts pic_struct 1 x3"
has "${PC_STRUCT_HIST:-}" "2:2" "census histogram counts pic_struct 2 x2"
[ "${PC_OK:-no}" = yes ] && ok "census: PC_OK=yes on a parseable log" || no "PC_OK=$PC_OK on good log"
# bad log: one frame-doubling pic_struct 7 -> counted bad
sed 's/1 = 2$/1 = 7/' "$WORK/trace_good.log" > "$WORK/trace_bad.log"
eval "$(PF_TRACE_FILE="$WORK/trace_bad.log" pf_trace_census DUMMY)"
[ "${PC_STRUCT_BAD:-0}" = 2 ] && ok "census: pic_struct 7 (doubling) counted bad (2 hits)" || no "census bad=$PC_STRUCT_BAD, want 2"
# empty log -> unusable, PC_OK=no
: > "$WORK/trace_empty.log"
eval "$(PF_TRACE_FILE="$WORK/trace_empty.log" pf_trace_census DUMMY)"
[ "${PC_OK:-yes}" = no ] && ok "census: zero pictures -> PC_OK=no (trace unusable)" || no "PC_OK=$PC_OK on empty log"

echo
echo "== 4. POC-lattice checker unit-pins (canned tables) =="
# two IDR sequences, B-field reorder in decode order, half=1800: all on-slot
cat > "$WORK/poc_on.csv" <<'CSV'
1,0,0
0,2,3600
0,1,1800
0,4,7200
0,3,5400
1,0,9000
0,2,12600
0,1,10800
CSV
eval "$(pf_poc_lattice "$WORK/poc_on.csv")"
{ [ "${PL_OFF:-9}" = 0 ] && [ "${PL_TOTAL:-0}" = 8 ] && [ "${PL_ON:-0}" = 8 ] && [ "${PL_SEQS:-0}" = 2 ]; } \
  && ok "on-lattice table -> 8/8 on-slot, 2 sequences, off=0" \
  || no "on-lattice miscount (on=$PL_ON total=$PL_TOTAL off=$PL_OFF seqs=$PL_SEQS)"
# one picture off by exactly one field slot -> off=1 (the failure the gate exists for)
sed 's/^0,3,5400$/0,3,7200/' "$WORK/poc_on.csv" > "$WORK/poc_off.csv"
eval "$(pf_poc_lattice "$WORK/poc_off.csv")"
{ [ "${PL_OFF:-0}" = 1 ] && [ "${PL_TOTAL:-0}" = 8 ]; } \
  && ok "off-by-one-slot table -> off=1 (FAIL evidence)" \
  || no "off-slot miscount (on=$PL_ON total=$PL_TOTAL off=$PL_OFF)"

echo
echo "== 5. fixtures + the injected junction scan profile =="
S="$WORK/src.ts"
ff -f lavfi -i testsrc2=s=160x120:r=25 -t 3 -c:v libx264 -g 25 -bf 2 -pix_fmt yuv420p -f mpegts "$S" || { echo "fixture mint failed"; exit 2; }
# one 2-run junction (displaced class) in an otherwise strictly-alternating scan
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
# a 3-run: past the widened model, refuses (attestation route)
cat > "$WORK/scan_run3.csv" <<'CSV'
0,0
N/A,N/A
N/A,N/A
N/A,N/A
3600,3600
7200,7200
CSV

echo
echo "== 6. widened branch: MAXRUN==2 announces the junction model; NEXT_PTS feature-detect decides =="
o=$(PP_SCAN_FILE="$WORK/scan_run2.csv" bash "$PF" "$S" "$WORK/j1.mov" --rate 50 2>&1); rc=$?
has "$o" "1 junction(s) with a 2-run of untimestamped packets — the displaced-timestamp class (measured 2026-08-18): widening the fill model; census required" \
  "MAXRUN==2 -> the junction model announces itself (with the 2-run count)"
hasnt "$o" "PRECONDITION FAIL" "MAXRUN==2 no longer refused outright"
if pf_setts_probe 'if(lt(PTS\,-8000000000000000000)\,NEXT_PTS\,PTS)'; then
  # capable ffmpeg: the junction model runs end-to-end on the (healthy) fixture —
  # the widened rule is an identity on fully-timestamped input, the census reads
  # the real file, and the POC-lattice gate judges the output.
  has "$o" "PP_CENSUS pics=" "capable ffmpeg: census machine line emitted"
  has "$o" "PP_POC_LATTICE on_slot=" "capable ffmpeg: POC-lattice machine line emitted"
  has "$o" " off=0" "capable ffmpeg: every picture on its slot (off=0)"
  { [ "$rc" -eq 0 ] && [ -f "$WORK/j1.mov" ]; } \
    && ok "capable ffmpeg: junction build blessed (rc=0)" \
    || no "capable ffmpeg: junction build rc=$rc"
else
  has "$o" "JUNCTION MODEL REFUSED" "this setts lacks NEXT_PTS -> announced refusal"
  has "$o" "NEXT_PTS" "the refusal names the missing setts variables"
  has "$o" "ffmpeg" "the refusal names the ffmpeg version requirement"
  [ "$rc" -eq 3 ] && ok "feature-detect refusal exits 3" || no "feature refusal rc=$rc, want 3"
  [ -f "$WORK/j1.mov" ] && no "feature refusal wrote an output" || ok "feature refusal writes nothing"
fi

echo
echo "== 7. census precondition through pairfill (hermetic: PF_SETTS_OK + PF_TRACE_FILE) =="
# bad pic_struct -> the junction model refuses with the histogram, exit 3
o=$(PP_SCAN_FILE="$WORK/scan_run2.csv" PF_SETTS_OK=yes PF_TRACE_FILE="$WORK/trace_bad.log" \
    bash "$PF" "$S" "$WORK/j2.mov" --rate 50 2>&1); rc=$?
{ [ "$rc" -eq 3 ] && case "$o" in *"JUNCTION MODEL REFUSED"*) true;; *) false;; esac; } \
  && ok "bad pic_struct census -> junction model refused, exit 3" || no "census refusal rc=$rc"
has "$o" "pic_struct" "the refusal names pic_struct"
has "$o" "histogram" "the refusal prints the histogram"
[ -f "$WORK/j2.mov" ] && no "census refusal wrote an output" || ok "census refusal writes nothing"
# clean census -> announced counts + PP_CENSUS machine line, then the build
# proceeds (on ffmpeg without the real setts vars the mux itself then fails —
# rc 1, not a refusal; on a capable ffmpeg the histogram gate judges the
# injected-census mismatch — also 1; either way the census PASSED and said so)
o=$(PP_SCAN_FILE="$WORK/scan_run2.csv" PF_SETTS_OK=yes PF_TRACE_FILE="$WORK/trace_good.log" \
    bash "$PF" "$S" "$WORK/j3.mov" --rate 50 2>&1); rc=$?
has "$o" "PP_CENSUS pics=6 fields=4 frames=2 pic_struct_bad=0" "clean census -> PP_CENSUS machine line (exact counts)"
[ "$rc" -ne 3 ] && ok "clean census is not a refusal (rc=$rc)" || no "clean census still refused"

echo
echo "== 8. attested override: pf-maxrun (run of 3) =="
o=$(PP_SCAN_FILE="$WORK/scan_run3.csv" bash "$PF" "$S" "$WORK/a1.mov" --rate 50 2>&1); rc=$?
{ [ "$rc" -eq 3 ] && case "$o" in *"PRECONDITION FAIL: 3 consecutive"*) true;; *) false;; esac; } \
  && ok "MAXRUN=3 without attestation -> refused, exit 3 (unchanged verdict)" || no "3-run refusal rc=$rc"
has "$o" "Operator override (recorded" "the refusal names the attestation route"
has "$o" "$ATT_MAXRUN" "the refusal prints the exact string"
[ -f "$WORK/a1.mov.precond-waiver.txt" ] && no "refusal wrote a sidecar" || ok "no sidecar without the string"
# wrong string (near-miss) still refuses, writes nothing
o=$(PP_SCAN_FILE="$WORK/scan_run3.csv" RTM_PRECOND_ATTEST="${ATT_MAXRUN% file}" \
    bash "$PF" "$S" "$WORK/a1.mov" --rate 50 2>&1); rc=$?
{ [ "$rc" -eq 3 ] && [ ! -f "$WORK/a1.mov.precond-waiver.txt" ]; } \
  && ok "near-miss attestation -> still refused, no sidecar" || no "near-miss accepted (rc=$rc)"
# exact string: announced, sidecar with the measured values, junction model armed
o=$(PP_SCAN_FILE="$WORK/scan_run3.csv" PF_SETTS_OK=yes PF_TRACE_FILE="$WORK/trace_good.log" \
    RTM_PRECOND_ATTEST="$ATT_MAXRUN" bash "$PF" "$S" "$WORK/a1.mov" --rate 50 2>&1); rc=$?
has "$o" "PRECONDITION OVERRIDE ATTESTED: gate pf-maxrun" "exact string -> loud announcement"
has "$o" "RTM_PRECOND_WAIVER gate=pf-maxrun script=pairfill-paff.sh" "machine line emitted"
[ "$rc" -ne 3 ] && ok "attested run proceeds past the precondition (rc=$rc, not 3)" || no "attested run still refused"
has "$o" "attested=pf-maxrun" "PP_CENSUS summary line gains attested=pf-maxrun (additive)"
if [ -f "$WORK/a1.mov.precond-waiver.txt" ]; then
  sc=$(cat "$WORK/a1.mov.precond-waiver.txt")
  ok "sidecar written: a1.mov.precond-waiver.txt"
  has "$sc" "gate: pf-maxrun" "sidecar records the gate"
  has "$sc" "script: pairfill-paff.sh" "sidecar records the script"
  has "$sc" "PP_MAXRUN=3" "sidecar records the measured values that would have refused"
  has "$sc" "$ATT_MAXRUN" "sidecar records the verbatim operator string"
else
  no "attested run wrote no sidecar"
fi

echo
echo "== 9. attested override: pf-rate-map (unmappable field rate) =="
o=$(bash "$PF" "$S" "$WORK/r1.mov" 2>&1); rc=$?
[ "$rc" -eq 3 ] && ok "unmappable rate without attestation -> exit 3 (unchanged)" || no "rate refusal rc=$rc"
has "$o" "cannot map a field rate" "refusal text unchanged"
has "$o" "$ATT_RATEMAP" "rate-map refusal names the exact attestation string"
o=$(RTM_PRECOND_ATTEST="$ATT_RATEMAP" bash "$PF" "$S" "$WORK/r1.mov" 2>&1); rc=$?
has "$o" "attested rate-map override" "attested -> announced fallback to the measured rate"
has "$o" "RTM_PRECOND_WAIVER gate=pf-rate-map" "machine line emitted"
[ "$rc" -ne 3 ] && ok "attested rate-map run proceeds (rc=$rc, not 3)" || no "attested rate-map still refused"
{ [ -f "$WORK/r1.mov.precond-waiver.txt" ] && grep -q 'gate: pf-rate-map' "$WORK/r1.mov.precond-waiver.txt"; } \
  && ok "rate-map sidecar written with the gate name" || no "rate-map sidecar missing/wrong"

echo
echo "== 10. attested override: dd-depth-class (derive-dts, the sidecar-recorded --force) =="
# the 63-suite technique: a correct-SPS (match-frame) reordered MKV + a venv
# shim, so the depth-class gate is reachable hermetically
MKV="$WORK/reord.mkv"
ff -f lavfi -i testsrc2=s=160x120:r=25 -t 2 -c:v libx264 -g 25 -bf 8 \
   -x264opts b-pyramid=normal:b-adapt=0 -pix_fmt yuv420p "$MKV" || { echo "MKV mint failed"; exit 2; }
mkdir -p "$WORK/shimdata/venv/bin"
cat > "$WORK/shimdata/venv/bin/python" <<SH
#!/bin/sh
case "\$*" in *"import av"*) echo 0.0-shim; exit 0;; esac
exec "$(command -v python3)" "\$@"
SH
chmod +x "$WORK/shimdata/venv/bin/python"
o=$(CLAUDE_PLUGIN_DATA="$WORK/shimdata" bash "$SC/derive-dts.sh" "$MKV" "$WORK/d1.mov" 2>&1); rc=$?
[ "$rc" -eq 3 ] && ok "match-frame without --force/attestation -> exit 3 (unchanged)" || no "depth refusal rc=$rc"
has "$o" "--force" "refusal still names --force (kept)"
has "$o" "$ATT_DDCLASS" "refusal names the exact dd-depth-class attestation string"
o=$(CLAUDE_PLUGIN_DATA="$WORK/shimdata" RTM_PRECOND_ATTEST="${ATT_DDCLASS% file}" \
    bash "$SC/derive-dts.sh" "$MKV" "$WORK/d1.mov" 2>&1); rc=$?
{ [ "$rc" -eq 3 ] && [ ! -f "$WORK/d1.mov.precond-waiver.txt" ]; } \
  && ok "near-miss dd attestation -> still refused, no sidecar" || no "dd near-miss accepted (rc=$rc)"
o=$(CLAUDE_PLUGIN_DATA="$WORK/shimdata" RTM_PRECOND_ATTEST="$ATT_DDCLASS" \
    bash "$SC/derive-dts.sh" "$MKV" "$WORK/d1.mov" 2>&1); rc=$?
has "$o" "PRECONDITION OVERRIDE ATTESTED: gate dd-depth-class" "exact string -> announced"
has "$o" "RTM_PRECOND_WAIVER gate=dd-depth-class script=derive-dts.sh" "machine line emitted"
[ "$rc" -ne 3 ] && ok "attested derive proceeds past the gate (rc=$rc, not 3)" || no "attested derive still refused"
{ [ -f "$WORK/d1.mov.precond-waiver.txt" ] && grep -q 'PF_DEPTH_CLASS=' "$WORK/d1.mov.precond-waiver.txt"; } \
  && ok "dd sidecar written with the measured class" || no "dd sidecar missing/wrong"
if python3 -c 'import av' 2>/dev/null; then
  # the shim execs the system python3, which has av: the attested run goes all
  # the way through the output gates and the summary line carries attested=
  dline=$(printf '%s\n' "$o" | grep '^DERIVE_DTS ' | head -1)
  case "$dline" in
    *"verdict=ok attested=dd-depth-class") ok "DERIVE_DTS summary line gains attested=dd-depth-class";;
    *) no "DERIVE_DTS attested line wrong: '$dline'";;
  esac
  { [ "$rc" -eq 0 ] && [ -f "$WORK/d1.mov" ]; } && ok "attested derive blessed by its own gates (rc=0)" \
    || no "attested derive end-to-end rc=$rc"
else
  echo "  (SKIP: python3 cannot import av — the attested= append on a BLESSED run is"
  echo "   grep-pinned in section 2; the gate/announce/sidecar mechanics ran above.)"
fi

echo
echo "== 11. legacy pins: the MAXRUN<=1 class is untouched =="
M2="$WORK/m2.ts"; ff -f lavfi -i testsrc2=s=160x120:r=25 -t 2 -c:v mpeg2video -pix_fmt yuv420p -f mpegts "$M2"
o=$(bash "$PF" "$M2" "$WORK/l1.mov" 2>&1); rc=$?
{ [ "$rc" -eq 3 ] && case "$o" in *"not H.264"*) true;; *) false;; esac; } \
  && ok "pairfill: non-H.264 -> exit 3 (existing pin holds)" || no "non-H.264 rc=$rc"
# strict alternation profile (MAXRUN=1) never announces the junction model
cat > "$WORK/scan_strict.csv" <<'CSV'
0,0
N/A,N/A
3600,3600
N/A,N/A
7200,7200
N/A,N/A
CSV
o=$(PP_SCAN_FILE="$WORK/scan_strict.csv" bash "$PF" "$S" "$WORK/l2.mov" --rate 50 2>&1); rc=$?
hasnt "$o" "junction" "MAXRUN<=1 -> no junction announcement (strict path untouched)"
hasnt "$o" "PP_CENSUS" "MAXRUN<=1 -> no census run (zero behavior change)"

echo
echo "junction-attest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

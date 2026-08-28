#!/usr/bin/env bash
# 90-harness-honesty.sh — WO-1.15.8 / CHECKUP-2026-08-27 Class E: what the
# suite structurally could not see.
#
# Measured pre-round: a non-exec sub-suite stub and even a DELETED
# regression.d/ both yielded "PASSED: 0 FAILED: 0" exit 0 (E1); a stub whose
# last command succeeds while its own tail says "1 failed" counted PASS (E2);
# eight capability gates skip whole lanes silently green (E3); test 14's
# hand-kept roster was 8 entry points behind its own "every entry point"
# promise (E7). Plus the closures this round makes tractable: the in-situ
# POC UNPROVEN count arm (E6 — testable since 1.15.5's census side files),
# the vacuous --signaling gate (E4 — a lossless h264_metadata VUI rewrite
# drifts ONLY the signaling, so every other gate passes while this one must
# catch it), and the 5.2 debt (rewrap_nudges/rewrap_hard_confessions unit
# tables).
#
# Standalone: bash tests/regression.d/90-harness-honesty.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
t_ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
t_no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
t_has () { case "$1" in *"$2"*) t_ok "$3";; *) t_no "$3 [missing: $2]";; esac; }
t_hasnt () { case "$1" in *"$2"*) t_no "$3 [unexpected: $2]";; *) t_ok "$3";; esac; }
ff () { ffmpeg -nostdin -y -v error "$@"; }

echo "== 1. lib-harness.sh: the runner counts what it used to swallow =="
if [ ! -f "$TESTS/lib-harness.sh" ]; then
  t_no "tests/lib-harness.sh does not exist (the runner loop is not factored/testable)"
else
  # shellcheck source=/dev/null
  . "$TESTS/lib-harness.sh"
  STUB="$WORK/stub.d"; mkdir -p "$STUB"
  cat > "$STUB/10-green.sh"  <<'S'
echo "detail line"
echo "green: 2 passed, 0 failed"
exit 0
S
  cat > "$STUB/20-red.sh"    <<'S'
echo "red: 1 passed, 1 failed"
exit 1
S
  cat > "$STUB/30-breach.sh" <<'S'
echo "breach: 3 passed, 1 failed"
exit 0
S
  cat > "$STUB/40-notail.sh" <<'S'
echo "all good here"
exit 0
S
  cat > "$STUB/50-noexec.sh" <<'S'
echo "noexec: 1 passed, 0 failed"
exit 0
S
  cat > "$STUB/60-skips.sh"  <<'S'
echo "  (SKIP: lane dormant on this bench)"
echo "skips: 1 passed, 0 failed"
exit 0
S
  chmod 755 "$STUB"/*.sh; chmod 644 "$STUB/50-noexec.sh"
  MOK=""; MNO=""
  ok () { MOK="$MOK
OK: $1"; }
  no () { MNO="$MNO
NO: $1"; }
  # plain redirection, NOT $( ) — a command substitution would run the
  # function in a subshell and the recorders/HARNESS_SKIPS would be lost
  run_subsuites "$STUB" > "$WORK/hout.txt" 2>&1
  hout=$(cat "$WORK/hout.txt")
  t_has "$MOK" "10-green.sh" "green case counts PASS"
  t_has "$MNO" "20-red.sh" "red case counts FAIL"
  t_has "$MNO" "30-breach.sh" "E2: green exit + '1 failed' tail is a convention-breach FAIL"
  t_has "$MNO" "40-notail.sh" "E2: green exit with NO recognizable tail is a FAIL too"
  t_has "$MOK" "50-noexec.sh" "E1: a non-executable case is ENROLLED anyway (the bit cannot un-enroll)"
  t_has "$hout" "not executable" "…and the mode drift is announced"
  t_has "$MOK" "60-skips.sh" "a skip-announcing green case stays green"
  [ "${HARNESS_SKIPS:-0}" -ge 1 ] && t_ok "E3: the skip announcement was COUNTED (HARNESS_SKIPS=$HARNESS_SKIPS)" \
    || t_no "E3: HARNESS_SKIPS=$HARNESS_SKIPS, want >=1"
  MOK=""; MNO=""
  mkdir -p "$WORK/empty.d"
  run_subsuites "$WORK/empty.d" >/dev/null 2>&1
  t_has "$MNO" "empty" "E1: an empty/deleted sub-suite dir is a suite FAILURE, never 0/0 green"
  unset -f ok no
fi

echo
echo "== 2. regression.sh is wired through the factored runner =="
rsrc=$(cat "$TESTS/regression.sh")
t_has "$rsrc" "lib-harness.sh" "regression.sh sources the factored runner"
t_has "$rsrc" "run_subsuites" "…and calls it"
t_has "$rsrc" "HARNESS_SKIPS" "…and surfaces the skip tally in the final banner (E3)"

echo
echo "== 3. E7: test 14 derives its roster from the tree =="
esrc=$(sed 's/#.*//' "$HERE/14-exit-codes.sh")   # comment-stripped: this file
# DISCUSSES the retired hand-kept roster in its own header, and an un-stripped
# read would be satisfied (or tripped) by the prose rather than the code.
t_hasnt "$esrc" 'ENTRY="auto batch derive-dts' "the hand-kept roster string is gone"
t_has "$esrc" 'lib-*)' "the roster is derived from scripts/*.sh minus lib-*"
for e in clean clock dim-scan lead-check mp4-swap surgical-cut verify-source zero-base; do
  ls "$SC/$e.sh" >/dev/null 2>&1 || t_no "roster sanity: $e.sh missing from scripts/"
done
t_ok "the eight 1.15-era entry points exist for the derived roster to pick up"

echo
echo "== 4. E6: the in-situ POC count-arm UNPROVEN branch, end-to-end =="
. "$SC/lib-probe.sh"; . "$SC/lib-paff.sh"
if pf_setts_probe 'if(lt(PTS\,-8000000000000000000)\,NEXT_PTS\,PTS)'; then
  S75="$WORK/s75.ts"
  ff -f lavfi -i testsrc2=r=25:s=320x240:d=3 -c:v libx264 -bf 3 -g 25 -pix_fmt yuv420p -f mpegts "$S75" \
    || { echo "mint failed"; exit 2; }
  # canned census: 75 pictures (so the junction histogram gate PASSES against
  # the written 75 pair-durations) but only 70 carry pic_order_cnt_lsb — the
  # census side table comes up short and the COUNT guard must trip.
  awk 'BEGIN{ for(i=0;i<75;i++){
        printf "[trace_headers @ 0x1] 7           nal_unit_type                                           00001 = %d\n", (i==0?5:1)
        print  "[trace_headers @ 0x1] 8           first_mb_in_slice                                           1 = 0"
        if(i<70) printf "[trace_headers @ 0x1] 5           pic_order_cnt_lsb                                  0000000000 = %d\n", (2*i)%256 } }' \
    > "$WORK/census75.log"
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
  o=$(PP_SCAN_FILE="$WORK/scan_run2.csv" PF_TRACE_FILE="$WORK/census75.log" \
      bash "$SC/pairfill-paff.sh" "$S75" "$WORK/e6.mov" --rate 50 2>&1); rc=$?
  t_has "$o" "consequence: the POC gate's count guard WILL trip" "the census announces the foregone ceiling pre-mux"
  [ "$rc" -eq 1 ] && t_ok "in-situ UNPROVEN keeps exit 1 (a bless decision is at stake)" || t_no "E6 run rc=$rc, want 1"
  t_has "$o" ">> POC-LATTICE GATE UNPROVEN" "the count arm reaches the in-situ UNPROVEN branch"
  t_has "$o" "PP_POC_LATTICE unproven=1 why=count rows=70 packets=75" "machine row: why=count with the real counts"
  t_has "$o" "re-judge: scripts/poc-gate.sh" "retention names the re-judge route"
  ls "$WORK"/e6.part* >/dev/null 2>&1 && t_ok ".part kept for the closer look" || t_no "no .part kept"
else
  echo "  (SKIP: this setts lacks NEXT_PTS — the junction build cannot run; the count"
  echo "   guard's arithmetic is pinned by tests 77-79's shared machinery.)"
fi

echo
echo "== 5. E4: --signaling sees real color tags, both directions =="
# setparams is the reliable mint: bare -color_primaries/-color_trc encoder
# flags only landed the matrix on this bench (measured — space=bt709,
# primaries/trc=unknown); the filter stamps all three into the VUI.
C709="$WORK/c709.ts"
ff -f lavfi -i "testsrc2=s=320x240:r=25,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709" \
   -t 2 -c:v libx264 -g 25 -pix_fmt yuv420p -f mpegts "$C709" || { echo "mint failed"; exit 2; }
p709=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_primaries -of default=nw=1:nk=1 "$C709" | head -1)
if [ "$p709" != bt709 ]; then
  echo "  (SKIP: this encoder did not write the bt709 VUI tag (got '$p709') — the"
  echo "   signaling fixtures are not mintable on this bench.)"
else
  ff -i "$C709" -map 0:v:0 -c copy "$WORK/ok709.mov"
  o=$(bash "$SC/verify.sh" "$C709" "$WORK/ok709.mov" --signaling 2>&1) || true
  t_has "$o" "color_primaries=bt709 (preserved)" "preserved direction is NON-VACUOUS (a real tag value, not unknown==unknown)"
  t_has "$o" "signaling: no drift" "…and reads no-drift"
  # the drift rides mpegts, NOT mov: the MOV muxer writes a colr atom from the
  # INPUT's codec parameters (bt709) which masks the rewritten SPS in ffprobe's
  # view (measured this session) — mpegts has no colr, so the probe reads the
  # SPS and the drift is visible, while every byte-level gate still passes.
  ff -i "$C709" -map 0:v:0 -c copy \
     -bsf:v 'h264_metadata=colour_primaries=9:transfer_characteristics=16:matrix_coefficients=9' \
     -f mpegts "$WORK/drift.ts"
  o=$(bash "$SC/verify.sh" "$C709" "$WORK/drift.ts" --signaling 2>&1) || true
  t_has "$o" "(DRIFT)" "a lossless VUI rewrite (bt709 -> bt2020/PQ) is caught as DRIFT"
  t_has "$o" "Signaling/caption drift" "…and lands in the verdict note"
  t_hasnt "$o" ">> OK" "the drifted output is never an OK (the E4 mutation cannot stay green)"
fi

echo
echo "== 6. E8 / 5.2 debt: rewrap_nudges + rewrap_hard_confessions unit tables =="
. "$SC/lib-rewrap.sh" 2>/dev/null || true
if command -v rewrap_nudges >/dev/null 2>&1 || type rewrap_nudges >/dev/null 2>&1; then
  cat > "$WORK/mux1.log" <<'LOG'
[mpegts @ 0x1] Application provided invalid, non-monotonic dts to muxer in stream 0
[mpegts @ 0x1] Application provided invalid, non-monotonic dts to muxer in stream 0
[mpegts @ 0x1] Application provided invalid, non-monotonic dts to muxer in stream 1
[mov @ 0x2] pts has no value
[mov @ 0x2] Timestamps are unset in a packet
frame counting line, unrelated
LOG
  [ "$(rewrap_nudges "$WORK/mux1.log")" = 3 ] && t_ok "nudge counter: 3 equal-DTS nudges counted" \
    || t_no "rewrap_nudges: $(rewrap_nudges "$WORK/mux1.log"), want 3"
  [ "$(rewrap_hard_confessions "$WORK/mux1.log")" = 2 ] && t_ok "hard-confession counter: 2 invented-timing lines counted" \
    || t_no "rewrap_hard_confessions: $(rewrap_hard_confessions "$WORK/mux1.log"), want 2"
  printf '[mpegts @ 0x1] Application provided invalid, non-monotonic dts to muxer in stream 0\n' > "$WORK/mux2.log"
  { [ "$(rewrap_nudges "$WORK/mux2.log")" = 1 ] && [ "$(rewrap_hard_confessions "$WORK/mux2.log")" = 0 ]; } \
    && t_ok "discrimination: a +1-tick nudge is NEVER a hard confession" \
    || t_no "nudge counted as confession (n=$(rewrap_nudges "$WORK/mux2.log") h=$(rewrap_hard_confessions "$WORK/mux2.log"))"
  printf '[mov @ 0x2] pts has no value\n' > "$WORK/mux3.log"
  { [ "$(rewrap_nudges "$WORK/mux3.log")" = 0 ] && [ "$(rewrap_hard_confessions "$WORK/mux3.log")" = 1 ]; } \
    && t_ok "discrimination: a hard confession is NEVER a nudge" \
    || t_no "confession counted as nudge"
  : > "$WORK/mux4.log"
  { [ "$(rewrap_nudges "$WORK/mux4.log")" = 0 ] && [ "$(rewrap_hard_confessions "$WORK/mux4.log")" = 0 ]; } \
    && t_ok "empty log: 0/0 (no phantom counts)" || t_no "phantom counts on an empty log"
else
  t_no "lib-rewrap.sh functions not sourceable"
fi

echo
echo "harness-honesty: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

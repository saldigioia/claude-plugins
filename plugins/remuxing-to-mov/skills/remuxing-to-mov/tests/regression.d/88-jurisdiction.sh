#!/usr/bin/env bash
# 88-jurisdiction.sh — WO-1.15.7 / CHECKUP-2026-08-27 rule 5: a scanner states
# its jurisdiction (B1, B2, B4, F1, F12) instead of printing an unscoped CLEAN.
#
# The measured defects: B1 an MP2-only TS scanned stream 0 as "video" and read
# CLEAN, then clean.sh routed a zero-base build that could only die at
# verify-source's "no video stream" — a full build to a foregone refusal;
# B2 a .vob with 4000 random bytes mid-file read ">> CLEAN: no transport loss"
# (program streams carry no continuity counters — the vocabulary is mpegts');
# B4 a mid-capture 33-bit crossing surfaces on this ffmpeg as an ALREADY-
# UNWRAPPED timeline (negative start_time), which nothing checked — the wrap
# counter guards a representation the demuxer no longer hands it; F1
# zero-base refused ALL PAFF with the pair-timestamped diagnosis and a
# pairfill route that exits 3 on a fully-timestamped file; F12 probe.sh's
# --kv/--json exited before the multi-program advisory, so clean.sh printed a
# "ready to run" zero-base command that refuses exit 2.
#
# Standalone: bash tests/regression.d/88-jurisdiction.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }

. "$TESTS/lib-harness.sh"   # grepq/grepqe + rtm_strip_comments: one definition (tests/lib-harness.sh)
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
hasnt () { case "$1" in *"$2"*) no "$3 [unexpected: $2]";; *) ok "$3";; esac; }
ff () { ffmpeg -nostdin -y -v error "$@"; }
kvget () { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

echo "== 0. fixtures =="
AUD="$WORK/audonly.ts"
ff -f lavfi -i sine=1000 -t 5 -c:a mp2 -f mpegts "$AUD" || { echo "mint failed"; exit 2; }
VOB="$WORK/x.vob"
ff -f lavfi -i testsrc2=s=320x240:r=25 -t 4 -c:v mpeg2video -pix_fmt yuv420p -f vob "$VOB" || { echo "mint failed"; exit 2; }
vsz=$(wc -c < "$VOB" | tr -d ' ')
dd if=/dev/urandom of="$VOB" bs=1 seek=$((vsz / 2)) count=4000 conv=notrunc 2>/dev/null
TS="$WORK/ctrl.ts"
ff -f lavfi -i testsrc2=s=320x240:r=25 -t 4 -c:v mpeg2video -pix_fmt yuv420p -f mpegts "$TS" || { echo "mint failed"; exit 2; }

echo
echo "== 1. B1: audio-only source — the video half has NO jurisdiction =="
o=$(bash "$SC/ts-health.sh" "$AUD" 2>&1); rc=$?
[ "$rc" -eq 10 ] && ok "audio-only TS is FINDINGS (rc=10), never an unscoped CLEAN" \
  || no "audio-only ts-health rc=$rc, want 10 (pre-round measured: CLEAN rc=0)"
hasnt "$o" ">> CLEAN" "no CLEAN verdict on a source the video gates never judged"
has "$o" "no video stream" "the scope finding names the missing jurisdiction"
kv=$(bash "$SC/ts-health.sh" "$AUD" --kv 2>&1)
[ "$(kvget "$kv" TSH_VIDEO)" = none ] && ok "--kv carries TSH_VIDEO=none (additive)" \
  || no "TSH_VIDEO=$(kvget "$kv" TSH_VIDEO), want none"
[ "$(kvget "$kv" TSH_VPKTS)" = 0 ] && ok "no audio packets counted as 'video packets' (pre-round: 1532)" \
  || no "TSH_VPKTS=$(kvget "$kv" TSH_VPKTS) on an audio-only source, want 0"
hasnt "$o" "single-GOP" "no bogus single-GOP finding from zero keyframes on no video"
# the control still reads CLEAN with TSH_VIDEO=yes
kv=$(bash "$SC/ts-health.sh" "$TS" --kv 2>&1)
[ "$(kvget "$kv" TSH_VIDEO)" = yes ] && ok "control: TSH_VIDEO=yes" || no "control TSH_VIDEO=$(kvget "$kv" TSH_VIDEO)"

echo
echo "== 2. B1: zero-base refuses an audio-only source at PRE-FLIGHT, not after the build =="
o=$(bash "$SC/zero-base.sh" "$AUD" "$WORK/zb.ts" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "audio-only zero-base -> exit 2 pre-flight" \
  || no "audio-only zero-base rc=$rc, want 2 (pre-round: full build, then verify-source refusal)"
has "$o" "no video stream" "the refusal names the reason"
if ls "$WORK"/zb* >/dev/null 2>&1; then no "refused zero-base wrote something"; else ok "nothing written (never build to a foregone refusal — the Item-C rule)"; fi

echo
echo "== 3. B1: clean.sh does not route a doomed zero-base on an audio-only source =="
o=$(bash "$SC/clean.sh" "$AUD" 2>&1) || true
hasnt "$o" "TIER 1 (structural): scripts/zero-base.sh" "no 'ready to run' zero-base route without video"
has "$o" "no video" "the clinic names the jurisdiction gap instead"

echo
echo "== 4. B2: program streams — the transport verdict states its vocabulary =="
o=$(bash "$SC/ts-health.sh" "$VOB" 2>&1) || true
has "$o" "no transport-counter vocabulary" "the .vob verdict is SCOPED (PS carries no continuity counters)"
has "$o" "demux" "the scope names the evidence class (demux-only)"
kv=$(bash "$SC/ts-health.sh" "$VOB" --kv 2>&1) || true
[ "$(kvget "$kv" TSH_SCOPE)" = demux-only ] && ok "--kv carries TSH_SCOPE=demux-only" \
  || no "TSH_SCOPE=$(kvget "$kv" TSH_SCOPE), want demux-only"
o=$(bash "$SC/ts-health.sh" "$TS" 2>&1); rc=$?
hasnt "$o" "no transport-counter vocabulary" "mpegts keeps its full-vocabulary verdict unscoped"
kv=$(bash "$SC/ts-health.sh" "$TS" --kv 2>&1)
[ "$(kvget "$kv" TSH_SCOPE)" = mpegts ] && ok "--kv carries TSH_SCOPE=mpegts on the control" \
  || no "control TSH_SCOPE=$(kvget "$kv" TSH_SCOPE), want mpegts"

echo
echo "== 5. B4: the unwrapped-wrap symptom (negative start_time) is a named finding =="
WRAP="$WORK/wrap.ts"
ff -i "$TS" -c copy -copyts -output_ts_offset 95435 -muxdelay 0 -f mpegts "$WRAP" 2>/dev/null || true
wst=$(ffprobe -v error -show_entries format=start_time -of default=nw=1:nk=1 "$WRAP" 2>/dev/null | head -1)
if [ -f "$WRAP" ] && awk "BEGIN{exit !((${wst:-0}) < -0.05)}" 2>/dev/null; then
  o=$(bash "$SC/ts-health.sh" "$WRAP" 2>&1); rc=$?
  has "$o" "negative start_time" "the finding names the symptom this demuxer actually hands back"
  has "$o" "unwrapped" "…and explains the representation (demuxer already unwrapped the crossing)"
  [ "$rc" -eq 10 ] && ok "negative start is FINDINGS (rc=10), not CLEAN" || no "wrap.ts rc=$rc, want 10"
  kv=$(bash "$SC/ts-health.sh" "$WRAP" --kv 2>&1)
  st_kv=$(kvget "$kv" TSH_START)
  awk "BEGIN{exit !((${st_kv:-0}) < -0.05)}" 2>/dev/null && ok "--kv carries TSH_START ($st_kv, additive)" \
    || no "TSH_START=$st_kv, want the measured negative start"
  o=$(bash "$SC/clean.sh" "$WRAP" 2>&1) || true
  has "$o" "negative" "clean.sh names the negative-start finding (pre-round: positive direction only)"
else
  echo "  (SKIP: this ffmpeg's demuxer did not produce a negative start_time from the"
  echo "   minted 33-bit crossing (start=$wst) — the B4 symptom is demuxer-version-"
  echo "   dependent; the negative-start finding is pinned only where mintable.)"
fi

echo
echo "== 6. F1: zero-base's PAFF refusal diagnoses the FULL-TS shape honestly =="
# pf_detect injection: full timestamps at 2x the container's nominal rate ->
# paff=yes half_ts=no (measured 2026-08-27; the F1 misdiagnosis shape)
S2="$WORK/s2997.ts"
ff -f lavfi -i testsrc2=s=320x240:r=30000/1001 -f lavfi -i sine=1000 -t 3 \
   -c:v libx264 -g 30 -pix_fmt yuv420p -c:a mp2 -f mpegts "$S2" || { echo "mint failed"; exit 2; }
awk 'BEGIN{for(i=0;i<180;i++){t=i*0.016683; printf "%.6f,%.6f\n", t, t}}' > "$WORK/full2x.csv"
o=$(PF_PKT_FILE="$WORK/full2x.csv" bash "$SC/zero-base.sh" "$S2" "$WORK/zb2.ts" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "full-TS PAFF still refused (exit 2 — the POLICY stands)" || no "full-TS PAFF rc=$rc, want 2"
hasnt "$o" "untimestamped mates" "no false 'untimestamped mates' diagnosis on a complete timestamp column"
hasnt "$o" "pair-timestamped PAFF source" "not labeled the pair-timestamped class"
has "$o" "half_ts=no" "the refusal states the measured profile"
has "$o" "pairfill-paff.sh would refuse" "…and says the OLD route would exit 3 on this very file"
has "$o" "mov.sh" "…and names a route that actually accepts the file (the copy ladder)"
# the pair-timestamped arm keeps its 1.15.2 message verbatim (test 75's pins)
awk 'BEGIN{for(i=0;i<120;i++){printf "%.6f,%.6f\nN/A,N/A\n", i*0.033367, i*0.033367}}' > "$WORK/pair.csv"
o=$(PF_PKT_FILE="$WORK/pair.csv" bash "$SC/zero-base.sh" "$S2" "$WORK/zb3.ts" 2>&1); rc=$?
{ [ "$rc" -eq 2 ] && case "$o" in *"pair-timestamped PAFF source"*) true;; *) false;; esac; } \
  && ok "half_ts arm unchanged (pair-timestamped message, exit 2)" || no "half_ts arm regressed (rc=$rc)"

echo
echo "== 7. F12: multi-program topology reaches the machine consumers =="
P2="$WORK/prog2.ts"
ff -f lavfi -i testsrc2=s=160x120:r=25 -f lavfi -i sine=1000 \
   -f lavfi -i testsrc2=s=160x120:r=25 -f lavfi -i sine=500 -t 2 \
   -map 0:v -map 1:a -map 2:v -map 3:a -c:v mpeg2video -pix_fmt yuv420p -c:a mp2 \
   -program title=P1:program_num=1:st=0:st=1 -program title=P2:program_num=2:st=2:st=3 \
   -f mpegts "$P2" || { echo "2-program mint failed"; exit 2; }
kv=$(bash "$SC/probe.sh" "$P2" --kv 2>&1)
[ "$(kvget "$kv" PR_NPROG)" = 2 ] && ok "--kv carries PR_NPROG=2 (pre-round: the advisory was human-mode-only)" \
  || no "PR_NPROG=$(kvget "$kv" PR_NPROG), want 2"
kv=$(bash "$SC/probe.sh" "$TS" --kv 2>&1)
[ "$(kvget "$kv" PR_NPROG)" = 1 ] && ok "single-program control: PR_NPROG=1" \
  || no "control PR_NPROG=$(kvget "$kv" PR_NPROG), want 1"
j=$(bash "$SC/probe.sh" "$P2" --json 2>&1)
has "$j" '"nprog":2' "--json carries nprog too (append-only API)"
o=$(bash "$SC/clean.sh" "$P2" 2>&1) || true
hasnt "$o" "TIER 1 (structural): scripts/zero-base.sh \"$P2\"" \
  "clean.sh no longer prints a ready-to-run zero-base that would refuse exit 2"
has "$o" "program" "the clinic names the multi-program topology instead"

echo
echo "== 8. A3 sweep: every entry point pins the C locale (directly or via lib-probe) =="
a3_bad=""
for s in "$SC"/*.sh; do
  b=$(basename "$s")
  case "$b" in lib-*) continue;; esac
  # the pin must be SOURCED, not mentioned: a comment naming lib-probe.sh used
  # to satisfy this (measured MISSED 2026-08-28, tests/mutation-audit.sh case
  # G18b). Measured on this tree: every entry point either carries a real `.`
  # source line for lib-probe.sh or exports LC_ALL=C itself (auto/doctor/
  # playable-check/waiver take the second road), so no transitive hop is owed.
  code=$(rtm_strip_comments "$s")
  printf '%s\n' "$code" | grepqe '^[[:space:]]*\.[[:space:]].*lib-probe\.sh' \
    || printf '%s\n' "$code" | grepq 'export LC_ALL=C' || a3_bad="$a3_bad $b"
done
[ -z "$a3_bad" ] && ok "no entry point runs with the float gates locale-exposed" \
  || no "LC_ALL unpinned in:$a3_bad"

echo
echo "jurisdiction: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

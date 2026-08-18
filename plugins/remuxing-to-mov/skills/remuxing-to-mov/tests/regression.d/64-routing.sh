#!/usr/bin/env bash
# 64-routing.sh — WO 1.14 Phase 4: the routing switchover, pinned.
#
# The defect under repair (DF-2): diagnose.sh chose the repair by
# HALF_TS ∨ REORDER before weighing evidence, so a fully-timestamped
# (PF_NOPTS_FRAC=0.000) reordered stream — the 2023-VMA class — was routed
# into pairfill-paff.sh, which exits 3 on exactly that shape. Phase 4 routes
# by the MEASURED profile and makes every routing verdict cite its evidence:
#   half_ts=yes (H.264)                          -> pairfill-paff.sh (unchanged)
#   nopts_frac~0 ∧ reorder ∧ class != unknown    -> derive-dts.sh (Rung 3-DERIVE;
#                                                   DTS absent/reconstructed/rotten
#                                                   alike — derivation discards it)
#   nopts_frac~0 ∧ reorder ∧ class = unknown     -> NO automatic rung: announced
#                                                   advisory, --force = operator call
#   non-H.264 timeline rot                       -> derive-dts.sh (codec-agnostic;
#                                                   pairfill/rebuild are H.264-only)
#   missing TS, no reorder                       -> rebuild-paff.sh (unchanged)
# probe.sh gains the ADDITIVE PR_REC_RUNG value `3-derive` (cmd derive-dts.sh
# IN OUT.mov) for the auto-proceed profile only (provably short DTS column:
# depth class match-field/understated or dts_short=yes) — a healthy match-frame
# reordered file keeps its old first rung. auto.sh gains the rung between
# 3-PAIR and the terminal advice; derive's venv-absent exit 10 surfaces its
# bootstrap as the ladder's REVIEW outcome, never a crash.
#
# Injection notes (house hooks, all real): PF_PKT_TICKS_FILE feeds
# pf_reorder_scan an integer-tick pts,dts column; PF_PPF_IN pins
# pictures-per-frame (the ticks hook otherwise reads ppf=unknown by design);
# PF_DECL_DEPTH_IN=unknown mints the unparseable-SPS class; PF_PKT_FILE feeds
# pf_detect the half-timestamped (seconds) column. The end-to-end derive run
# itself is pinned in 63-derive-dts.sh; THIS suite pins the routing.
#
# Standalone: bash tests/regression.d/64-routing.sh
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

# fixtures: the B-pyramid MKV (63's recipe — MKV genuinely stores no DTS, so
# every dts ffprobe shows is the demuxer's reconstruction) and an H.264 TS for
# the half-ts injection.
MKV="$WORK/reord.mkv"
ff -f lavfi -i testsrc2=s=320x240:r=30000/1001 -t 3 -c:v libx264 -g 30 -bf 8 \
   -x264opts b-pyramid=normal:b-adapt=0 -pix_fmt yuv420p "$MKV" || { echo "MKV mint failed"; exit 2; }
TS="$WORK/pair_src.ts"
ff -f lavfi -i testsrc2=s=320x240:r=30000/1001 -t 3 -c:v libx264 -g 30 -bf 2 \
   -pix_fmt yuv420p -f mpegts "$TS" || { echo "TS mint failed"; exit 2; }
# half-timestamped pair profile (pf_detect's PF_PKT_FILE hook, seconds)
awk 'BEGIN{for(i=0;i<120;i++){printf "%.6f,%.6f\nN/A,N/A\n", i*0.033367, i*0.033367}}' > "$WORK/pair.csv"
# understated pyramid ticks (pf_reorder_scan's PF_PKT_TICKS_FILE hook): the
# picture at presentation rank 2 rides at coded index 8 -> measured depth 6,
# beyond declared 2 x ppf 2 = 4 -> class understated, dts_short=yes (the
# provably-short-reconstruction shape the sandbox cannot mint as real PAFF).
awk 'BEGIN{for(i=0;i<60;i++){p=i*17; if(i==2)p=8*17; else if(i==8)p=2*17; printf "%d,%d\n", p, i*17-34}}' > "$WORK/pyr.csv"

echo "== (a) PTS-complete reordered MKV through diagnose: derive-dts named, pairfill NOT =="
o=$(bash "$SC/diagnose.sh" "$MKV" 2>&1)
has   "$o" "derive-dts.sh" "diagnose names derive-dts.sh for the PTS-complete reordered class"
hasnt "$o" "pairfill-paff.sh" "pairfill is NOT named anywhere (the DF-2 misroute is gone)"
has   "$o" "route evidence:" "the routing verdict cites its evidence"
has   "$o" "nopts_frac=0.000 (PTS-complete) + reorder=yes" "…and the evidence is the measured profile"
has   "$o" "dts_source=reconstructed" "…including the DTS provenance that makes derivation the remux itself"

echo
echo "== (b) half-timestamped pair profile still routes to pairfill =="
o=$(PF_PKT_FILE="$WORK/pair.csv" bash "$SC/diagnose.sh" "$TS" 2>&1)
has   "$o" "pairfill-paff.sh" "the pair class keeps its rung"
has   "$o" "half_ts=yes" "…with the pair-signature evidence printed"
hasnt "$o" "derive-dts.sh" "derive is not offered for a half-timestamped stream (missing PTS is pairfill's class)"

echo
echo "== (c) depth class unknown + reorder: announced operator --force advisory, never automatic =="
o=$(PF_PKT_TICKS_FILE="$WORK/pyr.csv" PF_DECL_DEPTH_IN=unknown bash "$SC/diagnose.sh" "$MKV" 2>&1)
has   "$o" "depth class UNKNOWN" "the unparseable-SPS situation is announced"
has   "$o" "OPERATOR" "the route is the operator's call, said so"
has   "$o" "--force" "…with derive-dts.sh --force named as that call"
hasnt "$o" "(PTS-complete)" "derive is NOT named as the automatic profile route on unknown evidence"

echo
echo "== (d) probe.sh emits the additive 3-derive rung on the short-reconstruction profile =="
kv=$(PF_PKT_TICKS_FILE="$WORK/pyr.csv" PF_PPF_IN=2 bash "$SC/probe.sh" "$MKV" --kv 2>&1)
has "$kv" "PR_REC_RUNG=3-derive" "kv carries the additive rung value 3-derive"
has "$kv" "PR_REC_CMD='derive-dts.sh IN OUT.mov'" "kv carries the derive command"
js=$(PF_PKT_TICKS_FILE="$WORK/pyr.csv" PF_PPF_IN=2 bash "$SC/probe.sh" "$MKV" --json 2>&1)
has "$js" '"rec_rung":"3-derive"' "json quotes the non-numeric rung value (stays parseable)"
# ADVERSARIAL half: the plain MKV is healthy (match-frame, dts_short=no) — the
# reconstruction accounts for the depth, so the first rung must NOT be rerouted.
kv=$(bash "$SC/probe.sh" "$MKV" --kv 2>&1)
has "$kv" "PR_REC_RUNG=0" "healthy match-frame reordered MKV keeps first rung 0 (no blanket reroute of B-frame sources)"
kv=$(bash "$SC/probe.sh" "$TS" --kv 2>&1)
has "$kv" "PR_REC_RUNG=0" "ordinary carried-DTS B-frame TS keeps first rung 0"

echo
echo "== (e) recommendation surfaces: grep-pins + the auto.sh derive reach =="
# ts-health: the false "lossless either way" phrasing is STRUCK (a wrong-rung
# constant-rate rebuild of a reordered stream is not lossless in presentation).
if grep -q "lossless either way" "$SC/ts-health.sh"; then
  no "ts-health.sh still says 'lossless either way'"
else
  ok "ts-health.sh no longer claims 'lossless either way'"
fi
grep -q "derive-dts" "$SC/ts-health.sh" && ok "ts-health DTS-rot finding names the derive rung" \
  || no "ts-health.sh never mentions derive-dts"
# rebuild-paff's reorder refusal points at derive-dts now (was: plain copy or pairfill)
o=$(bash "$SC/rebuild-paff.sh" "$TS" "$WORK/rb.mov" 30000/1001 30000 2>&1); rc=$?
[ "$rc" -eq 3 ] && ok "rebuild-paff still refuses the reordered stream (exit 3)" || no "rebuild-paff rc=$rc, want 3"
has "$o" "derive-dts.sh" "…and the refusal names derive-dts for the PTS-complete class"
has "$o" "Rung 3-DERIVE" "…by rung name"
# auto.sh reaches the derive rung; venv-absent exit 10 surfaces the rung's own
# bootstrap as the ladder's REVIEW outcome (never a crash, never a bare FAIL).
mkdir -p "$WORK/nodata"
o=$(PF_PKT_TICKS_FILE="$WORK/pyr.csv" PF_PPF_IN=2 CLAUDE_PLUGIN_DATA="$WORK/nodata" \
    bash "$SC/auto.sh" "$MKV" "$WORK/a.mov" 2>&1); rc=$?
has "$o" "attempting Rung 3-DERIVE" "auto.sh reaches the derive rung on the measured profile"
has "$o" "python3 -m venv" "the rung's one-line bootstrap surfaces through the ladder"
has "$o" ">> REVIEW" "venv-absent outcome is REVIEW with the remedy named"
[ "$rc" -eq 10 ] && ok "…and exits 10 (REVIEW), never a crash" || no "auto rc=$rc, want 10"
[ -f "$WORK/a.mov" ] && no "venv-absent run wrote an output" || ok "nothing written on the dependency REVIEW"
summ=$(printf '%s\n' "$o" | grep -E '^AUTO_SUMMARY ' | tail -1)
case "$summ" in *" rung=3-derive"*) ok "AUTO_SUMMARY rung=3-derive (additive value, greedy-sed safe)";; *) no "AUTO_SUMMARY rung field wrong: $summ";; esac
# dry-run names the plan + the venv-absent semantics without writing anything
o=$(PF_PKT_TICKS_FILE="$WORK/pyr.csv" PF_PPF_IN=2 bash "$SC/auto.sh" "$MKV" "$WORK/dry.mov" --dry-run 2>&1); rc=$?
has "$o" "plan: Rung 3-DERIVE" "dry-run plans the derive rung"
[ "$rc" -eq 0 ] && ok "dry-run exit 0" || no "dry-run rc=$rc"
[ -f "$WORK/dry.mov" ] && no "dry-run wrote a file" || ok "dry-run writes nothing"

for f in "$MKV" "$TS"; do [ -f "$f" ] || no "fixture $(basename "$f") vanished during the run"; done
ok "sources untouched"

echo
echo "routing: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

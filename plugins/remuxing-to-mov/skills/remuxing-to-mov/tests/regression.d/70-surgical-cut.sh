#!/usr/bin/env bash
# 70-surgical-cut.sh — 1.15 Phase 3: the deterministic surgical cut.
#
# Pins, end-to-end on the constructed black-lead fixture (lead-check's
# measured address replayed):
#   1. TIER-2 CONSENT: without --discard-content the cut REFUSES (exit 2),
#      prints the loss statement, writes NOTHING;
#   2. THE CUT: with consent it builds; the first output packet is the target
#      keyframe AU byte-for-byte (size gate); picture is PROGRAM-BRIGHT at
#      the head (luma proof — the whole point of the operation); the
#      verify-source battery inside passes with the identical filters;
#   3. DETERMINISM GUARDS: a non-keyframe index refuses pre-flight (exit 2);
#      a non-mpegts source refuses toward the remux ladder; source==output
#      refuses; SCUT_SUMMARY carries the plan verbatim;
#   4. THE PREDICTION CONTRACT line reconciles (predicted == observed).
#
# Standalone: bash tests/regression.d/70-surgical-cut.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
ffmpeg -hide_banner -bsfs 2>/dev/null | grep -qw noise || { echo "this ffmpeg lacks the noise bsf"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
ff () { ffmpeg -nostdin -hide_banner -loglevel error "$@"; }

echo "== fixture + measured address (lead-check) =="
BL="$WORK/blacklead.ts"
ff -f lavfi -i "color=black:s=320x240:r=25:d=1.4" \
   -f lavfi -i "testsrc2=s=320x240:r=25:d=3" \
   -f lavfi -i "sine=440:d=4.4" \
   -filter_complex "[0:v][1:v]concat=n=2:v=1:a=0[v]" -map "[v]" -map 2:a \
   -c:v libx264 -g 25 -bf 2 -pix_fmt yuv420p -force_key_frames 1.4 -c:a mp2 -f mpegts "$BL"
lc=$(bash "$SC/lead-check.sh" "$BL" 2>&1) || true
line=$(printf '%s\n' "$lc" | grep '^LEADCHECK_SUMMARY ') || true
gp () { printf '%s\n' "$line" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -1; }
SI=$(gp splice_idx); SPT=$(gp splice_pts_t)
{ [ -n "$SI" ] && [ "$SI" != na ]; } || { echo "lead-check could not address the fixture"; exit 2; }
echo "  (address: packet $SI, pts $SPT ticks)"

echo
echo "== 1. Tier-2 consent: refuses without --discard-content, writes nothing =="
out=$(bash "$SC/surgical-cut.sh" "$BL" "$WORK/c1.ts" --video-drop-lt "$SI" --audio-drop-lt-pts "$SPT" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "no consent -> exit 2" || no "no consent rc=$rc (want 2)"
has "$out" "LOSS STATEMENT" "loss statement printed before the refusal"
has "$out" "operator" "the refusal names whose trade it is"
[ ! -f "$WORK/c1.ts" ] && ok "nothing written" || no "refusal wrote a file"
ls "$WORK"/c1.part.* >/dev/null 2>&1 && no "a part file survived the refusal" || ok "no part file either"

echo
echo "== 2. the cut: target AU at packet 0, program-bright head, battery green =="
out=$(bash "$SC/surgical-cut.sh" "$BL" "$WORK/cut.ts" --video-drop-lt "$SI" --audio-drop-lt-pts "$SPT" --discard-content 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "cut exit 0" || no "cut exit $rc"
has "$out" "first output packet = the target keyframe AU" "same-AU size gate passed"
has "$out" ">> OK" "verify-source battery green inside the run"
has "$out" "observed nudges=" "prediction contract reconciled"
sline=$(printf '%s\n' "$out" | grep '^SCUT_SUMMARY ') || true
[ -n "$sline" ] && ok "SCUT_SUMMARY emitted" || no "SCUT_SUMMARY missing"
sp () { printf '%s\n' "$sline" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -1; }
[ "$(sp vdrop_lt)" = "$SI" ] && ok "summary carries the plan (vdrop_lt=$SI)" || no "vdrop_lt=$(sp vdrop_lt)"
[ "$(sp predicted_nudges)" = "$(sp observed_nudges)" ] && ok "predicted == observed nudges" || no "nudge mismatch"
# the whole point: first decoded frame is PROGRAM picture, not black
headluma=$(ffmpeg -nostdin -v error -i "$WORK/cut.ts" -map 0:v:0 -frames:v 1 \
    -vf signalstats,metadata=print:file=- -f null - 2>/dev/null | \
  awk -F'[:= ]+' '/YAVG/{printf "%.0f", $NF; exit}')
awk "BEGIN{exit !(($headluma) > 100)}" && ok "first frame is program-bright (luma $headluma)" \
  || no "first frame luma $headluma (black lead survived?)"
[ -f "$BL" ] && ok "source untouched" || no "source deleted"

echo
echo "== 3. determinism guards =="
out=$(bash "$SC/surgical-cut.sh" "$BL" "$WORK/c2.ts" --video-drop-lt $((SI+1)) --discard-content 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "non-keyframe index -> exit 2 (pre-flight)" || no "non-keyframe rc=$rc"
has "$out" "NOT keyframe-flagged" "refusal names the reason"
ff -y -i "$BL" -map 0 -c copy "$WORK/side.mkv"
out=$(bash "$SC/surgical-cut.sh" "$WORK/side.mkv" "$WORK/c3.ts" --video-drop-lt "$SI" --discard-content 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "non-mpegts -> exit 2" || no "non-mpegts rc=$rc"
bash "$SC/surgical-cut.sh" "$BL" "$BL" --video-drop-lt "$SI" --discard-content >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "source==output -> exit 2" || no "source==output rc=$rc"
bash "$SC/surgical-cut.sh" "$BL" "$WORK/c4.ts" --discard-content >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "missing --video-drop-lt -> exit 2" || no "missing vdrop rc=$rc"

echo
echo "surgical-cut: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

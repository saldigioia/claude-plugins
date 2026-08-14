#!/usr/bin/env bash
# 24-gate-f-budget.sh — work-order 2.4: verify.sh gate (f) source-aware
# tolerance. The fixed 0.25s A/V duration-parity gate re-reported SOURCE damage
# as a remux defect: a capture with measured, real packet loss collapses its
# raw-PCM audio by exactly the dropped time, so every gappy capture landed in
# REVIEW/FAIL forever. Gate (f) now widens by the source's MEASURED total
# forward-gap seconds (caller-supplied RTM_SOURCE_GAP_BUDGET, else disc_scan on
# the source) — and NEVER without a measured budget.
#
# Asserted here, on the gap.ts fixture (one ~4s forward gap, transport clean):
#   1. budget PASS: a gap.ts build (video copy + PCM audio, the gap-collapse
#      shape) passes (f) with the explanation line — both numbers printed plus
#      "residual Δ<x>s explained by measured source loss" — and the whole
#      verify reaches >> OK (the stuck-in-REVIEW-forever class is closed);
#   2. no silent widening: a CLEAN source with artificially offset audio still
#      fails (f) — sync REVIEW, NO budget line (the budget is 0 because the
#      source shows no measured loss);
#   3. caller-supplied budget: RTM_SOURCE_GAP_BUDGET is honored (PASS with the
#      explanation line on the clean-source fixture), wins over the scan even
#      when SMALLER than the measured loss (tightening is always safe-side),
#      and a malformed value is ignored — announced, never a silent widening;
#   4. overfill guard: a mismatch beyond budget+0.25s still fails, budget
#      consulted and printed; the audio-LONG direction surfaces the
#      aresample-overfill open question (BBC run: Δ −2.2s -> +1.9s) instead of
#      papering over it.
#
# Standalone: bash tests/regression.d/24-gate-f-budget.sh
# Exit 0 = all assertions pass; 1 = a regression; 2 = env/fixture failure.
# Regenerates its fixture via make-fixtures.sh when missing. Scratch goes to
# mktemp (auto-cleaned); the repo tree is never written to. Test tooling uses
# ffmpeg directly to mint the offset/overfill outputs (sanctioned for tests —
# the plugin's own scripts never build these deliberately-broken shapes).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"; FIX="$TESTS/fixtures"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
hasnt () { case "$1" in *"$2"*) no "$3 [unexpected: $2]";; *) ok "$3";; esac; }
ff () { ffmpeg -nostdin -hide_banner -loglevel error -y "$@"; }

# fixture: regenerate when missing (media never ships in git)
if [ ! -f "$FIX/gap.ts" ]; then
  echo "== regenerating missing fixture: gap.ts =="
  bash "$TESTS/make-fixtures.sh" gap.ts || { echo "fixture build failed"; exit 2; }
fi
GAP="$FIX/gap.ts"

echo "== 1. budget PASS: the gap.ts build's collapsed-audio Δ is explained by measured loss =="
# the gap-collapse shape itself: video copied (keeps the ~4s forward gap in its
# timeline), MP2 decoded to PCM (the MOV muxer writes PCM contiguously — the
# gap collapses, audio reads ~4s short of video). Pre-2.4 this was REVIEW
# forever; the loss is the SOURCE's, measured, and now explains the delta.
ff -i "$GAP" -map 0:v:0 -map 0:a:0 -c:v copy -c:a pcm_s16le -movflags +faststart -f mov "$WORK/gap.mov" \
  || { echo "gap.mov build failed"; exit 2; }
out=$(bash "$SC/verify.sh" "$GAP" "$WORK/gap.mov" 2>&1); rc=$?
has "$out" "exceeds the base 0.25s tolerance" "the raw Δ really exceeds the fixed gate (fixture is meaningful)"
has "$out" "gap budget" "the measured budget is printed next to the base tolerance"
has "$out" "explained by measured source loss" "the residual-explained line is printed"
has "$out" "disc_scan found" "budget provenance names the source measurement"
hasnt "$out" "sync REVIEW" "no sync REVIEW re-reporting source damage as a remux defect"
{ [ "$rc" -eq 0 ] && case "$out" in *">> OK"*) true;; *) false;; esac; } \
  && ok "gappy capture reaches >> OK, exit 0 (no longer stuck in REVIEW forever)" \
  || { no "gappy build verdict wrong (rc=$rc, want 0 + OK)"; printf '%s\n' "$out" | tail -8 | sed 's/^/   /'; }

echo
echo "== 2. no silent widening: clean source + artificially offset audio still fails (f) =="
# clean 6s A/V-matched MOV as the source; the output carries the SAME video but
# the audio -t-truncated to 5s — a real 1s desync with zero measured source
# loss to hide behind. Must flag exactly as before, with NO budget line.
ff -f lavfi -i "testsrc2=size=320x240:rate=25:duration=6" \
   -f lavfi -i "sine=frequency=440:duration=6:sample_rate=48000" \
   -map 0:v -map 1:a -c:v libx264 -g 25 -pix_fmt yuv420p -c:a pcm_s16le -f mov "$WORK/clean.mov" \
  || { echo "clean.mov build failed"; exit 2; }
ff -i "$WORK/clean.mov" -map 0:a:0 -c copy -t 5 -f mov "$WORK/a5.mov"
ff -i "$WORK/clean.mov" -i "$WORK/a5.mov" -map 0:v:0 -map 1:a:0 -c copy -f mov "$WORK/offset.mov"
out=$(bash "$SC/verify.sh" "$WORK/clean.mov" "$WORK/offset.mov" 2>&1); rc=$?
has "$out" "sync REVIEW" "clean source + offset audio -> still fails (f)"
has "$out" "no measured source loss" "the refusal states WHY the budget did not apply"
hasnt "$out" "explained by measured source loss" "NO budget line on a clean source (never widen unmeasured)"
has "$out" ">> REVIEW" "overall verdict REVIEW"
[ "$rc" -ne 1 ] && ok "REVIEW is not flattened to FAIL (rc=$rc)" || no "clean-offset case FAILed outright (rc=$rc)"

echo
echo "== 3. caller-supplied budget: RTM_SOURCE_GAP_BUDGET honored, precedent, validated =="
# (a) a caller that measured the ORIGINAL capture (e.g. ts-health before an
# intermediate build) may hand the budget in; the 1s offset passes under a
# 1.5s supplied budget, with the same explanation line.
out=$(RTM_SOURCE_GAP_BUDGET=1.5 bash "$SC/verify.sh" "$WORK/clean.mov" "$WORK/offset.mov" 2>&1); rc=$?
has "$out" "explained by measured source loss" "supplied budget -> (f) passes with the explanation line"
has "$out" "caller-supplied RTM_SOURCE_GAP_BUDGET" "budget provenance names the caller"
hasnt "$out" "sync REVIEW" "no sync flag under the supplied budget"
[ "$rc" -eq 0 ] && ok "supplied-budget run exits 0" || no "supplied-budget run rc=$rc"
# (b) the caller's number WINS over the scan — a tighter budget than the
# source's measured loss still fails (tightening is safe-side; the override
# exists because the caller may know the TRUE original better than SRC here)
out=$(RTM_SOURCE_GAP_BUDGET=0.1 bash "$SC/verify.sh" "$GAP" "$WORK/gap.mov" 2>&1)
has "$out" "sync REVIEW" "caller budget 0.1s beats the ~4s scan (env wins; no second-guessing)"
hasnt "$out" "disc_scan found" "no source scan runs when the caller supplied the budget"
# (c) a malformed value is ignored OUT LOUD and the scan takes over — on the
# clean source that means budget 0, so the gate still flags
out=$(RTM_SOURCE_GAP_BUDGET=banana bash "$SC/verify.sh" "$WORK/clean.mov" "$WORK/offset.mov" 2>&1)
has "$out" "is not a number" "malformed budget announced as ignored"
has "$out" "sync REVIEW" "malformed budget cannot silently widen the gate"

echo
echo "== 4. overfill guard: Δ beyond budget+0.25s still fails; audio-LONG surfaces the open question =="
# (a) audio SHORT far beyond the measured ~4s budget (15s of PCM under 24s of
# gapped video, Δ≈9s): more time missing than the source ever lost — a second
# defect rides on top of the source damage; the budget must not absorb it.
ff -f lavfi -i "sine=frequency=440:duration=15:sample_rate=48000" -c:a pcm_s16le -f mov "$WORK/a15.mov"
ff -i "$GAP" -i "$WORK/a15.mov" -map 0:v:0 -map 1:a:0 -c copy -f mov "$WORK/gap_over.mov"
out=$(bash "$SC/verify.sh" "$GAP" "$WORK/gap_over.mov" 2>&1)
has "$out" "gap budget" "the budget was consulted and printed (not silently skipped)"
has "$out" "sync REVIEW" "Δ beyond budget+0.25s -> still fails (f)"
has "$out" "exceeds even the source-loss widened tolerance" "the note states the widened bound was exceeded"
# (b) audio LONG beyond the budget (30s of PCM under ~24s of video, Δ≈6s):
# collapsed source gaps read SHORT — a LONG excess is the aresample-overfill
# signature (BBC resync: Δ −2.2s -> +1.9s), an OPEN question the gate must
# surface, never paper over.
ff -f lavfi -i "sine=frequency=440:duration=30:sample_rate=48000" -c:a pcm_s16le -f mov "$WORK/a30.mov"
ff -i "$GAP" -i "$WORK/a30.mov" -map 0:v:0 -map 1:a:0 -c copy -f mov "$WORK/gap_long.mov"
out=$(bash "$SC/verify.sh" "$GAP" "$WORK/gap_long.mov" 2>&1)
has "$out" "sync REVIEW" "audio-LONG beyond budget -> fails (f)"
has "$out" "aresample-overfill open question" "the overfill open question is surfaced by name"

echo
echo "gate-f budget: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

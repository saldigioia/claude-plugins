#!/usr/bin/env bash
# 23-escalation.sh — work-order 2.3: right rung, and no verdict cascade.
#
# Pins the measured defect (2026-08-13 bench finding, the trimmed BBC build):
# verify.sh failed ONLY gate (f) — the A/V duration gap-collapse — and NAMED
# its own remedy ("resync.sh to fix"), yet auto.sh escalated to Rung 3-PAIR
# pair-fill, a timestamp-profile repair for a problem the file did not have.
# Pair-fill missed its own gates ~18x and the cascade downgraded the run to
# "FAIL: no verified lossless MOV" — condemning the Rung-1 artifact already on
# disk with PROVEN-lossless video (VCL MATCH) and clean timeline/decode/scrub
# gates. (The pair-fill timeline gates themselves were right and are untouched
# — the CASCADE was the defect: rung selection plus verdict reporting.)
#
# The fix under test (auto.sh):
#   RIGHT RUNG — a REVIEW whose verify note is solely the gate-(f) gap-collapse
#   signature escalates to resync.sh (Rung 3-SYNC: video bit-identical, audio
#   re-timed to the picture), honestly capped at REVIEW-grade — never pair-fill,
#   never a timestamp rung.
#   NO VERDICT CASCADE — the best verified artifact is preserved across a
#   failed escalation; the final verdict is ITS grade (exit 10, not 1) and the
#   escalation's failure is reported separately. AUTO_SUMMARY grows
#   best_rung=/best_result= (additive, Ground Rule 4 — placed BEFORE the plain
#   rung= field so batch.sh's greedy '.*rung=' sed keeps reading rung=).
#
# Asserted here:
#   1. tests/fixtures/gap.ts through auto.sh ends honestly: DONE (exit 0) now
#      that item 2.4's gap-budget-aware gate (f) explains the source-loss
#      mismatch — or REVIEW (exit 10) with an artifact if a stricter bench
#      flags it. NEVER: exit 1, the "FAIL: no verified lossless MOV" line, or
#      a pair-fill escalation on a gap-only signature.
#   2. the gate-(f)-only class 2.4 still flags (A/V mismatch with NO measured
#      source loss — the suite's test-17c audio-short shape) routes to
#      Rung 3-SYNC resync, is labeled video-lossless / audio-RE-TIMED, and
#      exits 10 — never pair-fill, never genpts/rebuild.
#   3. verdict cascade: single-GOP + B-frame TS walks Rung 0 -> Rung 2 (both
#      REVIEW) -> Rung 3, which REFUSES the reorder pyramid — the failed
#      escalation must not condemn the Rung-2 artifact: exit 10, artifact
#      restored to OUT, no stray .autobest park, failure reported separately
#      (this exact shape exited 1 with "FAIL: no verified lossless MOV" before
#      the fix).
#   4. a pair-timestamped profile (PF_PKT_FILE injection — the suite's test-19
#      pattern) still routes to Rung 3-PAIR pair-fill: the right-rung fix must
#      not steal the pair class from its repair.
#
# Standalone: bash tests/regression.d/23-escalation.sh
# Exit 0 = all assertions pass; 1 = a regression; 2 = env/fixture failure.
# Regenerates missing fixtures via make-fixtures.sh; scratch goes to mktemp
# (auto-cleaned); the repo tree is never written to.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"; FIX="$TESTS/fixtures"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ff () { ffmpeg -nostdin -hide_banner -loglevel error "$@"; }

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
hasnt () { case "$1" in *"$2"*) no "$3 [unexpected: $2]";; *) ok "$3";; esac; }

# fixtures: regenerate any that are missing (media never ships in git)
if [ ! -f "$FIX/gap.ts" ]; then
  echo "== regenerating missing fixture: gap.ts =="
  bash "$TESTS/make-fixtures.sh" gap.ts || { echo "fixture build failed"; exit 2; }
fi

echo "== 1. gap.ts through auto.sh: honest verdict, never FAIL, never pair-fill =="
out=$(bash "$SC/auto.sh" "$FIX/gap.ts" "$WORK/gap.mov" 2>&1); rc=$?
summ=$(printf '%s\n' "$out" | grep -E '^AUTO_SUMMARY ' | tail -1)
hasnt "$out" "FAIL: no verified lossless MOV" "gap-only source never condemned as FAIL"
hasnt "$out" "attempting Rung 3-PAIR" "no pair-fill escalation on a gap-only signature"
[ -f "$WORK/gap.mov" ] && ok "artifact written" || no "artifact missing at $WORK/gap.mov"
has "$summ" "best_rung=" "AUTO_SUMMARY carries best_rung="
has "$summ" "best_result=" "AUTO_SUMMARY carries best_result="
# 2.4 coordination: the gap-budget-aware gate (f) may PASS the source-loss
# mismatch outright (DONE) — or a stricter bench keeps it REVIEW-with-artifact.
# Both are honest; FAIL and pair-fill (asserted above) never are.
case "$rc" in
  0)  has "$out" ">> DONE" "budget-explained gap -> DONE (exit 0)"
      has "$summ" "result=OK" "summary result matches the exit code (OK)";;
  10) has "$out" ">> REVIEW" "gap flagged -> REVIEW with artifact (exit 10)"
      case "$summ" in *" result=REVIEW"*) ok "summary result matches the exit code (REVIEW)";; *) no "summary result mismatch: $summ";; esac;;
  *)  no "auto.sh exit $rc on gap.ts (want 0 DONE or 10 REVIEW, never 1 FAIL)";;
esac

echo
echo "== 2. gate-(f)-only signature -> Rung 3-SYNC resync, REVIEW-grade, named residual =="
# The class 2.4 still flags: audio genuinely short of video with NO measured
# source loss (suite test-17c shape) — verify's note names resync.sh, and the
# ladder must follow it instead of a timestamp-profile repair.
ff -y -f lavfi -i testsrc2=s=320x240:r=30000/1001 -t 6 -c:v libx264 -g 30 -pix_fmt yuv420p -an "$WORK/dv6.mov"
ff -y -f lavfi -i sine=1000 -t 5.4 -c:a aac "$WORK/da54.m4a"
ff -y -i "$WORK/dv6.mov" -i "$WORK/da54.m4a" -map 0:v:0 -map 1:a:0 -c copy "$WORK/dshort.mov"
out=$(bash "$SC/auto.sh" "$WORK/dshort.mov" "$WORK/dshort_auto.mov" 2>&1); rc=$?
summ=$(printf '%s\n' "$out" | grep -E '^AUTO_SUMMARY ' | tail -1)
has   "$out" "attempting Rung 3-SYNC" "gate-(f)-only REVIEW escalates to resync (Rung 3-SYNC)"
hasnt "$out" "attempting Rung 3-PAIR" "never pair-fill for a sync-only defect"
hasnt "$out" "attempting Rung 2"      "never genpts for a sync-only defect (timestamps are fine)"
has   "$out" "RE-TIMED"               "REVIEW names the residual: audio re-timed, not bit-exact"
hasnt "$out" "FAIL: no verified lossless MOV" "sync-only defect never condemned as FAIL"
[ "$rc" -eq 10 ] && ok "honest REVIEW cap: resync artifact is never an OK (exit 10)" || no "exit 10 expected (got $rc)"
[ -f "$WORK/dshort_auto.mov" ] && ok "resync artifact written" || no "resync artifact missing"
has "$summ" "best_rung=S" "AUTO_SUMMARY best_rung=S (the resync artifact)"
has "$summ" "best_result=REVIEW" "AUTO_SUMMARY best_result=REVIEW"
# the artifact's video really is the lossless copy resync promises
vh () { ffmpeg -nostdin -v error -i "$1" -map 0:v:0 -c copy -f streamhash -hash md5 - 2>/dev/null | sed -n 's/.*MD5=//p' | head -1; }
{ [ -n "$(vh "$WORK/dshort.mov")" ] && [ "$(vh "$WORK/dshort.mov")" = "$(vh "$WORK/dshort_auto.mov")" ]; } \
  && ok "resync artifact video bit-identical to the source" || no "resync artifact video not bit-identical"

echo
echo "== 3. no verdict cascade: a failed Rung-3 escalation cannot condemn the Rung-2 artifact =="
# Single-GOP (>30 s -> scrub-gate REVIEW at every copy rung) WITH B-frames, so
# the Rung-3 rebuild REFUSES the reorder pyramid: before the fix this exact
# walk ended "FAIL: no verified lossless MOV" with the REVIEW artifact on disk.
ff -y -f lavfi -i testsrc2=s=160x120:r=25 -t 35 -c:v libx264 -preset veryfast -g 100000 \
   -keyint_min 100000 -sc_threshold 0 -bf 2 -pix_fmt yuv420p -f mpegts "$WORK/ogb.ts"
out=$(bash "$SC/auto.sh" "$WORK/ogb.ts" "$WORK/ogb.mov" 2>&1); rc=$?
summ=$(printf '%s\n' "$out" | grep -E '^AUTO_SUMMARY ' | tail -1)
has "$out" "attempting Rung 3 (" "the ladder did try the Rung-3 escalation"
has "$out" "restoring it" "failed escalation -> the verified artifact is restored"
has "$out" "does not condemn this artifact" "the escalation's failure is reported separately"
hasnt "$out" "FAIL: no verified lossless MOV" "REVIEW artifact never condemned by the failed escalation"
[ "$rc" -eq 10 ] && ok "exit 10 (REVIEW — the best artifact's grade, not the last attempt's)" || no "exit 10 expected (got $rc)"
[ -f "$WORK/ogb.mov" ] && ok "restored artifact present at OUT" || no "artifact missing after restore"
[ ! -f "$WORK/ogb.mov.autobest" ] && ok "no stray .autobest park left behind" || no "stale .autobest park remains"
has "$summ" "best_rung=2" "AUTO_SUMMARY best_rung=2 (the artifact that verified)"
has "$summ" "best_result=REVIEW" "AUTO_SUMMARY best_result=REVIEW"
case "$summ" in *" rung=3"*) ok "AUTO_SUMMARY rung=3 keeps the last-attempted meaning";; *) no "rung= field wrong: $summ";; esac
# and the restored artifact still verifies to the same grade it earned
v=$(bash "$SC/verify.sh" "$WORK/ogb.ts" "$WORK/ogb.mov" 2>&1) || true
has "$v" ">> REVIEW" "restored artifact re-verifies REVIEW (single-GOP, as flagged)"

echo
echo "== 4. a pair-timestamped profile still routes to pair-fill (right rung, both directions) =="
# PF_PKT_FILE injection (test-19 pattern): ~50% untimestamped packets at 2x
# cadence = the pair class; the dry-run plan must be Rung 3-PAIR, untouched by
# the gate-(f) routing.
ff -y -f lavfi -i testsrc2=size=320x240:rate=30000/1001 -t 6 -c:v libx264 -g 30 -bf 2 \
   -pix_fmt yuv420p -mpegts_flags +resend_headers "$WORK/pair_src.ts"
awk 'BEGIN{for(i=0;i<120;i++){printf "%.6f,%.6f\nN/A,N/A\n", i*0.033367, i*0.033367}}' > "$WORK/pair.csv"
out=$(PF_PKT_FILE="$WORK/pair.csv" bash "$SC/auto.sh" "$WORK/pair_src.ts" "$WORK/pair.mov" --dry-run 2>&1); rc=$?
has "$out" "plan: Rung 3-PAIR" "pair-timestamped profile -> pair-fill plan"
has "$out" "pairfill-paff.sh" "plan names the pair-fill command"
hasnt "$out" "Rung 3-SYNC" "the pair class is never re-routed to resync"
[ "$rc" -eq 0 ] && ok "dry-run exit 0" || no "dry-run exit $rc"
[ ! -f "$WORK/pair.mov" ] && ok "dry-run wrote nothing" || no "dry-run wrote a file"

echo
echo "escalation: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

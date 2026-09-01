#!/usr/bin/env bash
# 120-struct-budget-identity.sh — 1.18.0: the copy-identity settle for gates
# (h)/(k) when the whole-file structural parse is declined on budget.
#
# THE INCIDENT (2026-08-31, RESEARCH-EVERYDAY-COST-1.17.md). A clean 5.15 GB
# H.264+AAC Rung-0 copy exited 10 (REVIEW) because (h)/(k) declined above the
# 4 GiB RTM_STRUCT_MAX_BYTES budget, the decline text named --full as the
# remedy, and the session obediently ran a whole-file header parse PLUS a
# whole-file double decode on a file with zero findings — 25+ minutes for a
# 5-minute job. Bigger file ⇒ more suspicion ⇒ more work.
#
# THE FIX. Over budget, verify first attempts the settle that is SUFFICIENT
# for a copy: payload bit-identical (gate (a)/(b)) + equal video packet
# counts + PTS column equal to the source's (anchor-aligned, 2 ms tolerance).
# All three hold ⇒ (h)/(k) PASS as identity-proven (the output declares what
# the source declared; an inherited defect is diagnosis territory). The
# settle FAILS by construction on authored timing (repair rungs, genpts,
# PTS=DTS flattening) ⇒ UNPROVEN → REVIEW there, unchanged — with the
# remedies named cheapest-first and the budget-REVIEW-is-reportable sentence.
#
# Pins are relationships: the budget is forced tiny (RTM_STRUCT_MAX_BYTES=1)
# so the settle path runs on a small fixture; the flattened-PTS negative case
# is the (k) defect class itself (decode-order presentation on a B-frame
# stream), constructed with the setts bsf when this ffmpeg has it.
#
# Standalone: bash tests/regression.d/120-struct-budget-identity.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
hasnt () { case "$1" in *"$2"*) no "$3 [present: $2]";; *) ok "$3";; esac; }
ff () { ffmpeg -nostdin -y -v error "$@"; }

echo "== 0. fixture: H.264 with B-frames (a reorder pyramid) + AAC, mp4 =="
S="$WORK/src.mp4"
ff -f lavfi -i "testsrc2=size=320x240:rate=25" -f lavfi -i "sine=frequency=440:sample_rate=48000" \
   -t 3 -c:v libx264 -bf 2 -g 25 -pix_fmt yuv420p -c:a aac -movflags +faststart "$S" \
  || { echo "fixture mint failed"; exit 2; }
O="$WORK/out.mov"
bash "$SC/remux.sh" "$S" "$O" >/dev/null 2>&1 || { echo "fixture remux failed"; exit 2; }

echo
echo "== 1. over budget + clean copy -> identity settle, (h)/(k) PASS, verdict OK =="
o=$(RTM_STRUCT_MAX_BYTES=1 bash "$SC/verify.sh" "$S" "$O" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "verify exits 0" || no "verify rc=$rc"
has "$o" ">> OK" "the verdict is OK — a budget decline on a proven copy is not a REVIEW"
has "$o" "copy-identity settle" "the settle announces itself"
has "$o" "identity-proven under budget" "(h)/(k) ledger rows say identity-proven"
has "$o" "whole-file parse not run" "…and state plainly what was NOT run (II.1)"
hasnt "$o" "declined on budget" "no unproven-decline row on the clean copy"

echo
echo "== 2. the settle is a measurement: authored timing (PTS=DTS flatten) REVIEWs =="
# The (k) defect class itself: presentation order flattened to decode order.
# Constructed losslessly with the setts bsf so gate (a) still PASSes (same
# payloads) while the PTS column diverges by whole frame durations.
B="$WORK/flat.mov"
if ff -i "$S" -map 0:v:0 -map 0:a:0 -c copy -bsf:v setts=pts=DTS "$B" 2>/dev/null && [ -s "$B" ]; then
  o=$(RTM_STRUCT_MAX_BYTES=1 bash "$SC/verify.sh" "$S" "$B" 2>&1); rc=$?
  has "$o" "REVIEW" "flattened presentation order does not ship as OK under budget"
  has "$o" "identity settle did not apply" "the settle names its own inapplicability"
  has "$o" "PTS columns diverge" "…with the measured divergence as the reason"
  has "$o" "poc-gate.sh" "the remedy names the cheap settle FIRST ((k) alone, parse only)"
  has "$o" "reportable as done" "…and states the budget-REVIEW-is-reportable doctrine"
else
  echo "  SKIP: this ffmpeg cannot build the setts fixture (bsf missing) — negative case unproven here"
fi

echo
echo "== 3. under budget nothing changed: the whole-file parse still runs =="
o=$(bash "$SC/verify.sh" "$S" "$O" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "default verify exits 0 on the small fixture" || no "default verify rc=$rc"
hasnt "$o" "copy-identity settle" "under budget the settle path is not taken"

echo
echo "== 4. --full still forces the parse regardless of budget =="
o=$(RTM_STRUCT_MAX_BYTES=1 bash "$SC/verify.sh" "$S" "$O" --full 2>&1); rc=$?
hasnt "$o" "copy-identity settle" "--full runs the real gates, never the settle"

echo
echo "struct-budget-identity: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

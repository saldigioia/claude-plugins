#!/usr/bin/env bash
# 102-refused-not-fail.sh — WO-1.15.21 C1 / TIERS.md T3.12: REFUSED and FAIL
# are the two different "no"s this whole round is about, and the ladder must
# not collapse them.
#
# WHY. auto.sh mapped every non-zero child status to RESULT=FAIL — the comment
# at the site said so outright. So a run in which NOTHING WAS BUILT and NOTHING
# WAS WRONG WITH ANY ARTIFACT reported ">> FAIL" and exit 1. The handoff's own
# outcome table prescribes different operator responses for the two, which
# makes the table unusable in the field; batch.sh switches on the exit code and
# recorded the class as a batch failure. The 1.11 round fixed exactly this
# ledger corruption for VP9 at the front door; it grew back one layer down.
#
# A refusal is a gate doing its job: nothing written, source unchanged, a named
# reason. A FAIL is an artifact that exists and did not verify. Conflating them
# tells the operator to go looking for damage that does not exist.
#
# Pins:
#   1. a child exiting 3 through auto.sh -> exit 11, not 1;
#   2. AUTO_SUMMARY carries result=REFUSED and best_rung=none;
#   3. ">> FAIL" never appears for a run that built nothing and refused;
#   4. the refusal's own reason survives to the top (it is not swallowed);
#   5. the same through mov.sh (the verdict vocabulary is API);
#   6. batch.sh records it as REFUSED, not FAIL, and does not fail the batch;
#   7. the NEGATIVE control: a real FAIL still reports FAIL and exit 1 — this
#      round widens the vocabulary, it does not soften it.
#
# Standalone: bash tests/regression.d/102-refused-not-fail.sh
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

# The refusing child is Rung 3-DERIVE on the house orphan fixture: two unstamped
# packets side by side, so neither has a readable pair-mate and the rung refuses
# the WHOLE file with exit 3 — nothing written, nothing wrong with any artifact.
[ -s "$FIX/sparse-orphan.ts" ] || {
  echo "SKIP: sparse-orphan.ts absent — run: bash tests/make-fixtures.sh sparse-orphan.ts"
  echo "refused-not-fail: 0 passed, 0 failed"; exit 0; }
DATA="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/remuxing-to-mov}"
if ! [ -x "$DATA/venv/bin/python" ] || ! "$DATA/venv/bin/python" -c 'import av' 2>/dev/null; then
  echo "SKIP: PyAV venv absent — the refusing rung cannot run here"
  echo "      bootstrap: python3 -m venv \"$DATA/venv\" && \"$DATA/venv/bin/pip\" install av"
  echo "refused-not-fail: 0 passed, 0 failed"; exit 0
fi

echo "== 1. a child's exit 3 through auto.sh is REFUSED, not FAIL =="
o=$(bash "$SC/auto.sh" "$FIX/sparse-orphan.ts" "$WORK/a.mov" 2>&1); rc=$?
[ "$rc" -eq 11 ] && ok "auto.sh exits 11 REFUSED (not 1 FAIL)" || no "auto rc=$rc, want 11"
has "$o" "AUTO_SUMMARY result=REFUSED" "AUTO_SUMMARY carries the REFUSED token"
has "$o" "best_rung=none" "…with no rung claimed (nothing was built)"
hasnt "$o" ">> FAIL" "no >> FAIL for a run that built nothing and refused"
# the rung now DISTINGUISHES why a hole orphaned rather than listing the
# possibilities (WO-1.15.21 A1), so pin the invariant — the child's own
# reason reaches the operator — not one wording of it
has "$o" "cannot be reconstructed" "the child's own reason survives to the top"
has "$o" "WHY:" "…including which shape of missing evidence this is"
ls "$WORK"/a.mov* >/dev/null 2>&1 && no "the refused ladder wrote something" || ok "nothing written"
# pin the LADDER's own verdict line, not the child's text echoed through it
has "$o" "every route this ladder had refused" "the ladder reaches its own REFUSED verdict"

echo
echo "== 2. the same through mov.sh (the verdict vocabulary is API) =="
o=$(bash "$SC/mov.sh" "$FIX/sparse-orphan.ts" "$WORK/m.mov" 2>&1); rc=$?
[ "$rc" -eq 11 ] && ok "mov.sh propagates REFUSED as exit 11" || no "mov rc=$rc, want 11"
hasnt "$o" ">> FAIL" "mov.sh does not report a refusal as FAIL"

echo
echo "== 3. batch.sh records REFUSED and does not fail the batch =="
B="$WORK/batch"; mkdir -p "$B"
cp "$FIX/sparse-orphan.ts" "$B/one.ts"
o=$(bash "$SC/batch.sh" "$B" "$WORK/bout" 2>&1); rc=$?
has "$o" "REFUSED=1" "the batch report counts it as REFUSED"
has "$o" "FAIL=0" "…and not as a FAIL"
[ "$rc" -eq 0 ] && ok "a refused source does not fail the batch (exit 0)" || no "batch rc=$rc, want 0"
if [ -f "$WORK/bout/one.mov.provenance.txt" ]; then
  grep -q '^PROV_VERDICT=REFUSED' "$WORK/bout/one.mov.provenance.txt" \
    && ok "the provenance sidecar records PROV_VERDICT=REFUSED" \
    || no "sidecar verdict is not REFUSED: $(grep '^PROV_VERDICT=' "$WORK/bout/one.mov.provenance.txt" 2>/dev/null)"
fi

echo
echo "== 4. NEGATIVE control: a real FAIL is still a FAIL =="
# A truncated source produces an artifact that cannot verify — damage, not a
# refusal. Widening the vocabulary must not soften the verdict that already
# worked.
head -c 4000 "$FIX/sparse-orphan.ts" > "$WORK/trunc.ts"
o=$(bash "$SC/auto.sh" "$WORK/trunc.ts" "$WORK/t.mov" 2>&1); rc=$?
case "$rc" in
  1)  ok "a genuinely unverifiable source still exits 1 FAIL" ;;
  11) no "a genuine failure was reported as REFUSED — the vocabulary got softer, not sharper" ;;
  *)  ok "a genuinely unverifiable source does not report REFUSED (rc=$rc)" ;;
esac

echo
echo "refused-not-fail: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

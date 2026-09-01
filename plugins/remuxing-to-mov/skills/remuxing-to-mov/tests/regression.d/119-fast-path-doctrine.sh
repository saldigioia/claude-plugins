#!/usr/bin/env bash
# 119-fast-path-doctrine.sh — 1.17.1: the FAST PATH doctrine is pinned prose.
#
# WHY THIS TEST EXISTS. The 2026-08-31 review found the sessions running this
# skill over-diagnosing clean files: SKILL.md's mass is ~95% pathology, its
# workflow led with the clinic (-1) and ts-health (0) before probe (1), and
# nothing stated the base rate or what ffmpeg itself already guarantees on
# `-c copy` (ffmpeg.html §3.1; mov muxer defaults). TIERS.md's own rule —
# gate the assertion, not the attempt — was applied to refusals only.
# 1.17.1 adds the FAST PATH preamble + trusted-baseline section (SKILL.md)
# and extends the TIERS rule to diagnosis. This test pins that prose the same
# way 91/99 pin routing prose: a doc edit that silently drops the doctrine
# fails the bench.
#
# Standalone: bash tests/regression.d/119-fast-path-doctrine.sh
# Exit 0 = all assertions pass; 1 = a regression; 2 = env failure.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; DOCS="$TESTS/.."; ROOT="$TESTS/../../.."
SKILL="$DOCS/SKILL.md"; TIERSMD="$ROOT/TIERS.md"
[ -r "$SKILL" ] && [ -r "$TIERSMD" ] || { echo "docs not readable"; exit 2; }
pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
has    () { grep -qF -- "$2" "$1" && ok "$3" || no "$3"; }
hasnt  () { grep -qF -- "$2" "$1" && no "$3" || ok "$3"; }

echo "== 1. SKILL.md carries the FAST PATH preamble =="
has "$SKILL" "FAST PATH" "the FAST PATH section exists"
has "$SKILL" "Base rate: most files are Rung 0" "…and states the base rate"
has "$SKILL" "Analysis is gated the same way refusals are" \
  "…and gates analysis like refusals (the TIERS extension)"
has "$SKILL" "No trigger → no battery" "…with the trigger rule stated as a rule"

echo
echo "== 2. SKILL.md carries the trusted-baseline section =="
has "$SKILL" "What ffmpeg already does on a plain \`-c copy\`" \
  "the trusted-baseline section exists"
has "$SKILL" "use_editlist" "…and names the muxer's own edit-list handling"
has "$SKILL" "informational" \
  "…and marks probe's Annex-B/AVCC line informational for a plain remux"

echo
echo "== 3. the workflow spine no longer leads with the batteries =="
# The clinic and ts-health must appear AFTER the probe step in the workflow,
# behind the symptom-gate heading — the -1/0 numbering was the 1.17.0-era
# ordering that primed sessions to audit clean files.
has "$SKILL" "Symptom-gated pre-flights" "the symptom-gate heading exists"
hasnt "$SKILL" $'-1. **The SOURCE CLINIC**' \
  "the clinic is no longer workflow step -1"
spine=$(grep -n "The spine — every job" "$SKILL" | cut -d: -f1 | head -1)
gate=$(grep -n "Symptom-gated pre-flights" "$SKILL" | cut -d: -f1 | head -1)
if [ -n "$spine" ] && [ -n "$gate" ] && [ "$spine" -lt "$gate" ]; then
  ok "probe/build/verify spine precedes the symptom-gated block"
else
  no "spine/gate ordering wrong (spine=$spine gate=$gate)"
fi

echo
echo "== 4. TIERS.md extends the rule to diagnosis =="
has "$TIERSMD" "The rule scopes diagnosis too" "the TIERS extension exists"
has "$TIERSMD" "the attempt IS the" "…and states the corollary (attempt = diagnostic)"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]

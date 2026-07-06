#!/usr/bin/env bash
# test-gates.sh — acceptance tests for the Phase 2 gate hardening.
#
# Proves the css-strict.sh checks added in 4.6.0 (multi-line @media,
# 0-2-0 specificity cap, completed --archival, .html/.astro scanning with
# inline-attribute enforcement), the ports-lint.sh CSS-in-JS detector, and
# the escapes.sh malformed-date guard — plus a regression guard for the
# prefers-reduced-motion !important whitelist.
#
# Companion to test-escapes.sh (escape suppression battery).
# Exit codes: 0 — all assertions passed; 1 — one or more failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GATES="$ROOT/eval/fixtures/gates"
# Pin escapes to a nonexistent file so a developer's escapes.md can't skew results.
export ESCAPES_FILE="$ROOT/eval/fixtures/escapes/none.md"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  \033[0;32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; }

# assert <label> <expected-exit> <must-contain> <must-not-contain|-> <exit> <output>
assert() {
  local label="$1" want_exit="$2" need="$3" deny="$4" got_exit="$5" out="$6"
  local failed=0
  [ "$got_exit" -eq "$want_exit" ] || failed=1
  # -F: needles are literal strings, so "[ELA_003]" is not a character class
  printf '%s' "$out" | grep -qF -- "$need" || failed=1
  if [ "$deny" != "-" ]; then
    printf '%s' "$out" | grep -qF -- "$deny" && failed=1
  fi
  if [ "$failed" -eq 0 ]; then ok "$label (exit $got_exit)"; else
    bad "$label — want exit $want_exit & /$need/$([ "$deny" != - ] && echo " & !/$deny/")"
    printf '       --- output ---\n'; printf '%s\n' "$out" | sed 's/^/       /'
  fi
}

echo "css-strict.sh — ELA_001 multi-line @media"
out=$(bash "$SCRIPT_DIR/css-strict.sh" "$GATES/gate-media-multiline.css" 2>&1); ec=$?
assert "multi-line viewport @media block is caught" 1 "[ELA_001]" "-" "$ec" "$out"
assert "exactly the 2 layout declarations flagged" 1 "2 violation(s)" "[ELA_003]" "$ec" "$out"

echo "css-strict.sh — reduced-motion whitelist regression"
out=$(bash "$SCRIPT_DIR/css-strict.sh" "$ROOT/eval/fixtures/css-strict-motion-reset-intentional.css" 2>&1); ec=$?
assert "2 whitelisted resets pass, 2 stray !important fail" 1 "2 violation(s)" "-" "$ec" "$out"

echo "css-strict.sh — ELA_003 specificity cap"
out=$(bash "$SCRIPT_DIR/css-strict.sh" "$GATES/gate-specificity.css" 2>&1); ec=$?
assert "class chains over 0-2-0 are caught" 1 "specificity 0-3-0" "-" "$ec" "$out"
assert "canonical Cover :not() selector stays legal" 1 "2 violation(s)" "principal" "$ec" "$out"

echo "css-strict.sh — ELA_006 archival completion"
out=$(bash "$SCRIPT_DIR/css-strict.sh" --archival "$GATES/gate-archival.css" 2>&1); ec=$?
assert "content-visibility + nesting + @supports not all flagged" 1 "3 violation(s)" "-" "$ec" "$out"
assert "@supports not (...) check exists" 1 "@supports not" "-" "$ec" "$out"
out=$(bash "$SCRIPT_DIR/css-strict.sh" "$GATES/gate-archival.css" 2>&1); ec=$?
assert "ELA_006 checks stay opt-in without --archival" 0 "PASS" "-" "$ec" "$out"

echo "css-strict.sh — .html/.astro scanning (ELA_002)"
out=$(bash "$SCRIPT_DIR/css-strict.sh" "$GATES/gate-inline-style.html" 2>&1); ec=$?
assert "style block + bespoke inline attr flagged" 1 "2 violation(s)" "\-\-space" "$ec" "$out"
out=$(bash "$SCRIPT_DIR/css-strict.sh" "$ROOT/eval/fixtures/inline-style-bespoke.astro" 2>&1); ec=$?
assert "bespoke.astro: 4 per-declaration violations" 1 "4 violation(s)" "-" "$ec" "$out"
out=$(bash "$SCRIPT_DIR/css-strict.sh" "$ROOT/eval/fixtures/inline-style-mixed.astro" 2>&1); ec=$?
assert "mixed.astro: only the bespoke halves fail (3)" 1 "3 violation(s)" "-" "$ec" "$out"
out=$(bash "$SCRIPT_DIR/css-strict.sh" "$ROOT/eval/fixtures/inline-style-primitive-param.astro" 2>&1); ec=$?
assert "primitive-param.astro: parameterization passes" 0 "PASS" "-" "$ec" "$out"

echo "ports-lint.sh — CSS-in-JS detector (ELA_005)"
out=$(bash "$SCRIPT_DIR/ports-lint.sh" --strict "$GATES/ports/cssinjs-violating.tsx" 2>&1); ec=$?
assert "CSS-in-JS patterns fail strict mode" 1 "React.CSSProperties" "-" "$ec" "$out"
assert "bespoke style-object keys flagged" 1 "bespoke key" "-" "$ec" "$out"
out=$(bash "$SCRIPT_DIR/ports-lint.sh" --strict "$GATES/ports/cssinjs-compliant.tsx" 2>&1); ec=$?
assert "class + --custom-property port pattern is CLEAN" 0 "CLEAN" "bespoke key" "$ec" "$out"

echo "escapes.sh — malformed-date guard"
TMP="$(mktemp -d)"
cat > "$TMP/escapes.bad.md" <<'MD'
| ESC ID | Target (glob) | Axiom | Lines | Expires | Owner | Justification |
|--------|---------------|-------|-------|---------|-------|---------------|
| ESC_LEGACY | `*violation.css` | ELA_003 | - | 2099-13-01 | @test | Impossible month: row must be ignored with a warning. |
MD
out=$(ESCAPES_FILE="$TMP/escapes.bad.md" bash "$SCRIPT_DIR/css-strict.sh" "$ROOT/eval/fixtures/escapes/violation.css" 2>&1); ec=$?
assert "impossible expiry warns and does not suppress" 1 "WARNING" "suppressed by" "$ec" "$out"
rm -rf "$TMP"

echo "---"
printf 'gate hardening tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

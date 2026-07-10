#!/usr/bin/env bash
# test-gates.sh — acceptance tests for the Phase 2 gate hardening.
#
# Proves the css-strict.sh checks added in 4.6.0 (multi-line @media,
# 0-2-0 specificity cap, completed --archival, .html/.astro scanning with
# inline-attribute enforcement), the ports-lint.sh CSS-in-JS detector, and
# the escapes.sh malformed-date guard — plus a regression guard for the
# prefers-reduced-motion !important whitelist.
#
# 4.10.0 (Campaign 3 C1/C2) additions: the light-dark ⇒ color-scheme gate
# (ELP_016), the painted-ground gate (ELP_035), the scoped-typographic-
# permissions gate (ELP_034), the near-duplicate-token and adjacent-
# breakpoint warn tripwires, and the css-lint-hook infinite-motion +
# ELP_034 warning tiers.
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

echo "js-budget.sh — trailing-slash dist argument"
TS="$(mktemp -d)"
head -c 20000 /dev/urandom | base64 > "$TS/big.app.js"
cat > "$TS/escapes.md" <<'MD'
| ESC ID | Target (glob) | Axiom | Lines | Expires | Owner | Justification |
|--------|---------------|-------|-------|---------|-------|---------------|
| ESC_JS_EXCESS | `big.*.js` | ELA_005 | - | 2099-12-31 | @test | Trailing-slash arg must still match dist-relative escape globs. |
MD
out=$(ESCAPES_FILE="$TS/escapes.md" bash "$SCRIPT_DIR/js-budget.sh" "$TS/" 2>&1); ec=$?
assert "dist/ with trailing slash still matches escape globs" 0 "suppressed by ESC_JS_EXCESS" "FAIL" "$ec" "$out"
rm -rf "$TS"

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

echo "css-strict.sh — H2.1 true counts past the display cap"
out=$(bash "$SCRIPT_DIR/css-strict.sh" "$GATES/gate-many.css" 2>&1); ec=$?
assert "all 8 findings counted, not just the 5 shown" 1 "8 violation(s)" "-" "$ec" "$out"
assert "remainder line announces the truncation" 1 "and 3 more [ELA_003]" "-" "$ec" "$out"

echo "css-strict.sh — H2.3 per-file suppression advisory"
AD="$(mktemp -d)"
cat > "$AD/many.css" <<'CSS'
.a1 { color: red !important; }
.a2 { color: red !important; }
.a3 { color: red !important; }
.a4 { color: red !important; }
CSS
cat > "$AD/escapes.adv.md" <<'MD'
| ESC ID | Target (glob) | Axiom | Lines | Expires | Owner | Justification |
|--------|---------------|-------|-------|---------|-------|---------------|
| ESC_LEGACY | `*many.css` | ELA_003 | - | 2099-12-31 | @test | File-level waiver to exercise the per-file advisory. |
MD
out=$(ESCAPES_FILE="$AD/escapes.adv.md" bash "$SCRIPT_DIR/css-strict.sh" "$AD/many.css" 2>&1); ec=$?
assert "4 suppressions in one file trip the advisory" 0 "advisory: 4 suppressions" "-" "$ec" "$out"

echo "escapes.sh — H2.3 per-project registry-size advisory"
REG="$(mktemp -d)"
{
  echo '| ESC ID | Target (glob) | Axiom | Lines | Expires | Owner | Justification |'
  echo '|--------|---------------|-------|-------|---------|-------|---------------|'
  for i in 1 2 3 4 5 6 7 8 9 10 11; do
    echo "| ESC_LEGACY | \`f$i.css\` | ELA_003 | - | 2099-12-31 | @test | row $i |"
  done
} > "$REG/escapes.md"
out=$(ESCAPES_FILE="$REG/escapes.md" bash "$SCRIPT_DIR/css-strict.sh" "$ROOT/eval/fixtures/escapes/violation.css" 2>&1); ec=$?
assert "11 registry rows trip the per-project advisory" 1 "per-project cap (10)" "-" "$ec" "$out"
rm -rf "$AD" "$REG"

echo "ports-lint.sh — Tailwind arbitrary-value tripwire (ELA_004)"
out=$(bash "$SCRIPT_DIR/ports-lint.sh" --strict "$GATES/ports/tailwind-arbitrary.html" 2>&1); ec=$?
assert "bracket-literal utilities fail strict" 1 "arbitrary-value" "-" "$ec" "$out"
out=$(bash "$SCRIPT_DIR/ports-lint.sh" --strict "$GATES/ports/tailwind-clean.html" 2>&1); ec=$?
assert "named utilities + primitive params stay CLEAN" 0 "CLEAN" "-" "$ec" "$out"

echo "ports-lint.sh — --docs mode on a reference port"
out=$(bash "$SCRIPT_DIR/ports-lint.sh" --strict --docs "$ROOT/skills/framework-implementations/references/react.md" 2>&1); ec=$?
assert "react.md fenced blocks scan CLEAN via --docs" 0 "CLEAN" "-" "$ec" "$out"

echo "css-strict.sh — C1.1 light-dark ⇒ color-scheme (ELP_016)"
CS1="$(mktemp -d)"
cp "$GATES/gate-colorscheme-fail.css" "$CS1/"
out=$(bash "$SCRIPT_DIR/css-strict.sh" "$CS1" 2>&1); ec=$?
assert "dir-mode: light-dark without color-scheme fails" 1 "ELP_016" "-" "$ec" "$out"
rm -rf "$CS1"
out=$(bash "$SCRIPT_DIR/css-strict.sh" "$GATES/gate-colorscheme-fail.css" 2>&1); ec=$?
assert "single-file scan downgrades to a warning" 0 "ELP_016" "FAIL" "$ec" "$out"
out=$(bash "$SCRIPT_DIR/css-strict.sh" "$GATES/gate-colorscheme-pass.css" 2>&1); ec=$?
assert "light-dark with color-scheme passes silently" 0 "PASS" "ELP_016" "$ec" "$out"

echo "css-strict.sh — C1.2 painted ground (ELP_035)"
PG="$(mktemp -d)"
cp "$GATES/gate-painted-ground-fail.css" "$PG/"
out=$(bash "$SCRIPT_DIR/css-strict.sh" "$PG" 2>&1); ec=$?
assert "dir-mode: unpainted canvas under gradient fails" 1 "ELP_035" "-" "$ec" "$out"
rm -rf "$PG"
PG="$(mktemp -d)"
cp "$GATES/gate-painted-ground-pass.css" "$PG/"
out=$(bash "$SCRIPT_DIR/css-strict.sh" "$PG" 2>&1); ec=$?
assert "painted ground beneath the gradient passes" 0 "PASS" "ELP_035" "$ec" "$out"
cat > "$PG/page.html" <<'HTML'
<!doctype html>
<html><head><style>
body {
  background: linear-gradient(180deg, #dbeafe, #eff6ff);
  background-size: 100% 37.5rem;
}
</style></head><body><p>content</p></body></html>
HTML
out=$(bash "$SCRIPT_DIR/css-strict.sh" "$PG/page.html" 2>&1); ec=$?
assert ".html documents fail per-file even in file mode" 1 "ELP_035" "-" "$ec" "$out"
rm -rf "$PG"

echo "css-strict.sh — C2.2 scoped typographic permissions (ELP_034)"
out=$(bash "$SCRIPT_DIR/css-strict.sh" "$GATES/gate-wordbreak-global.css" 2>&1); ec=$?
assert "body/*/heading grants fail (3 violations)" 1 "3 violation(s)" "-" "$ec" "$out"
assert "failure text cites ELP_034" 1 "ELP_034" "-" "$ec" "$out"
out=$(bash "$SCRIPT_DIR/css-strict.sh" "$GATES/gate-wordbreak-scoped.css" 2>&1); ec=$?
assert "content/print/manual grants stay legal" 0 "PASS" "ELP_034" "$ec" "$out"

echo "css-strict.sh — C2.6/C2.7 warn-tier tripwires"
TW="$(mktemp -d)"
cp "$GATES/gate-token-drift.css" "$TW/"
out=$(bash "$SCRIPT_DIR/css-strict.sh" "$TW" 2>&1); ec=$?
assert "near-duplicate ink tokens warn without failing" 0 "near-duplicate color tokens" "FAIL" "$ec" "$out"
rm -rf "$TW"
TW="$(mktemp -d)"
cp "$GATES/gate-breakpoint-adjacent.css" "$TW/"
out=$(bash "$SCRIPT_DIR/css-strict.sh" "$TW" 2>&1); ec=$?
assert "640/641 breakpoints warn without failing" 0 "adjacent breakpoints" "FAIL" "$ec" "$out"
rm -rf "$TW"

echo "css-lint-hook.sh — C1.4 infinite-motion warning tier"
out=$(bash "$SCRIPT_DIR/css-lint-hook.sh" "$GATES/gate-motion-infinite-decorative.css" 2>&1); ec=$?
assert "decorative infinite animation warns" 0 "INFINITE ANIMATION" "-" "$ec" "$out"
out=$(bash "$SCRIPT_DIR/css-lint-hook.sh" "$GATES/gate-motion-infinite-status.css" 2>&1); ec=$?
out="${out}__CLEAN__"
assert "motion: status marker silences the warning" 0 "__CLEAN__" "INFINITE ANIMATION" "$ec" "$out"

echo "css-lint-hook.sh — C2.2 warn tier (ELP_034)"
out=$(bash "$SCRIPT_DIR/css-lint-hook.sh" "$GATES/gate-wordbreak-global.css" 2>&1); ec=$?
assert "hook warns on global typographic grants" 0 "ELP_034" "-" "$ec" "$out"

echo "---"
printf 'gate hardening tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

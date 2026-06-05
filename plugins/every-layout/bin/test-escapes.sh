#!/usr/bin/env bash
# test-escapes.sh — Phase 1 acceptance for escape-aware axiom gates.
#
# Proves that bin/css-strict.sh and bin/js-budget.sh honor escapes.md:
#   - a violation WITH a valid, unexpired escape  -> exit 0, "suppressed by ESC_…"
#   - the same violation with an EXPIRED escape    -> exit !=0, "escape expired"
#   - the same violation with NO escape            -> exit !=0, normal violation
#
# "Today" is pinned so the result is reproducible regardless of run date.
#
# Exit codes: 0 — all assertions passed; 1 — one or more failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIX="$ROOT/eval/fixtures/escapes"
export ESCAPES_TODAY=2026-06-04   # valid escape expires 2099, expired one 2020

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  \033[0;32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; }

# assert <label> <expected-exit> <must-contain> <must-not-contain|-> <exit> <output>
assert() {
  local label="$1" want_exit="$2" need="$3" deny="$4" got_exit="$5" out="$6"
  local bad=0
  [ "$got_exit" -eq "$want_exit" ] || { bad=1; }
  printf '%s' "$out" | grep -q -- "$need" || bad=1
  if [ "$deny" != "-" ]; then
    printf '%s' "$out" | grep -q -- "$deny" && bad=1
  fi
  if [ "$bad" -eq 0 ]; then ok "$label (exit $got_exit)"; else
    bad "$label — want exit $want_exit & /$need/$([ "$deny" != - ] && echo " & !/$deny/")"
    printf '       --- output ---\n'; printf '%s\n' "$out" | sed 's/^/       /'
  fi
}

echo "css-strict.sh — escape suppression"

out=$(ESCAPES_FILE="$FIX/escapes.valid.md" bash "$SCRIPT_DIR/css-strict.sh" "$FIX" 2>&1); ec=$?
assert "valid escape suppresses ELA_003" 0 "suppressed by ESC_LEGACY" "FAIL" "$ec" "$out"

out=$(ESCAPES_FILE="$FIX/escapes.expired.md" bash "$SCRIPT_DIR/css-strict.sh" "$FIX" 2>&1); ec=$?
assert "expired escape fails the gate" 1 "escape expired" "suppressed by" "$ec" "$out"

out=$(ESCAPES_FILE="$FIX/none.md" bash "$SCRIPT_DIR/css-strict.sh" "$FIX" 2>&1); ec=$?
assert "no escape fails the gate" 1 "[ELA_003]" "suppressed by" "$ec" "$out"

echo "js-budget.sh — escape suppression"
DIST="$(mktemp -d)"
# Incompressible base64 sized so the single route is OVER the 15 KB per-route
# gzip budget but UNDER the 30 KB page-total budget (~20 KB gzipped) — so a
# per-route escape alone is enough to make the gate pass.
head -c 20000 /dev/urandom | base64 > "$DIST/big.app.js"

cat > "$DIST/escapes.valid.md" <<'MD'
| ESC ID | Target (glob) | Axiom | Lines | Expires | Owner | Justification |
|--------|---------------|-------|-------|---------|-------|---------------|
| ESC_JS_EXCESS | `big.*.js` | ELA_005 | - | 2099-12-31 | @test | Fixture: unexpired over-budget route. |
MD
cat > "$DIST/escapes.expired.md" <<'MD'
| ESC ID | Target (glob) | Axiom | Lines | Expires | Owner | Justification |
|--------|---------------|-------|-------|---------|-------|---------------|
| ESC_JS_EXCESS | `big.*.js` | ELA_005 | - | 2020-01-01 | @test | Fixture: expired over-budget route. |
MD

out=$(ESCAPES_FILE="$DIST/escapes.valid.md" bash "$SCRIPT_DIR/js-budget.sh" "$DIST" 2>&1); ec=$?
assert "valid escape suppresses over-budget route" 0 "suppressed by ESC_JS_EXCESS" "FAIL" "$ec" "$out"

out=$(ESCAPES_FILE="$DIST/escapes.expired.md" bash "$SCRIPT_DIR/js-budget.sh" "$DIST" 2>&1); ec=$?
assert "expired escape fails the budget gate" 1 "escape expired" "-" "$ec" "$out"

out=$(ESCAPES_FILE="$DIST/none.md" bash "$SCRIPT_DIR/js-budget.sh" "$DIST" 2>&1); ec=$?
assert "no escape fails the budget gate" 1 "OVER" "suppressed by" "$ec" "$out"

rm -rf "$DIST"

echo "css-strict.sh — line-level escape precision"
LL="$(mktemp -d)"
# Two ELA_003 !important violations, on lines 2 and 5. The escape is scoped to
# line 2 only, so line 2 is suppressed but line 5 must still fail the gate.
cat > "$LL/two.css" <<'CSS'
.a {
  color: red !important;
}
.b {
  color: blue !important;
}
CSS
cat > "$LL/escapes.md" <<'MD'
| ESC ID | Target (glob) | Axiom | Lines | Expires | Owner | Justification |
|--------|---------------|-------|-------|---------|-------|---------------|
| ESC_LEGACY | `*/two.css` | ELA_003 | 2 | 2099-12-31 | @test | Fixture: line-scoped escape covers line 2 only. |
MD
out=$(ESCAPES_FILE="$LL/escapes.md" bash "$SCRIPT_DIR/css-strict.sh" "$LL" 2>&1); ec=$?
# line 3 suppressed, line 6 still a violation -> gate fails with exactly 1 left
assert "line-scoped escape suppresses its line" 1 "suppressed by ESC_LEGACY" "-" "$ec" "$out"
assert "line-scoped escape leaves the other line failing" 1 "1 violation(s) across 1 file(s)" "-" "$ec" "$out"
rm -rf "$LL"

echo "---"
printf 'escape gate tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

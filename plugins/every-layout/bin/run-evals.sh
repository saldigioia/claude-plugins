#!/usr/bin/env bash
# Run eval fixture validation — checks that fixtures are well-formed
# and contain the expected violation markers and audit result comments.
#
# This is a structural check, not an AI-scored eval. It verifies:
#   1. Every fixture has an EXPECTED AUDIT RESULT comment
#   2. Anti-pattern fixtures contain VIOLATION comments
#   3. Compliant fixtures contain no VIOLATION comments
#   4. Expected score ranges are valid (X-Y/24 format)
#   5. Every eval prompt references at least one fixture
#
# Usage: run-evals.sh

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

check() {
  local status="$1" file="$2" msg="$3"
  if [ "$status" = "pass" ]; then
    printf "${GREEN}PASS${NC}  %-50s %s\n" "$file" "$msg"
    PASS=$((PASS + 1))
  elif [ "$status" = "fail" ]; then
    printf "${RED}FAIL${NC}  %-50s %s\n" "$file" "$msg"
    FAIL=$((FAIL + 1))
  else
    printf "${YELLOW}WARN${NC}  %-50s %s\n" "$file" "$msg"
    WARN=$((WARN + 1))
  fi
}

printf "${BOLD}Every Layout Eval Suite — Structural Validation${NC}\n"
echo "================================================="
echo ""

# --- Fixture Checks ---
printf "${BOLD}Fixtures${NC}\n"

FIXTURES=$(find eval/fixtures -type f \( -name "*.html" -o -name "*.astro" \) 2>/dev/null | sort) || true

if [ -z "$FIXTURES" ]; then
  check "fail" "eval/fixtures/" "No fixtures found"
else
  while IFS= read -r fixture; do
    [ -z "$fixture" ] && continue
    basename=$(basename "$fixture")

    # Check for EXPECTED AUDIT RESULT
    if grep -q "EXPECTED AUDIT RESULT" "$fixture" 2>/dev/null; then
      check "pass" "$basename" "Has expected result comment"
    else
      check "fail" "$basename" "Missing EXPECTED AUDIT RESULT comment"
    fi

    # Anti-pattern fixtures should have VIOLATION comments
    if echo "$basename" | grep -q "anti-pattern"; then
      VIOLATION_COUNT=$(grep -c "VIOLATION" "$fixture" 2>/dev/null) || VIOLATION_COUNT=0
      if [ "$VIOLATION_COUNT" -gt 0 ]; then
        check "pass" "$basename" "$VIOLATION_COUNT VIOLATION markers"
      else
        check "fail" "$basename" "Anti-pattern fixture has no VIOLATION markers"
      fi
    fi

    # Compliant fixtures should NOT have VIOLATION comments
    if echo "$basename" | grep -q "compliant"; then
      if grep -q "VIOLATION" "$fixture" 2>/dev/null; then
        check "fail" "$basename" "Compliant fixture contains VIOLATION markers"
      else
        check "pass" "$basename" "No violation markers (correct for compliant)"
      fi
    fi

    # Check score format (X-Y/24 or X/24)
    if grep -qE 'Score:.*\/24' "$fixture" 2>/dev/null; then
      check "pass" "$basename" "Score uses /24 rubric scale"
    elif grep -qE 'Score:.*\/[0-9]+' "$fixture" 2>/dev/null; then
      check "fail" "$basename" "Score uses non-24 rubric scale"
    fi

  done <<< "$FIXTURES"
fi

echo ""

# --- Eval Prompt Checks ---
printf "${BOLD}Eval Prompts${NC}\n"

PROMPTS=$(find eval/prompts -name "*.md" 2>/dev/null | sort) || true

if [ -z "$PROMPTS" ]; then
  check "fail" "eval/prompts/" "No eval prompts found"
else
  while IFS= read -r prompt; do
    [ -z "$prompt" ] && continue
    basename=$(basename "$prompt")

    # Check for scoring rubric (numeric scale)
    if grep -qE '(0-[0-9]+|Score|Scoring|rubric)' "$prompt" 2>/dev/null; then
      check "pass" "$basename" "Has scoring criteria"
    else
      check "warn" "$basename" "No scoring rubric found"
    fi

    # Check for fixture references
    if grep -qE 'eval/fixtures/|fixture' "$prompt" 2>/dev/null; then
      check "pass" "$basename" "References fixtures"
    else
      check "warn" "$basename" "Does not reference any fixtures"
    fi

    # Check for output format section
    if grep -qE '(Output Format|OUTPUT FORMAT|Expected.*Output)' "$prompt" 2>/dev/null; then
      check "pass" "$basename" "Has output format specification"
    else
      check "warn" "$basename" "No output format specification"
    fi

  done <<< "$PROMPTS"
fi

echo ""

# --- Cross-Reference Checks ---
printf "${BOLD}Cross-References${NC}\n"

# Check that rubric.md exists and has 8 dimensions
if [ -f "eval/rubric.md" ]; then
  DIMENSIONS=$(grep -cE '^### [0-9]+\.' "eval/rubric.md" 2>/dev/null) || DIMENSIONS=0
  if [ "$DIMENSIONS" -eq 8 ]; then
    check "pass" "rubric.md" "8 scoring dimensions present"
  else
    check "fail" "rubric.md" "Expected 8 dimensions, found $DIMENSIONS"
  fi
else
  check "fail" "rubric.md" "File not found"
fi

# Check that expected-properties.md covers all 13 primitives
if [ -f "eval/expected-properties.md" ]; then
  PRIMITIVES=$(grep -cE '^## ' "eval/expected-properties.md" 2>/dev/null) || PRIMITIVES=0
  if [ "$PRIMITIVES" -eq 13 ]; then
    check "pass" "expected-properties.md" "13 primitives documented"
  else
    check "fail" "expected-properties.md" "Expected 13 primitives, found $PRIMITIVES"
  fi
else
  check "fail" "expected-properties.md" "File not found"
fi

echo ""

# --- Summary ---
echo "================================================="
TOTAL=$((PASS + FAIL + WARN))
printf "${BOLD}Results:${NC} %d checks — " "$TOTAL"
printf "${GREEN}%d pass${NC}, " "$PASS"
printf "${RED}%d fail${NC}, " "$FAIL"
printf "${YELLOW}%d warn${NC}\n" "$WARN"

if [ "$FAIL" -gt 0 ]; then
  printf "${RED}${BOLD}FAIL${NC}\n"
  exit 1
else
  printf "${GREEN}${BOLD}PASS${NC}\n"
  exit 0
fi

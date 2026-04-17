#!/usr/bin/env bash
# js-budget.sh — enforce the ELA_005 JavaScript budget.
#
# Measures compressed (gzip) size of every .js file in a build output directory
# and fails when any route, or the page total, exceeds the budget in
# skills/css-design-system/references/performance-rules.md.
#
# Usage:
#   bin/js-budget.sh <dist-dir>
#
# Exit codes:
#   0 — every route within budget
#   1 — one or more routes over budget
#   2 — invocation error (missing args, unreadable directory)

set -uo pipefail

DIR="${1:-}"
if [ -z "$DIR" ]; then
  echo "usage: bin/js-budget.sh <dist-dir>" >&2
  echo "  e.g. bin/js-budget.sh dist/" >&2
  exit 2
fi
[ -d "$DIR" ] || { echo "error: $DIR is not a directory" >&2; exit 2; }

# Canonical budgets mirror skills/css-design-system/references/performance-rules.md
PER_ROUTE_LIMIT=$((15 * 1024))     # 15 KB compressed
PAGE_TOTAL_LIMIT=$((30 * 1024))    # 30 KB compressed

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

printf "${BOLD}js-budget.sh — ELA_005 JavaScript budget gate${NC}\n"
printf "Directory:     %s\n" "$DIR"
printf "Per-route:     %d bytes (~%s)\n" "$PER_ROUTE_LIMIT" \
  "$(awk -v n="$PER_ROUTE_LIMIT" 'BEGIN{printf "%g KB", n/1024}')"
printf "Page total:    %d bytes (~%s)\n" "$PAGE_TOTAL_LIMIT" \
  "$(awk -v n="$PAGE_TOTAL_LIMIT" 'BEGIN{printf "%g KB", n/1024}')"
echo "---"

JS_FILES=$(find "$DIR" -type f -name "*.js" -not -path "*/node_modules/*" 2>/dev/null | sort) || true

if [ -z "$JS_FILES" ]; then
  printf "${GREEN}No JavaScript shipped — axiom ELA_005 trivially satisfied.${NC}\n"
  exit 0
fi

TOTAL=0
FAILURES=0

printf "%-48s %10s %10s %s\n" "File" "Raw" "Gzipped" "Status"
printf "%-48s %10s %10s %s\n" "$(printf '%0.s-' {1..48})" "----------" "----------" "------"

while IFS= read -r file; do
  [ -z "$file" ] && continue
  RAW=$(wc -c < "$file" | tr -d ' ')
  GZ=$(gzip -c "$file" | wc -c | tr -d ' ')
  TOTAL=$((TOTAL + GZ))

  REL="${file#$DIR/}"
  RAW_KB=$(awk -v n="$RAW" 'BEGIN{printf "%.1f", n/1024}')
  GZ_KB=$(awk -v n="$GZ" 'BEGIN{printf "%.1f", n/1024}')
  if [ "$GZ" -gt "$PER_ROUTE_LIMIT" ]; then
    printf "%-48s %7s KB %7s KB ${RED}OVER${NC}\n" "$REL" "$RAW_KB" "$GZ_KB"
    FAILURES=$((FAILURES + 1))
  else
    printf "%-48s %7s KB %7s KB ${GREEN}OK${NC}\n" "$REL" "$RAW_KB" "$GZ_KB"
  fi
done <<< "$JS_FILES"

echo "---"
TOTAL_KB=$(awk -v n="$TOTAL" 'BEGIN{printf "%.1f", n/1024}')
PAGE_LIMIT_KB=$(awk -v n="$PAGE_TOTAL_LIMIT" 'BEGIN{printf "%g", n/1024}')
if [ "$TOTAL" -gt "$PAGE_TOTAL_LIMIT" ]; then
  printf "Page total:    %s KB gzipped  ${RED}OVER %s KB page budget${NC}\n" "$TOTAL_KB" "$PAGE_LIMIT_KB"
  FAILURES=$((FAILURES + 1))
else
  printf "Page total:    %s KB gzipped  ${GREEN}OK${NC}\n" "$TOTAL_KB"
fi

echo ""
if [ "$FAILURES" -eq 0 ]; then
  printf "${GREEN}${BOLD}PASS${NC} — JavaScript within ELA_005 budget.\n"
  exit 0
else
  printf "${RED}${BOLD}FAIL${NC} — %d budget violation(s).\n" "$FAILURES"
  printf "\nOptions:\n"
  printf "  1. Remove JavaScript until under budget (preferred)\n"
  printf "  2. Register ESC_JS_EXCESS in escapes.md with justification and expiry\n"
  printf "  3. Raise the limit in skills/css-design-system/references/performance-rules.md\n"
  printf "     (requires CHANGELOG entry — budgets are contracts)\n"
  exit 1
fi

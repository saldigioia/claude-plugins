#!/usr/bin/env bash
# Measure CSS files against the Every Layout performance budget
# Usage: css-budget.sh [directory]
#
# Canonical source for thresholds:
#   skills/css-design-system/references/performance-rules.md
# The constants below mirror that reference; update both together.

set -uo pipefail

DIR="${1:-.}"
BUDGET_MINIFIED=34816    # bytes — performance-rules.md: "Total system CSS (minified)"
BUDGET_GZIPPED=8704      # bytes — performance-rules.md: "Total system CSS (gzipped)"
BUDGET_PROPS=120         #       — performance-rules.md (tier cap)
BUDGET_PER_FILE=10240    # bytes — performance-rules.md: "Per-file minified"

# Pretty-print labels derived from the constants above
BUDGET_MINIFIED_LABEL=$(awk "BEGIN{printf \"%g KB\", $BUDGET_MINIFIED/1024}")
BUDGET_GZIPPED_LABEL=$(awk "BEGIN{printf \"%g KB\", $BUDGET_GZIPPED/1024}")
BUDGET_PER_FILE_LABEL=$(awk "BEGIN{printf \"%g KB\", $BUDGET_PER_FILE/1024}")

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

TOTAL_RAW=0
TOTAL_PROPS=0
HAS_ID_SELECTOR=0
FILES_CHECKED=0
FAILURES=0

# Minify CSS on stdin. Strips /* */ comments (multi-line safe), collapses
# whitespace around punctuation, and removes leading/trailing whitespace.
# Not perfect but dependable on any POSIX awk, no npm install needed.
minify_css() {
  awk '
    BEGIN { RS = "" }
    {
      # Strip C-style comments
      gsub(/\/\*[^*]*\*+([^\/*][^*]*\*+)*\//, "", $0)
      # Collapse whitespace sequences to single space
      gsub(/[ \t\n\r]+/, " ", $0)
      # Remove spaces around punctuation that do not need them
      gsub(/ *([{};:,>+~()]) */, "\\1", $0)
      # Trim leading / trailing space
      sub(/^ +/, "", $0); sub(/ +$/, "", $0)
      print $0
    }
  '
}

CSS_FILES=$(find "$DIR" -type f -name "*.css" -not -path "*/node_modules/*" -not -path "*/.astro/*" -not -path "*/dist/*" 2>/dev/null) || true

if [ -z "$CSS_FILES" ]; then
  echo "No CSS files found in $DIR"
  exit 0
fi

printf "${BOLD}%-40s %8s %8s %6s${NC}\n" "File" "Raw" "Props" "Status"
printf "%-40s %8s %8s %6s\n" "$(printf '%0.s-' {1..40})" "--------" "------" "------"

while IFS= read -r file; do
  [ -z "$file" ] && continue
  FILES_CHECKED=$((FILES_CHECKED + 1))

  # Raw size
  RAW_SIZE=$(wc -c < "$file" | tr -d ' ')
  TOTAL_RAW=$((TOTAL_RAW + RAW_SIZE))

  # Custom property count
  PROPS=$(grep -cE '^\s*--[a-zA-Z]' "$file" 2>/dev/null) || PROPS=0
  TOTAL_PROPS=$((TOTAL_PROPS + PROPS))

  # Check for ID selectors (specificity > 0-2-0)
  if grep -qE '#[a-zA-Z]' "$file" 2>/dev/null; then
    HAS_ID_SELECTOR=1
  fi

  # Per-file status
  RAW_KB=$(echo "scale=1; $RAW_SIZE / 1024" | bc)
  if [ "$RAW_SIZE" -gt "$BUDGET_PER_FILE" ]; then
    STATUS="${RED}OVER${NC}"
    FAILURES=$((FAILURES + 1))
  else
    STATUS="${GREEN}OK${NC}"
  fi

  REL_PATH="${file#$DIR/}"
  printf "%-40s %6sKB %6s   " "$REL_PATH" "$RAW_KB" "$PROPS"
  printf "${STATUS}\n"
done <<< "$CSS_FILES"

echo ""
printf "${BOLD}Summary${NC}\n"
echo "---"

# Total raw
TOTAL_RAW_KB=$(echo "scale=1; $TOTAL_RAW / 1024" | bc)
printf "Files checked:      %s\n" "$FILES_CHECKED"
printf "Total raw size:     %s KB\n" "$TOTAL_RAW_KB"

# Measure real minified + gzipped sizes
MINIFIED_BYTES=$(
  while IFS= read -r file; do
    [ -n "$file" ] && cat "$file"
  done <<< "$CSS_FILES" | minify_css | wc -c | tr -d ' '
)
GZIPPED_BYTES=$(
  while IFS= read -r file; do
    [ -n "$file" ] && cat "$file"
  done <<< "$CSS_FILES" | minify_css | gzip -c | wc -c | tr -d ' '
)
MIN_KB=$(echo "scale=1; $MINIFIED_BYTES / 1024" | bc)
GZ_KB=$(echo "scale=1; $GZIPPED_BYTES / 1024" | bc)
if [ "$MINIFIED_BYTES" -gt "$BUDGET_MINIFIED" ]; then
  printf "Minified:           %s KB / %s  ${RED}OVER BUDGET${NC}\n" "$MIN_KB" "$BUDGET_MINIFIED_LABEL"
  FAILURES=$((FAILURES + 1))
else
  printf "Minified:           %s KB / %s  ${GREEN}OK${NC}\n" "$MIN_KB" "$BUDGET_MINIFIED_LABEL"
fi
if [ "$GZIPPED_BYTES" -gt "$BUDGET_GZIPPED" ]; then
  printf "Gzipped:            %s KB / %s  ${RED}OVER BUDGET${NC}\n" "$GZ_KB" "$BUDGET_GZIPPED_LABEL"
  FAILURES=$((FAILURES + 1))
else
  printf "Gzipped:            %s KB / %s  ${GREEN}OK${NC}\n" "$GZ_KB" "$BUDGET_GZIPPED_LABEL"
fi

# Custom properties
if [ "$TOTAL_PROPS" -gt "$BUDGET_PROPS" ]; then
  printf "Custom properties:  %s / %s  ${RED}OVER BUDGET${NC}\n" "$TOTAL_PROPS" "$BUDGET_PROPS"
  FAILURES=$((FAILURES + 1))
else
  printf "Custom properties:  %s / %s  ${GREEN}OK${NC}\n" "$TOTAL_PROPS" "$BUDGET_PROPS"
fi

# Specificity
if [ "$HAS_ID_SELECTOR" -eq 1 ]; then
  printf "Max specificity:    ${RED}ID selectors found (exceeds 0-2-0)${NC}\n"
  FAILURES=$((FAILURES + 1))
else
  printf "Max specificity:    ${GREEN}No ID selectors (within 0-2-0)${NC}\n"
fi

echo "---"
if [ "$FAILURES" -eq 0 ]; then
  printf "${GREEN}${BOLD}PASS${NC} — All metrics within budget.\n"
else
  printf "${RED}${BOLD}FAIL${NC} — %d metric(s) over budget.\n" "$FAILURES"
fi

exit $((FAILURES > 0 ? 1 : 0))

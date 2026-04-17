#!/usr/bin/env bash
# Audit CSS files in a directory for Every Layout compliance
# Usage: css-audit.sh [directory] [--verbose]
#
# Checks for:
#   1. Physical properties (width/height instead of inline-size/block-size)
#   2. Arbitrary values (pixel values not from modular scale)
#   3. Media queries for layout (min-width/max-width changing layout properties)

set -euo pipefail

DIR="${1:-.}"
VERBOSE="${2:-}"
VIOLATIONS=0
FILES_CHECKED=0

# Accepted pixel values (borders, outlines — everything else must map to --s* tokens)
ACCEPTED_PX="1px|2px|3px"

RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m'

report() {
  local severity="$1" file="$2" line="$3" msg="$4"
  VIOLATIONS=$((VIOLATIONS + 1))
  if [ "$severity" = "error" ]; then
    printf "${RED}[ERROR]${NC} %s:%s — %s\n" "$file" "$line" "$msg"
  else
    printf "${YELLOW}[WARN]${NC}  %s:%s — %s\n" "$file" "$line" "$msg"
  fi
}

# Find all CSS files
CSS_FILES=$(find "$DIR" -name "*.css" -not -path "*/node_modules/*" -not -path "*/.astro/*" -not -path "*/dist/*" 2>/dev/null || true)

if [ -z "$CSS_FILES" ]; then
  echo "No CSS files found in $DIR"
  exit 0
fi

while IFS= read -r file; do
  FILES_CHECKED=$((FILES_CHECKED + 1))
  LINE_NUM=0

  while IFS= read -r line; do
    LINE_NUM=$((LINE_NUM + 1))

    # Skip comments
    case "$line" in
      *"/*"*|*"//"*) continue ;;
    esac

    # 1. Physical properties
    # Check for width/height (but not inline-size/block-size, min-inline-size, etc.)
    if echo "$line" | grep -qE '^\s*(width|height|min-width|max-width|min-height|max-height)\s*:' 2>/dev/null; then
      # Allow exceptions: inside transform, translate, SVG attributes
      if ! echo "$line" | grep -qE '(translate|transform|svg|img\[|video\[)' 2>/dev/null; then
        report "error" "$file" "$LINE_NUM" "Physical property: use inline-size/block-size instead — $(echo "$line" | xargs)"
      fi
    fi

    # Check for physical margin/padding
    if echo "$line" | grep -qE '^\s*(margin|padding)-(left|right|top|bottom)\s*:' 2>/dev/null; then
      report "error" "$file" "$LINE_NUM" "Physical property: use logical equivalents (inline-start/end, block-start/end) — $(echo "$line" | xargs)"
    fi

    # 2. Arbitrary pixel values
    if echo "$line" | grep -qoE '[0-9]+px' 2>/dev/null; then
      # Extract the pixel value
      PX_VAL=$(echo "$line" | grep -oE '[0-9]+px' | head -1)
      # Skip accepted values (border widths)
      if ! echo "$PX_VAL" | grep -qE "^($ACCEPTED_PX)$" 2>/dev/null; then
        # Skip if it's in a var() fallback that matches scale
        if ! echo "$line" | grep -q 'var(--' 2>/dev/null; then
          report "warn" "$file" "$LINE_NUM" "Arbitrary pixel value: $PX_VAL — use modular scale token instead — $(echo "$line" | xargs)"
        fi
      fi
    fi

    # 3. Media queries for layout
    if echo "$line" | grep -qE '@media.*\b(min-width|max-width)\b' 2>/dev/null; then
      report "warn" "$file" "$LINE_NUM" "Media query for layout: prefer intrinsic layout (Grid/Switcher/Sidebar) — $(echo "$line" | xargs)"
    fi

  done < "$file"
done <<< "$CSS_FILES"

echo ""
echo "---"
echo "Files checked: $FILES_CHECKED"

if [ "$VIOLATIONS" -eq 0 ]; then
  printf "${GREEN}No violations found.${NC}\n"
else
  printf "${RED}%d violation(s) found.${NC}\n" "$VIOLATIONS"
fi

exit $((VIOLATIONS > 0 ? 1 : 0))

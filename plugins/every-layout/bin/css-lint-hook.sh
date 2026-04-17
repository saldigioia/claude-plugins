#!/usr/bin/env bash
# PostToolUse CSS lint hook — called from hooks/hooks.json.
#
# The hook command in hooks/hooks.json extracts the file_path from the
# PostToolUse JSON payload on stdin via jq and passes it to this script as
# the first positional argument. See plugins.md canonical pattern.
#
# Exits silently on:
#   - Missing argument
#   - Non-.css file
#   - File that does not exist (e.g. deleted, moved)
#
# Lints .css files for:
#   1. Physical properties (width/height/margin-left etc.)
#   2. Layout media queries (@media min-width/max-width)
#   3. Arbitrary pixel values outside var() context

set -uo pipefail

FILE="${1:-}"
[ -z "$FILE" ] && exit 0

# Only lint CSS files — silent on everything else
case "$FILE" in
  *.css) ;;
  *) exit 0 ;;
esac

[ -f "$FILE" ] || exit 0

# 1. Physical properties — logical equivalents exist for all of these
grep -nE '(^|[{;[:space:]])(width|height|min-width|max-width|min-height|max-height|margin-left|margin-right|margin-top|margin-bottom|padding-left|padding-right|padding-top|padding-bottom|border-left|border-right|border-top|border-bottom)\s*:' "$FILE" 2>/dev/null \
  | grep -vE '(translate|transform|[Ss][Vv][Gg]|img\[|video\[)' \
  | head -5 \
  | while IFS= read -r line; do
      echo "PHYSICAL PROPERTY: $line — use logical equivalent (inline-size/block-size/margin-inline/etc.)"
    done || true

# 2. Layout media queries — prefer intrinsic primitives
grep -nE '@media.*\b(min-width|max-width)\b' "$FILE" 2>/dev/null \
  | head -3 \
  | while IFS= read -r line; do
      echo "LAYOUT MEDIA QUERY: $line — prefer intrinsic layout (Grid/Switcher/Sidebar)"
    done || true

# 3. Arbitrary pixel values — should come from the modular scale
grep -nE '[0-9]{2,}px' "$FILE" 2>/dev/null \
  | grep -vE '(var\(--|/\*|^\s*//|border-radius|content:)' \
  | head -3 \
  | while IFS= read -r line; do
      echo "ARBITRARY PX VALUE: $line — use modular scale token (--s-5 through --s5)"
    done || true

exit 0

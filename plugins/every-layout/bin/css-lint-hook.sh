#!/usr/bin/env bash
# PostToolUse CSS lint hook — called from hooks/hooks.json.
#
# The hook command in hooks/hooks.json extracts the file_path from the
# PostToolUse JSON payload on stdin via jq and passes it to this script as
# the first positional argument. See plugins.md canonical pattern.
#
# Exits silently on:
#   - Missing argument
#   - Unsupported extension
#   - File that does not exist (e.g. deleted, moved)
#
# Lints .css files for:
#   1. Physical properties (width/height/margin-left etc.)
#   2. Layout media queries (@media min-width/max-width)
#   3. Arbitrary pixel values outside var() context
#
# Lints framework templates (.astro/.tsx/.jsx/.vue/.svelte) for:
#   4. Bespoke declarations inside style="..." attributes.
#      Only primitive-parameter custom properties are allowed inline;
#      everything else emits ELA_002.

set -uo pipefail

FILE="${1:-}"
[ -z "$FILE" ] && exit 0
[ -f "$FILE" ] || exit 0

case "$FILE" in
  *.css)
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
    ;;

  *.astro|*.tsx|*.jsx|*.vue|*.svelte)
    # 4. Inline style="..." scan. Primitive-parameter custom properties are the
    #    only declarations legitimately carried on a template element (they
    #    parameterize ELC_STACK, ELC_SIDEBAR, ELC_SWITCHER, ELC_COVER,
    #    ELC_CLUSTER, ELC_FRAME, ELC_IMPOSTER, ELC_GRID, ELC_CENTER,
    #    ELC_CONTAINER, ELC_BOX, ELC_REEL, ELC_ICON). Everything else is
    #    bespoke CSS outside @layer — ELA_002.
    awk '
      BEGIN {
        split("--space --threshold --min --max --sidebar-min --ratio --measure --min-height --gutter --with-sidebar", a, " ")
        for (i in a) allowed[a[i]] = 1
        violations = 0
      }
      {
        line = $0
        # Find each style="..." attribute on the line; support single or double
        # quotes but do not attempt to parse JSX style={{...}} object syntax
        # (that is not a literal declaration string).
        while (match(line, /style[[:space:]]*=[[:space:]]*"[^"]*"/) > 0 || match(line, /style[[:space:]]*=[[:space:]]*'"'"'[^'"'"']*'"'"'/) > 0) {
          attr = substr(line, RSTART, RLENGTH)
          # Extract the quoted content.
          q1 = index(attr, "\"")
          if (q1 == 0) q1 = index(attr, "'"'"'")
          content = substr(attr, q1 + 1, length(attr) - q1 - 1)

          n = split(content, decls, ";")
          for (i = 1; i <= n; i++) {
            decl = decls[i]
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", decl)
            if (decl == "") continue
            colon = index(decl, ":")
            if (colon == 0) continue
            prop = substr(decl, 1, colon - 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", prop)
            if (!(prop in allowed)) {
              snippet = decl
              if (length(snippet) > 80) snippet = substr(snippet, 1, 80)
              printf "[ELA_002] %s:%d\n    %s\n    Bespoke inline style in template — move to @layer components or use a primitive-parameter custom property (--space, --threshold, --min, --max, --sidebar-min, --ratio, --measure, --min-height, --gutter, --with-sidebar)\n", FILENAME, NR, snippet
              violations++
            }
          }
          line = substr(line, RSTART + RLENGTH)
        }
      }
      END {
        if (violations > 0) exit 1
      }
    ' "$FILE" || true
    ;;

  *) exit 0 ;;
esac

exit 0

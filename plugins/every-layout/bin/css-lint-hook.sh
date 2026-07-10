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
#   4. Bare 1fr grid tracks (hidden auto floor, ELP_033)
#   5. Infinite animations without a /* motion: status */ marker — infinite
#      iteration is allowed only for status/progress indication
#      (motion-allowlist.md); decorative infinite motion is a violation even
#      under prefers-reduced-motion: no-preference.
#   6. Content-tier typographic permissions (word-break/overflow-wrap/
#      hyphens) granted at body/:root/*/heading scope (ELP_034; shared
#      scanner in bin/lib/typo-scope.sh — the hard version lives in
#      css-strict.sh).
#
# Lints framework templates (.astro/.tsx/.jsx/.vue/.svelte) for:
#   7. Bespoke declarations inside style="..." attributes.
#      Only primitive-parameter custom properties are allowed inline;
#      everything else emits ELA_002.

set -uo pipefail

# Shared primitive-parameter allowlist (also used by css-strict.sh and
# ports-lint.sh) — the single place inline-styleable custom properties live.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/primitive-params.sh
. "$SCRIPT_DIR/lib/primitive-params.sh"
# shellcheck source=lib/typo-scope.sh
. "$SCRIPT_DIR/lib/typo-scope.sh"

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

    # 4. Bare 1fr tracks — hidden minmax(auto, 1fr) floor clips at narrow widths (ELP_033)
    grep -nE 'grid-template[a-z-]*\s*:[^;]*1fr' "$FILE" 2>/dev/null \
      | grep -v 'minmax(' \
      | head -3 \
      | while IFS= read -r line; do
          echo "BARE 1fr TRACK: $line — bare 1fr is minmax(auto, 1fr); use minmax(0, 1fr) or a definite minimum (ELP_033)"
        done || true

    # 5. Infinite animations — allowed only for status/progress indication.
    #    Whitelist: a /* motion: status */ marker on the same or the
    #    immediately preceding line. (Warn-tier; a project keeping one
    #    deliberately registers the escape or carries the marker.)
    awk '
      BEGIN { prev = "" }
      {
        if ($0 ~ /animation[^;]*infinite/ \
            && $0 !~ /motion:[[:space:]]*status/ \
            && prev !~ /motion:[[:space:]]*status/) {
          printf "INFINITE ANIMATION: %d: %s — infinite iteration is allowed only for status/progress indication; mark it /* motion: status */ or make it single-run (motion-allowlist.md, ELP_028)\n", NR, substr($0, 1, 100)
          n++
        }
        prev = $0
        if (n >= 3) exit
      }
    ' "$FILE" 2>/dev/null || true

    # 6. Typographic permissions at global/heading scope (ELP_034) — the
    #    shared scanner; css-strict.sh fails these, the hook warns.
    typo_scope_scan "$FILE" \
      | head -5 \
      | while IFS="$(printf '\t')" read -r lineno sel decl; do
          [ -z "$lineno" ] && continue
          echo "GLOBAL TYPO PERMISSION: $lineno: $sel { $decl } — word-break/overflow-wrap/hyphens are content-tier grants; scope them to the content container, never body/:root/*/headings (ELP_034)"
        done || true
    ;;

  *.astro|*.tsx|*.jsx|*.vue|*.svelte)
    # 7. Inline style="..." scan. Primitive-parameter custom properties are the
    #    only declarations legitimately carried on a template element (they
    #    parameterize ELC_STACK, ELC_SIDEBAR, ELC_SWITCHER, ELC_COVER,
    #    ELC_CLUSTER, ELC_FRAME, ELC_IMPOSTER, ELC_GRID, ELC_CENTER,
    #    ELC_CONTAINER, ELC_BOX, ELC_REEL, ELC_ICON). Everything else is
    #    bespoke CSS outside @layer — ELA_002.
    awk -v allowed_list="$PRIMITIVE_PARAMS" '
      BEGIN {
        n = split(allowed_list, a, " ")
        for (i = 1; i <= n; i++) allowed[a[i]] = 1
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
              printf "[ELA_002] %s:%d\n    %s\n    Bespoke inline style in template — move to @layer components or use a primitive-parameter custom property (see bin/lib/primitive-params.sh)\n", FILENAME, NR, snippet
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

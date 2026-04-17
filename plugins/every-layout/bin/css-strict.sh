#!/usr/bin/env bash
# css-strict.sh — strict axiom gate. Exits non-zero on any violation.
#
# This is NOT a scorer. It is a CI-grade pass/fail check against the six
# axioms in skills/css-layout-engine/references/axioms.md. A team that adopts
# this plugin adopts the axioms as a contract; this script enforces the
# contract at the file level.
#
# Usage:
#   bin/css-strict.sh [directory]             # strict mode (default)
#   bin/css-strict.sh --archival [directory]  # adds ELA_006 checks
#
# Exit codes:
#   0 — all axioms satisfied
#   1 — one or more violations
#   2 — invocation error (missing args, unreadable file)

set -uo pipefail

ARCHIVAL=0
DIR="."
while [ $# -gt 0 ]; do
  case "$1" in
    --archival) ARCHIVAL=1; shift ;;
    --help|-h)
      grep -E '^# ' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) DIR="$1"; shift ;;
  esac
done

[ -d "$DIR" ] || { echo "error: $DIR is not a directory" >&2; exit 2; }

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

VIOLATIONS=0
FILES_CHECKED=0

# Axiom check helpers -----------------------------------------------------

fail() {
  local axiom="$1" file="$2" line="$3" snippet="$4" reason="$5"
  VIOLATIONS=$((VIOLATIONS + 1))
  printf "${RED}[%s]${NC} %s:%s\n    %s\n    %s\n" \
    "$axiom" "$file" "$line" "$snippet" "$reason"
}

check_file() {
  local file="$1"
  FILES_CHECKED=$((FILES_CHECKED + 1))

  # Find line ranges inside `@media (prefers-reduced-motion: reduce) { ... }` blocks;
  # the canonical WCAG reset uses !important there — whitelist those lines.
  local reduced_motion_lines=""
  reduced_motion_lines=$(awk '
    /@media[^{]*prefers-reduced-motion:\s*reduce/ { in_block=1; depth=0 }
    in_block && /\{/ { depth++ }
    in_block && /\}/ { depth--; if (depth==0) { in_block=0; next } }
    in_block { print NR }
  ' "$file" 2>/dev/null)

  is_whitelisted_line() {
    local n="$1"
    [ -z "$reduced_motion_lines" ] && return 1
    printf '%s\n' "$reduced_motion_lines" | grep -qx "$n"
  }

  # ELA_001 — no layout @media queries
  while IFS=: read -r lineno rest; do
    [ -z "$lineno" ] && continue
    fail "ELA_001" "$file" "$lineno" "$rest" "Layout @media query — use intrinsic primitive (Grid/Switcher/Sidebar)"
    VIOLATIONS=$((VIOLATIONS + 1))
  done < <(grep -nE '@media[^{]*\b(min-width|max-width|min-height|max-height)\b[^{]*\{[^}]*(grid-template|flex-direction|display:|width:|flex-basis)' "$file" 2>/dev/null | head -5)

  # ELA_002 — physical properties (excluding icon-style cap/em on width/height)
  while IFS=: read -r lineno rest; do
    [ -z "$lineno" ] && continue
    # Whitelist: width/height with em/cap unit on icon-sized values (ELP_024 icon pattern)
    if printf '%s' "$rest" | grep -qE '(width|height)\s*:\s*(0?\.[0-9]+|1)\s*(cap|em|ex)\s*;'; then
      continue
    fi
    fail "ELA_002" "$file" "$lineno" "$(printf '%s' "$rest" | head -c 80)" "Physical property — use logical equivalent"
    VIOLATIONS=$((VIOLATIONS + 1))
  done < <(grep -nE '(^|[{;[:space:]])(width|height|min-width|max-width|min-height|max-height|margin-left|margin-right|margin-top|margin-bottom|padding-left|padding-right|padding-top|padding-bottom|left|right|top|bottom)\s*:' "$file" 2>/dev/null \
    | grep -vE '(translate|transform|inset-|max-inline-size|max-block-size|min-inline-size|min-block-size|block-size|inline-size|[Ss][Vv][Gg]|img\[|video\[)' \
    | head -5)

  # ELA_002 — arbitrary pixel values (10+ px, outside accepted contexts).
  # Strip C-style comments first so px values inside /* ... */ don't false-positive.
  # Exclude lines that look like shadow-offset continuations (leading digits).
  while IFS=: read -r lineno rest; do
    [ -z "$lineno" ] && continue
    # Skip shadow-offset continuation lines: `  0 4px 12px ...` after a `box-shadow:` / `text-shadow:` / `filter:`
    if printf '%s' "$rest" | grep -qE '^\s*[0-9]+\s+[0-9]+'; then continue; fi
    # Skip comment continuation lines
    if printf '%s' "$rest" | grep -qE '^\s*\*'; then continue; fi
    fail "ELA_002" "$file" "$lineno" "$(printf '%s' "$rest" | head -c 80)" "Arbitrary pixel value — use modular scale (--s-5..--s5) or ch/cap/em"
    VIOLATIONS=$((VIOLATIONS + 1))
  done < <(awk '
      BEGIN { in_comment = 0 }
      {
        line = $0
        while (1) {
          if (in_comment) {
            idx = index(line, "*/")
            if (idx == 0) { line = ""; break }
            line = substr(line, idx + 2)
            in_comment = 0
          } else {
            idx = index(line, "/*")
            if (idx == 0) break
            end_idx = index(line, "*/")
            if (end_idx > idx) {
              line = substr(line, 1, idx - 1) substr(line, end_idx + 2)
            } else {
              line = substr(line, 1, idx - 1)
              in_comment = 1
              break
            }
          }
        }
        print NR ":" line
      }
    ' "$file" 2>/dev/null \
    | grep -E '[0-9]{2,}px' \
    | grep -vE '(var\(--|^\s*//|border-radius:|content:|box-shadow|text-shadow|outline:|filter:)' \
    | head -5)

  # ELA_003 — !important (excluding canonical prefers-reduced-motion: reduce resets)
  while IFS=: read -r lineno rest; do
    [ -z "$lineno" ] && continue
    if is_whitelisted_line "$lineno"; then continue; fi
    fail "ELA_003" "$file" "$lineno" "$(printf '%s' "$rest" | head -c 80)" "!important — use layer order for overrides, not specificity escalation"
    VIOLATIONS=$((VIOLATIONS + 1))
  done < <(grep -nE '!important' "$file" 2>/dev/null | head -5)

  # ELA_003 — ID selectors
  while IFS=: read -r lineno rest; do
    [ -z "$lineno" ] && continue
    fail "ELA_003" "$file" "$lineno" "$(printf '%s' "$rest" | head -c 80)" "ID selector — 0-2-0 specificity cap. Use class or attribute."
    VIOLATIONS=$((VIOLATIONS + 1))
  done < <(grep -nE '^\s*#[a-zA-Z][a-zA-Z0-9_-]*\s*[{,]' "$file" 2>/dev/null | head -5)

  # ELA_004 — arbitrary numeric spacing (rem/em outside scale)
  while IFS=: read -r lineno rest; do
    [ -z "$lineno" ] && continue
    fail "ELA_004" "$file" "$lineno" "$(printf '%s' "$rest" | head -c 80)" "Non-scale rem/em value — use --s-5..--s5 tokens"
    VIOLATIONS=$((VIOLATIONS + 1))
  done < <(grep -nE '(margin|padding|gap)(-[a-z]+)?\s*:\s*[0-9]+\.?[0-9]*(rem|em)' "$file" 2>/dev/null \
    | grep -vE '(var\(--|/\*|0\.132rem|0\.198rem|0\.296rem|0\.444rem|0\.667rem|1rem|1\.5rem|2\.25rem|3\.375rem|5\.063rem|7\.594rem|0\.5em|1em|1\.5em|0\.25em)' \
    | head -5)

  # ELA_006 — archival durability (opt-in)
  if [ "$ARCHIVAL" -eq 1 ]; then
    while IFS=: read -r lineno rest; do
      [ -z "$lineno" ] && continue
      fail "ELA_006" "$file" "$lineno" "$rest" "content-visibility: auto can hide primary content if script fails"
      VIOLATIONS=$((VIOLATIONS + 1))
    done < <(grep -nE '^\s*content-visibility\s*:\s*auto' "$file" 2>/dev/null | head -3)

    while IFS=: read -r lineno rest; do
      [ -z "$lineno" ] && continue
      fail "ELA_006" "$file" "$lineno" "$(printf '%s' "$rest" | head -c 80)" "CSS nesting depth > 2 — flatten for archival durability"
      VIOLATIONS=$((VIOLATIONS + 1))
    done < <(awk '/\{/ { d++ } /\}/ { d-- } d > 3 { print NR ":" $0 }' "$file" | head -3)
  fi
}

# Main --------------------------------------------------------------------

printf "${BOLD}css-strict.sh — axiom gate${NC}\n"
printf "Directory: %s\n" "$DIR"
[ "$ARCHIVAL" -eq 1 ] && printf "Mode:      %sarchival (ELA_006 enabled)%s\n" "$YELLOW" "$NC"
echo "---"

CSS_FILES=$(find "$DIR" -type f -name "*.css" \
  -not -path "*/node_modules/*" \
  -not -path "*/.astro/*" \
  -not -path "*/dist/*" \
  -not -path "*/.git/*" 2>/dev/null) || true

if [ -z "$CSS_FILES" ]; then
  printf "${YELLOW}No CSS files found in %s${NC}\n" "$DIR"
  exit 0
fi

while IFS= read -r file; do
  [ -n "$file" ] && check_file "$file"
done <<< "$CSS_FILES"

echo "---"
if [ "$VIOLATIONS" -eq 0 ]; then
  printf "${GREEN}${BOLD}PASS${NC} — %d file(s) checked; axioms satisfied.\n" "$FILES_CHECKED"
  exit 0
else
  printf "${RED}${BOLD}FAIL${NC} — %d violation(s) across %d file(s). Axioms are contract, not suggestion.\n" \
    "$VIOLATIONS" "$FILES_CHECKED"
  printf "\nCanonical axioms: skills/css-layout-engine/references/axioms.md\n"
  printf "Escape-hatch registry: escapes.md (root of project)\n"
  exit 1
fi

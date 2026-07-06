#!/usr/bin/env bash
# css-strict.sh — strict axiom gate. Exits non-zero on any violation.
#
# This is NOT a scorer. It is a CI-grade pass/fail check against the six
# axioms in skills/css-layout-engine/references/axioms.md. A team that adopts
# this plugin adopts the axioms as a contract; this script enforces the
# contract at the file level.
#
# Usage:
#   bin/css-strict.sh [directory|file]             # strict mode (default)
#   bin/css-strict.sh --archival [directory|file]  # adds ELA_006 checks
#
# Scanned file types:
#   *.css           — full check suite
#   *.html, *.astro — <style> block contents (line numbers preserved) plus
#                     inline style="..." attributes (only primitive-parameter
#                     custom properties are allowed inline; see
#                     bin/lib/primitive-params.sh)
# A single file of any scanned type may be passed for targeted testing.
#
# Checks (each escape-aware via escapes.md):
#   ELA_001 — viewport @media blocks (multi-line aware) containing layout
#             properties (grid-template*, flex-direction, flex-basis,
#             display:, width:)
#   ELA_002 — physical properties (icon em/cap width/height whitelisted);
#             arbitrary 2+ digit px values (comments stripped first);
#             bespoke inline style="" declarations in .html/.astro
#   ELA_003 — !important (canonical prefers-reduced-motion reset whitelisted);
#             ID selectors; compound/complex selectors exceeding the 0-2-0
#             specificity cap (functional pseudo-classes :not/:is/:where/:has
#             and their arguments are NOT counted — the cap targets
#             class-chaining escalation, not spec-exact specificity)
#   ELA_004 — margin/padding/gap rem/em values outside the modular scale
#   ELA_006 — (--archival only) content-visibility:auto on content;
#             brace-nesting depth > 3; @supports not (...) gating
#
# Exit codes:
#   0 — all axioms satisfied
#   1 — one or more violations
#   2 — invocation error (missing args, unreadable file)

set -uo pipefail

# Escape-hatch registry: a registered, unexpired escape suppresses the matching
# violation; an expired or unregistered one still fails the gate.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/escapes.sh
. "$SCRIPT_DIR/lib/escapes.sh"
# shellcheck source=lib/primitive-params.sh
. "$SCRIPT_DIR/lib/primitive-params.sh"

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

if [ -f "$DIR" ]; then
  case "$DIR" in
    *.css|*.html|*.astro) ;;
    *) echo "error: $DIR is not a .css/.html/.astro file" >&2; exit 2 ;;
  esac
elif [ ! -d "$DIR" ]; then
  echo "error: $DIR is not a scannable file or directory" >&2; exit 2
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

VIOLATIONS=0
SUPPRESSED=0
FILES_CHECKED=0

STYLE_TMP="$(mktemp "${TMPDIR:-/tmp}/css-strict.XXXXXX")"
trap 'rm -f "$STYLE_TMP"' EXIT

# Axiom check helpers -----------------------------------------------------

# fail — record (or suppress) one axiom violation. This is the SOLE place
# VIOLATIONS is incremented, so escape suppression accounting stays correct:
#   - a registered, unexpired escape suppresses it (no count, yellow note);
#   - an expired escape still counts and is flagged as expired;
#   - an unregistered violation counts as normal.
fail() {
  local axiom="$1" file="$2" line="$3" snippet="$4" reason="$5"
  local status esc rest
  status="$(escapes_lookup "$file" "$axiom" "$line")"
  case "$status" in
    "suppressed "*)
      esc="${status#suppressed }"
      SUPPRESSED=$((SUPPRESSED + 1))
      printf "${YELLOW}[%s]${NC} %s:%s — suppressed by %s\n" \
        "$axiom" "$file" "$line" "$esc"
      ;;
    "expired "*)
      rest="${status#expired }"
      VIOLATIONS=$((VIOLATIONS + 1))
      printf "${RED}[%s]${NC} %s:%s\n    %s\n    escape expired (%s) — renew the escapes.md entry or fix the violation\n" \
        "$axiom" "$file" "$line" "$snippet" "$rest"
      ;;
    *)
      VIOLATIONS=$((VIOLATIONS + 1))
      printf "${RED}[%s]${NC} %s:%s\n    %s\n    %s\n" \
        "$axiom" "$file" "$line" "$snippet" "$reason"
      ;;
  esac
}

# check_css_content <readable-css-file> <report-name>
# Runs every CSS-level axiom check on <readable-css-file>, reporting
# violations against <report-name>. For plain .css files both are the same
# path; for .html/.astro the first is a line-number-preserving extraction of
# the <style> blocks and the second is the original file.
check_css_content() {
  local file="$1" rname="$2"

  # Find line ranges inside `@media (prefers-reduced-motion: reduce) { ... }` blocks;
  # the canonical WCAG reset uses !important there — whitelist those lines.
  local reduced_motion_lines=""
  reduced_motion_lines=$(awk '
    /@media[^{]*prefers-reduced-motion:[[:space:]]*reduce/ { in_block=1; depth=0 }
    in_block && /\{/ { depth++ }
    in_block && /\}/ { depth--; if (depth==0) { in_block=0; next } }
    in_block { print NR }
  ' "$file" 2>/dev/null)

  is_whitelisted_line() {
    local n="$1"
    [ -z "$reduced_motion_lines" ] && return 1
    printf '%s\n' "$reduced_motion_lines" | grep -qx "$n"
  }

  # ELA_001 — no layout @media queries. Block-aware: a viewport @media opens a
  # scan window that lasts until its closing brace, so multi-line blocks are
  # caught, not just single-line ones.
  while IFS=: read -r lineno rest; do
    [ -z "$lineno" ] && continue
    fail "ELA_001" "$rname" "$lineno" "$(printf '%s' "$rest" | head -c 80)" "Layout @media query — use intrinsic primitive (Grid/Switcher/Sidebar)"
  done < <(awk '
    BEGIN { in_mq = 0; depth = 0; opened = 0 }
    {
      if (in_mq == 0) {
        if ($0 ~ /@media/ && $0 ~ /(min-width|max-width|min-height|max-height)/) {
          in_mq = 1; depth = 0; opened = 0
        } else next
      }
      if ($0 ~ /(grid-template|flex-direction|flex-basis|display[[:space:]]*:)/ ||
          $0 ~ /(^|[^-A-Za-z])width[[:space:]]*:/) {
        print NR ":" $0
      }
      o = gsub(/\{/, "{"); c = gsub(/\}/, "}")
      if (o > 0) opened = 1
      depth += o - c
      if (opened == 1 && depth <= 0) { in_mq = 0 }
    }
  ' "$file" 2>/dev/null | head -5)

  # ELA_002 — physical properties (excluding icon-style cap/em on width/height)
  while IFS=: read -r lineno rest; do
    [ -z "$lineno" ] && continue
    # Whitelist: width/height with em/cap unit on icon-sized values (ELP_024 icon pattern)
    if printf '%s' "$rest" | grep -qE '(width|height)\s*:\s*(0?\.[0-9]+|1)\s*(cap|em|ex)\s*;'; then
      continue
    fi
    fail "ELA_002" "$rname" "$lineno" "$(printf '%s' "$rest" | head -c 80)" "Physical property — use logical equivalent"
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
    fail "ELA_002" "$rname" "$lineno" "$(printf '%s' "$rest" | head -c 80)" "Arbitrary pixel value — use modular scale (--s-5..--s5) or ch/cap/em"
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
    | grep -vE '(var\(--|^\s*//|border-radius:|content:|box-shadow|text-shadow|outline:|filter:|@media)' \
    | head -5)

  # ELA_003 — !important (excluding canonical prefers-reduced-motion: reduce resets)
  while IFS=: read -r lineno rest; do
    [ -z "$lineno" ] && continue
    if is_whitelisted_line "$lineno"; then continue; fi
    fail "ELA_003" "$rname" "$lineno" "$(printf '%s' "$rest" | head -c 80)" "!important — use layer order for overrides, not specificity escalation"
  done < <(grep -nE '!important' "$file" 2>/dev/null | head -5)

  # ELA_003 — ID selectors
  while IFS=: read -r lineno rest; do
    [ -z "$lineno" ] && continue
    fail "ELA_003" "$rname" "$lineno" "$(printf '%s' "$rest" | head -c 80)" "ID selector — 0-2-0 specificity cap. Use class or attribute."
  done < <(grep -nE '^\s*#[a-zA-Z][a-zA-Z0-9_-]*\s*[{,]' "$file" 2>/dev/null | head -5)

  # ELA_003 — 0-2-0 specificity cap. Counts classes + attributes +
  # pseudo-classes per complex selector (selector lists split on commas).
  # Deliberate approximation, documented in axioms.md: pseudo-elements,
  # legacy single-colon element pseudos, and the functional wrappers
  # :not/:is/:where/:has INCLUDING their arguments are not counted — the cap
  # exists to block class-chaining escalation (`.a .b .c`), and the canonical
  # primitives (e.g. Cover's `:first-child:not(.principal)`) stay legal.
  # v1 scans selectors on the line that contains their `{`.
  while IFS=: read -r lineno rest; do
    [ -z "$lineno" ] && continue
    fail "ELA_003" "$rname" "$lineno" "$(printf '%s' "$rest" | head -c 100)" "Selector exceeds the 0-2-0 specificity cap — reduce chained classes/attributes/pseudo-classes"
  done < <(awk '
    {
      line = $0
      p = index(line, "{")
      if (p == 0) next
      sel = substr(line, 1, p - 1)
      gsub(/\/\*[^*]*\*\//, "", sel)
      if (sel ~ /\/\*/ || sel ~ /\*\//) next
      gsub(/^[[:space:]]+/, "", sel); gsub(/[[:space:]]+$/, "", sel)
      if (sel == "" || sel ~ /^@/) next
      if (sel ~ /^[0-9]+%/ || sel == "from" || sel == "to") next
      n = split(sel, parts, ",")
      for (i = 1; i <= n; i++) {
        s = parts[i]
        # Strip functional-wrapper arguments FIRST so attribute selectors
        # inside :not(...)/:is(...) do not count toward the cap.
        while (gsub(/\([^()]*\)/, "", s) > 0) { dummy = 1 }
        attrs = gsub(/\[[^\]]*\]/, "", s)
        gsub(/::[A-Za-z-]+/, "", s)
        gsub(/:(before|after|first-line|first-letter)/, "", s)
        gsub(/:(not|is|where|has)/, "", s)
        pseudo = gsub(/:[A-Za-z][A-Za-z-]*/, "", s)
        classes = gsub(/\.[A-Za-z_-]/, "", s)
        total = classes + attrs + pseudo
        if (total > 2) {
          gsub(/^[[:space:]]+/, "", parts[i]); gsub(/[[:space:]]+$/, "", parts[i])
          print NR ":" parts[i] " — specificity 0-" total "-0"
          break
        }
      }
    }
  ' "$file" 2>/dev/null | head -5)

  # ELA_004 — arbitrary numeric spacing (rem/em outside scale)
  while IFS=: read -r lineno rest; do
    [ -z "$lineno" ] && continue
    fail "ELA_004" "$rname" "$lineno" "$(printf '%s' "$rest" | head -c 80)" "Non-scale rem/em value — use --s-5..--s5 tokens"
  done < <(grep -nE '(margin|padding|gap)(-[a-z]+)?\s*:\s*[0-9]+\.?[0-9]*(rem|em)' "$file" 2>/dev/null \
    | grep -vE '(var\(--|/\*|0\.132rem|0\.198rem|0\.296rem|0\.444rem|0\.667rem|1rem|1\.5rem|2\.25rem|3\.375rem|5\.063rem|7\.594rem|0\.5em|1em|1\.5em|0\.25em)' \
    | head -5)

  # ELA_006 — archival durability (opt-in)
  if [ "$ARCHIVAL" -eq 1 ]; then
    while IFS=: read -r lineno rest; do
      [ -z "$lineno" ] && continue
      fail "ELA_006" "$rname" "$lineno" "$rest" "content-visibility: auto can hide primary content if script fails"
    done < <(grep -nE '^\s*content-visibility\s*:\s*auto' "$file" 2>/dev/null | head -3)

    # Brace-nesting depth: flag any line whose opening brace(s) push depth
    # past 3 (rule inside @media inside @layer is depth 3; deeper than that
    # is CSS nesting the archival profile forbids). All braces on a line are
    # counted; depth never goes negative.
    while IFS=: read -r lineno rest; do
      [ -z "$lineno" ] && continue
      fail "ELA_006" "$rname" "$lineno" "$(printf '%s' "$rest" | head -c 80)" "CSS nesting depth > 2 — flatten for archival durability"
    done < <(awk '
      BEGIN { d = 0 }
      {
        o = gsub(/\{/, "{")
        if (o > 0 && d + o > 3) print NR ":" $0
        d += o
        c = gsub(/\}/, "}")
        d -= c
        if (d < 0) d = 0
      }
    ' "$file" 2>/dev/null | head -3)

    # @supports not (...) — gating a "must work" feature behind a negative
    # support query means the base experience differs by browser era.
    while IFS=: read -r lineno rest; do
      [ -z "$lineno" ] && continue
      fail "ELA_006" "$rname" "$lineno" "$(printf '%s' "$rest" | head -c 80)" "@supports not (...) — provide the base experience unconditionally; enhance additively"
    done < <(grep -nE '@supports[^{]*\bnot[[:space:]]*\(' "$file" 2>/dev/null | head -3)
  fi
}

# check_inline_attrs <file> — scan .html/.astro inline style="..." attributes.
# Only primitive-parameter custom properties (bin/lib/primitive-params.sh) may
# be carried inline; every other declaration is bespoke CSS outside @layer.
check_inline_attrs() {
  local file="$1"
  local lineno decl
  while IFS="$(printf '\t')" read -r lineno decl; do
    [ -z "$lineno" ] && continue
    fail "ELA_002" "$file" "$lineno" "$(printf '%s' "$decl" | head -c 80)" "Bespoke inline style in template — move to @layer components or pass a primitive-parameter custom property"
  done < <(awk -v allowed_list="$PRIMITIVE_PARAMS" '
    BEGIN {
      n = split(allowed_list, a, " ")
      for (i = 1; i <= n; i++) allowed[a[i]] = 1
    }
    {
      line = $0
      while (match(line, /style[[:space:]]*=[[:space:]]*"[^"]*"/) || match(line, /style[[:space:]]*=[[:space:]]*'\''[^'\'']*'\''/)) {
        attr = substr(line, RSTART, RLENGTH)
        q1 = index(attr, "\"")
        if (q1 == 0) q1 = index(attr, "'\''")
        content = substr(attr, q1 + 1, length(attr) - q1 - 1)
        m = split(content, decls, ";")
        for (i = 1; i <= m; i++) {
          decl = decls[i]
          gsub(/^[[:space:]]+/, "", decl); gsub(/[[:space:]]+$/, "", decl)
          if (decl == "") continue
          colon = index(decl, ":")
          if (colon == 0) continue
          prop = substr(decl, 1, colon - 1)
          gsub(/^[[:space:]]+/, "", prop); gsub(/[[:space:]]+$/, "", prop)
          if (!(prop in allowed)) printf "%d\t%s\n", NR, decl
        }
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$file" 2>/dev/null | head -10)
}

# extract_style_blocks <file> — write the contents of every <style ...> block
# to $STYLE_TMP, one output line per input line (non-CSS lines become blank),
# so violation line numbers match the source file.
extract_style_blocks() {
  local file="$1"
  awk '
    BEGIN { in_style = 0 }
    {
      if (in_style == 0) {
        if (match($0, /<style[^>]*>/)) {
          rest = substr($0, RSTART + RLENGTH)
          e = index(rest, "</style>")
          if (e > 0) { print substr(rest, 1, e - 1) }
          else { in_style = 1; print rest }
        } else print ""
      } else {
        e = index($0, "</style>")
        if (e > 0) { print substr($0, 1, e - 1); in_style = 0 }
        else print $0
      }
    }
  ' "$file" > "$STYLE_TMP" 2>/dev/null
}

check_file() {
  local file="$1"
  FILES_CHECKED=$((FILES_CHECKED + 1))
  case "$file" in
    *.css)
      check_css_content "$file" "$file"
      ;;
    *.html|*.astro)
      extract_style_blocks "$file"
      check_css_content "$STYLE_TMP" "$file"
      check_inline_attrs "$file"
      ;;
  esac
}

# Main --------------------------------------------------------------------

escapes_load "${ESCAPES_FILE:-escapes.md}"

printf "${BOLD}css-strict.sh — axiom gate${NC}\n"
printf "Directory: %s\n" "$DIR"
[ "$ARCHIVAL" -eq 1 ] && printf "Mode:      %sarchival (ELA_006 enabled)%s\n" "$YELLOW" "$NC"
if [ -n "$ESCAPES_FILE_USED" ]; then
  printf "Escapes:   %s\n" "$ESCAPES_FILE_USED"
fi
echo "---"

if [ -f "$DIR" ]; then
  CSS_FILES="$DIR"
else
  CSS_FILES=$(find "$DIR" -type f \( -name "*.css" -o -name "*.html" -o -name "*.astro" \) \
    -not -path "*/node_modules/*" \
    -not -path "*/.astro/*" \
    -not -path "*/dist/*" \
    -not -path "*/.git/*" 2>/dev/null) || true
fi

if [ -z "$CSS_FILES" ]; then
  printf "${YELLOW}No scannable files found in %s${NC}\n" "$DIR"
  exit 0
fi

while IFS= read -r file; do
  [ -n "$file" ] && check_file "$file"
done <<< "$CSS_FILES"

echo "---"
[ "$SUPPRESSED" -gt 0 ] && printf "${YELLOW}%d violation(s) suppressed by registered escapes.${NC}\n" "$SUPPRESSED"
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

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

# Treat a single-file target as a one-file scan.
SINGLE_FILE=""
if [ -f "$DIR" ]; then
  SINGLE_FILE="$DIR"
  DIR="$(dirname "$DIR")"
fi

[ -d "$DIR" ] || { echo "error: $DIR is not a directory or file" >&2; exit 2; }

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

VIOLATIONS=0
FILES_CHECKED=0
WHITELISTED_MOTION=0       # lines suppressed via @media (prefers-reduced-motion: reduce)
CONSUMED_ESCAPES=0         # violations suppressed via active escapes.md entries
CONSUMED_ESCAPE_NAMES=""   # space-separated, deduped at end
EXPIRED_ESCAPES=0          # violations still counted despite a registered (but expired) escape

# Escape-hatch registry loading ------------------------------------------
#
# Registry format (one entry per ## header). Example:
#
#   ## ESC_MOTION_RESET
#
#   - File(s): public/styles/motion.css
#   - Axiom violated: ELA_003
#   - Line(s): 14, 27            # optional — absent/empty means "all"
#   - Justification: WCAG 2.2 motion reset
#   - Expiry: 2026-10-01         # or `none`
#   - Reviewed: 2026-04-23 sal
#
# Parsed into pipe-delimited records: NAME|AXIOM|FILES|LINES|EXPIRY
# where LINES="all" when unspecified, and EXPIRY="none" for permanent escapes.

ESCAPES_DATA=""
ESCAPES_FILE=""

load_escapes() {
  local candidate="$1/escapes.md"
  if [ ! -f "$candidate" ]; then
    return 0
  fi
  ESCAPES_FILE="$candidate"
  ESCAPES_DATA=$(awk '
    function emit() {
      if (name != "" && axiom != "") {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", files)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", lines)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", expiry)
        if (lines == "") lines = "all"
        if (expiry == "") expiry = "none"
        print name "|" axiom "|" files "|" lines "|" expiry
      }
      name=""; axiom=""; files=""; lines=""; expiry=""
    }
    /^##[[:space:]]+ESC_[A-Z0-9_]+/ {
      emit()
      # capture header token that starts with ESC_
      for (i=1; i<=NF; i++) if ($i ~ /^ESC_[A-Z0-9_]+/) { name=$i; break }
      next
    }
    name != "" && /^[[:space:]]*-[[:space:]]*File\(s\)[[:space:]]*:/ {
      sub(/^[[:space:]]*-[[:space:]]*File\(s\)[[:space:]]*:[[:space:]]*/, "")
      files=$0
      next
    }
    name != "" && /^[[:space:]]*-[[:space:]]*Axiom[[:space:]]+violated[[:space:]]*:/ {
      if (match($0, /ELA_[0-9]+/)) axiom = substr($0, RSTART, RLENGTH)
      next
    }
    name != "" && /^[[:space:]]*-[[:space:]]*Line\(s\)[[:space:]]*:/ {
      sub(/^[[:space:]]*-[[:space:]]*Line\(s\)[[:space:]]*:[[:space:]]*/, "")
      # strip trailing comments ("— if present...")
      sub(/[[:space:]]*(—|--).*$/, "")
      out=""
      # collect digits and commas only
      for (i=1; i<=length($0); i++) {
        c = substr($0, i, 1)
        if (c ~ /[0-9,]/) out = out c
        else if (c == " " || c == "\t") continue
      }
      if (out != "") lines = out
      next
    }
    name != "" && /^[[:space:]]*-[[:space:]]*Expiry[[:space:]]*:/ {
      sub(/^[[:space:]]*-[[:space:]]*Expiry[[:space:]]*:[[:space:]]*/, "")
      if (match($0, /[0-9]{4}-[0-9]{2}-[0-9]{2}/)) {
        expiry = substr($0, RSTART, RLENGTH)
      } else if ($0 ~ /^[[:space:]]*none/) {
        expiry = "none"
      }
      next
    }
    END { emit() }
  ' "$candidate")
}

# Global slots set by check_escape() to avoid subshell roundtrips.
ESC_MATCH_NAME=""
ESC_MATCH_EXPIRED=0
ESC_MATCH_EXPIRY=""

# Returns 0 if an active OR expired escape matches (check ESC_MATCH_EXPIRED);
# returns 1 if no match.
check_escape() {
  local axiom="$1" file="$2" lineno="$3"
  ESC_MATCH_NAME=""
  ESC_MATCH_EXPIRED=0
  ESC_MATCH_EXPIRY=""
  [ -z "$ESCAPES_DATA" ] && return 1

  local today
  today="$(date +%Y-%m-%d)"

  local rec ename eaxiom efiles elines eexpiry
  while IFS='|' read -r ename eaxiom efiles elines eexpiry; do
    [ -z "$ename" ] && continue
    [ "$eaxiom" != "$axiom" ] && continue

    # File match: efiles is a comma-separated list of substring patterns.
    local matched_file=0 p
    local OLD_IFS="$IFS"
    IFS=','
    # shellcheck disable=SC2206
    local patterns=( $efiles )
    IFS="$OLD_IFS"
    local pt
    for pt in "${patterns[@]}"; do
      # trim
      pt="${pt#"${pt%%[![:space:]]*}"}"
      pt="${pt%"${pt##*[![:space:]]}"}"
      [ -z "$pt" ] && continue
      case "$file" in
        *"$pt"*) matched_file=1; break ;;
      esac
    done
    [ "$matched_file" -eq 0 ] && continue

    # Line match: "all" or comma-separated integers.
    if [ "$elines" != "all" ]; then
      local found=0 ln
      IFS=','
      # shellcheck disable=SC2206
      local linenums=( $elines )
      IFS="$OLD_IFS"
      for ln in "${linenums[@]}"; do
        ln="${ln//[[:space:]]/}"
        [ -z "$ln" ] && continue
        if [ "$ln" = "$lineno" ]; then found=1; break; fi
      done
      [ "$found" -eq 0 ] && continue
    fi

    ESC_MATCH_NAME="$ename"
    if [ "$eexpiry" = "none" ]; then
      return 0
    fi
    # lexical date compare works for YYYY-MM-DD
    if [[ "$eexpiry" < "$today" ]]; then
      ESC_MATCH_EXPIRED=1
      ESC_MATCH_EXPIRY="$eexpiry"
    fi
    return 0
  done <<< "$ESCAPES_DATA"

  return 1
}

# Axiom check helpers -----------------------------------------------------

fail() {
  local axiom="$1" file="$2" line="$3" snippet="$4" reason="$5"
  VIOLATIONS=$((VIOLATIONS + 1))
  printf "${RED}[%s]${NC} %s:%s\n    %s\n    %s\n" \
    "$axiom" "$file" "$line" "$snippet" "$reason"
}

# Apply escape-registry + motion-whitelist gates before calling fail().
# Returns 0 if the violation should be suppressed (caller should `continue`).
# Returns 1 if the caller should still report via fail().
suppress_or_report() {
  local axiom="$1" file="$2" lineno="$3" snippet="$4" reason="$5"

  if check_escape "$axiom" "$file" "$lineno"; then
    if [ "$ESC_MATCH_EXPIRED" -eq 1 ]; then
      EXPIRED_ESCAPES=$((EXPIRED_ESCAPES + 1))
      fail "$axiom" "$file" "$lineno" "$snippet" "$reason"
      printf "    ${YELLOW}Expired escape: %s (expired %s) — entry no longer honored${NC}\n" \
        "$ESC_MATCH_NAME" "$ESC_MATCH_EXPIRY"
      return 1
    fi
    CONSUMED_ESCAPES=$((CONSUMED_ESCAPES + 1))
    case " $CONSUMED_ESCAPE_NAMES " in
      *" $ESC_MATCH_NAME "*) ;;
      *) CONSUMED_ESCAPE_NAMES="$CONSUMED_ESCAPE_NAMES $ESC_MATCH_NAME" ;;
    esac
    return 0
  fi

  fail "$axiom" "$file" "$lineno" "$snippet" "$reason"
  return 1
}

check_file() {
  local file="$1"
  FILES_CHECKED=$((FILES_CHECKED + 1))

  # Find line ranges inside `@media (prefers-reduced-motion: reduce) { ... }` blocks;
  # the canonical WCAG reset uses !important there — whitelist those lines.
  # NOTE: awk does not support \s; use [[:space:]] so the whitelist actually populates.
  local reduced_motion_lines=""
  reduced_motion_lines=$(awk '
    /@media[^{]*prefers-reduced-motion:[[:space:]]*reduce/ { in_block=1; depth=0 }
    in_block && /\{/ { depth++ }
    in_block && /\}/ { depth--; if (depth==0) { in_block=0; next } }
    in_block { print NR }
  ' "$file" 2>/dev/null)

  is_reduced_motion_line() {
    local n="$1"
    [ -z "$reduced_motion_lines" ] && return 1
    printf '%s\n' "$reduced_motion_lines" | grep -qx "$n"
  }

  # ELA_001 — no layout @media queries
  while IFS=: read -r lineno rest; do
    [ -z "$lineno" ] && continue
    suppress_or_report "ELA_001" "$file" "$lineno" "$rest" \
      "Layout @media query — use intrinsic primitive (Grid/Switcher/Sidebar)" || true
  done < <(grep -nE '@media[^{]*\b(min-width|max-width|min-height|max-height)\b[^{]*\{[^}]*(grid-template|flex-direction|display:|width:|flex-basis)' "$file" 2>/dev/null | head -5)

  # ELA_002 — physical properties (excluding icon-style cap/em on width/height)
  while IFS=: read -r lineno rest; do
    [ -z "$lineno" ] && continue
    # Whitelist: width/height with em/cap unit on icon-sized values (ELP_024 icon pattern)
    if printf '%s' "$rest" | grep -qE '(width|height)\s*:\s*(0?\.[0-9]+|1)\s*(cap|em|ex)\s*;'; then
      continue
    fi
    suppress_or_report "ELA_002" "$file" "$lineno" "$(printf '%s' "$rest" | head -c 80)" \
      "Physical property — use logical equivalent" || true
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
    suppress_or_report "ELA_002" "$file" "$lineno" "$(printf '%s' "$rest" | head -c 80)" \
      "Arbitrary pixel value — use modular scale (--s-5..--s5) or ch/cap/em" || true
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
  local ela003_whitelisted=0
  while IFS=: read -r lineno rest; do
    [ -z "$lineno" ] && continue
    if is_reduced_motion_line "$lineno"; then
      ela003_whitelisted=$((ela003_whitelisted + 1))
      WHITELISTED_MOTION=$((WHITELISTED_MOTION + 1))
      continue
    fi
    suppress_or_report "ELA_003" "$file" "$lineno" "$(printf '%s' "$rest" | head -c 80)" \
      "!important — use layer order for overrides, not specificity escalation" || true
  done < <(grep -nE '!important' "$file" 2>/dev/null | head -5)
  if [ "$ela003_whitelisted" -gt 0 ]; then
    printf "    ${GREEN}ELA_003: %d line(s) whitelisted via @media (prefers-reduced-motion: reduce) in %s${NC}\n" \
      "$ela003_whitelisted" "$file"
  fi

  # ELA_003 — ID selectors
  while IFS=: read -r lineno rest; do
    [ -z "$lineno" ] && continue
    suppress_or_report "ELA_003" "$file" "$lineno" "$(printf '%s' "$rest" | head -c 80)" \
      "ID selector — 0-2-0 specificity cap. Use class or attribute." || true
  done < <(grep -nE '^\s*#[a-zA-Z][a-zA-Z0-9_-]*\s*[{,]' "$file" 2>/dev/null | head -5)

  # ELA_004 — arbitrary numeric spacing (rem/em outside scale)
  while IFS=: read -r lineno rest; do
    [ -z "$lineno" ] && continue
    suppress_or_report "ELA_004" "$file" "$lineno" "$(printf '%s' "$rest" | head -c 80)" \
      "Non-scale rem/em value — use --s-5..--s5 tokens" || true
  done < <(grep -nE '(margin|padding|gap)(-[a-z]+)?\s*:\s*[0-9]+\.?[0-9]*(rem|em)' "$file" 2>/dev/null \
    | grep -vE '(var\(--|/\*|0\.132rem|0\.198rem|0\.296rem|0\.444rem|0\.667rem|1rem|1\.5rem|2\.25rem|3\.375rem|5\.063rem|7\.594rem|0\.5em|1em|1\.5em|0\.25em)' \
    | head -5)

  # ELA_006 — archival durability (opt-in)
  if [ "$ARCHIVAL" -eq 1 ]; then
    while IFS=: read -r lineno rest; do
      [ -z "$lineno" ] && continue
      suppress_or_report "ELA_006" "$file" "$lineno" "$rest" \
        "content-visibility: auto can hide primary content if script fails" || true
    done < <(grep -nE '^\s*content-visibility\s*:\s*auto' "$file" 2>/dev/null | head -3)

    while IFS=: read -r lineno rest; do
      [ -z "$lineno" ] && continue
      suppress_or_report "ELA_006" "$file" "$lineno" "$(printf '%s' "$rest" | head -c 80)" \
        "CSS nesting depth > 2 — flatten for archival durability" || true
    done < <(awk '/\{/ { d++ } /\}/ { d-- } d > 3 { print NR ":" $0 }' "$file" | head -3)
  fi
}

# Main --------------------------------------------------------------------

printf "${BOLD}css-strict.sh — axiom gate${NC}\n"
if [ -n "$SINGLE_FILE" ]; then
  printf "Target:    %s\n" "$SINGLE_FILE"
else
  printf "Directory: %s\n" "$DIR"
fi
[ "$ARCHIVAL" -eq 1 ] && printf "Mode:      %sarchival (ELA_006 enabled)%s\n" "$YELLOW" "$NC"

load_escapes "$DIR"
if [ -n "$ESCAPES_FILE" ]; then
  printf "Escapes:   %s\n" "$ESCAPES_FILE"
fi
echo "---"

if [ -n "$SINGLE_FILE" ]; then
  CSS_FILES="$SINGLE_FILE"
else
  CSS_FILES=$(find "$DIR" -type f -name "*.css" \
    -not -path "*/node_modules/*" \
    -not -path "*/.astro/*" \
    -not -path "*/dist/*" \
    -not -path "*/.git/*" 2>/dev/null) || true
fi

if [ -z "$CSS_FILES" ]; then
  printf "${YELLOW}No CSS files found in %s${NC}\n" "$DIR"
  exit 0
fi

while IFS= read -r file; do
  [ -n "$file" ] && check_file "$file"
done <<< "$CSS_FILES"

echo "---"

# Summary diagnostics
if [ "$WHITELISTED_MOTION" -gt 0 ]; then
  printf "${GREEN}ELA_003: %d line(s) whitelisted via @media (prefers-reduced-motion: reduce)${NC}\n" \
    "$WHITELISTED_MOTION"
fi
if [ "$CONSUMED_ESCAPES" -gt 0 ]; then
  # trim leading space, then comma-separate dedup list
  esc_name_list="${CONSUMED_ESCAPE_NAMES# }"
  esc_name_list="${esc_name_list// /, }"
  printf "${GREEN}Registered escapes consumed: %d (from %s: %s)${NC}\n" \
    "$CONSUMED_ESCAPES" "${ESCAPES_FILE:-escapes.md}" "$esc_name_list"
fi
if [ "$EXPIRED_ESCAPES" -gt 0 ]; then
  printf "${YELLOW}Expired escapes still counted as violations: %d${NC}\n" \
    "$EXPIRED_ESCAPES"
fi

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

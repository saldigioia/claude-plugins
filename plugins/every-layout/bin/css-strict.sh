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
#             bespoke inline style="" declarations in .html/.astro;
#             light-dark() without a color-scheme declaration in the same
#             corpus (ELP_016 — per-document for .html incl. the meta tag,
#             corpus-level for .css/.astro; a lone-file scan downgrades to a
#             warning); root-painted background images/gradients/sizes with
#             no background-color ground anywhere on body/html/:root
#             (ELP_035 — same document/corpus/warning split)
#   ELA_003 — !important (canonical prefers-reduced-motion reset whitelisted);
#             ID selectors; compound/complex selectors exceeding the 0-2-0
#             specificity cap (functional pseudo-classes :not/:is/:where/:has
#             and their arguments are NOT counted — the cap targets
#             class-chaining escalation, not spec-exact specificity);
#             content-tier typographic permissions (word-break/word-wrap/
#             overflow-wrap/hyphens) granted to body/html/:root/*/heading
#             subjects (ELP_034 — @media print/@page blocks and the
#             non-grant values normal/keep-all/none/manual/unset/initial/
#             revert are whitelisted; see bin/lib/typo-scope.sh)
#   ELA_004 — margin/padding/gap rem/em values outside the modular scale
#   ELA_006 — (--archival only) content-visibility:auto on content;
#             brace-nesting depth > 3; @supports not (...) gating
#
# Warn-tier tripwires (printed, never affect the exit code, no escape rows):
#   - near-duplicate hex color tokens: two distinct custom properties whose
#     6-digit (or expanded 3-digit) hex values sit within a max per-channel
#     delta of 16 — near-duplicate inks are drift (token-rules.md). Honest
#     limits: hex-literal values only; light-dark()/oklch()/color-mix()
#     wrapped tokens are not compared — a tripwire, not colorimetry.
#   - adjacent breakpoints: two distinct @media min-width px values ≤ 2px
#     apart in the same corpus (max-width is deliberately ignored: the
#     640px/641px max/min hand-off idiom is legitimate).
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
# shellcheck source=lib/typo-scope.sh
. "$SCRIPT_DIR/lib/typo-scope.sh"

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

MODE_FILE=0
if [ -f "$DIR" ]; then
  case "$DIR" in
    *.css|*.html|*.astro) ;;
    *) echo "error: $DIR is not a .css/.html/.astro file" >&2; exit 2 ;;
  esac
  MODE_FILE=1
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

# H2.1 — true counts: every finding is COUNTED (and escape-checked); only the
# first $DISPLAY_CAP per (axiom, file) group are PRINTED. fail() tracks the
# group itself and flush_more announces any truncated remainder, so the
# summary's "N violation(s)" is the real N, never a display artifact.
DISPLAY_CAP=5
VERBOSE=1
LAST_KEY=""
LAST_AXIOM=""
LAST_FILE=""
KEY_N=0
FILE_SUPPRESSED=0
flush_more() {
  if [ -n "$LAST_KEY" ] && [ "$KEY_N" -gt "$DISPLAY_CAP" ]; then
    printf "    ${YELLOW}… and %d more [%s] finding(s) in %s (display capped; all counted)${NC}\n" \
      "$((KEY_N - DISPLAY_CAP))" "$LAST_AXIOM" "$LAST_FILE"
  fi
  LAST_KEY=""
  KEY_N=0
  VERBOSE=1
  return 0
}

STYLE_TMP="$(mktemp "${TMPDIR:-/tmp}/css-strict.XXXXXX")"
# Corpus signal store for the cross-file checks (C1.1 color-scheme, C1.2
# painted ground, and the warn-tier token/breakpoint tripwires). One
# TAB-delimited record per line: KIND<TAB>file<TAB>...payload.
CORPUS_TMP="$(mktemp "${TMPDIR:-/tmp}/css-strict-corpus.XXXXXX")"
trap 'rm -f "$STYLE_TMP" "$CORPUS_TMP"' EXIT

# warn_note — warn-tier finding: printed, never counted, never escape-keyed.
warn_note() {
  printf "${YELLOW}warning: %s${NC}\n" "$1"
}

# Axiom check helpers -----------------------------------------------------

# fail — record (or suppress) one axiom violation. This is the SOLE place
# VIOLATIONS is incremented, so escape suppression accounting stays correct:
#   - a registered, unexpired escape suppresses it (no count, yellow note);
#   - an expired escape still counts and is flagged as expired;
#   - an unregistered violation counts as normal.
fail() {
  local axiom="$1" file="$2" line="$3" snippet="$4" reason="$5"
  local status esc rest key
  key="$axiom|$file"
  if [ "$key" = "$LAST_KEY" ]; then
    KEY_N=$((KEY_N + 1))
  else
    flush_more
    LAST_KEY="$key"; LAST_AXIOM="$axiom"; LAST_FILE="$file"; KEY_N=1
  fi
  if [ "$KEY_N" -le "$DISPLAY_CAP" ]; then VERBOSE=1; else VERBOSE=0; fi
  status="$(escapes_lookup "$file" "$axiom" "$line")"
  case "$status" in
    "suppressed "*)
      esc="${status#suppressed }"
      SUPPRESSED=$((SUPPRESSED + 1))
      FILE_SUPPRESSED=$((FILE_SUPPRESSED + 1))
      if [ "$VERBOSE" -eq 1 ]; then
        printf "${YELLOW}[%s]${NC} %s:%s — suppressed by %s\n" \
          "$axiom" "$file" "$line" "$esc"
      fi
      ;;
    "expired "*)
      rest="${status#expired }"
      VIOLATIONS=$((VIOLATIONS + 1))
      if [ "$VERBOSE" -eq 1 ]; then
        printf "${RED}[%s]${NC} %s:%s\n    %s\n    escape expired (%s) — renew the escapes.md entry or fix the violation\n" \
          "$axiom" "$file" "$line" "$snippet" "$rest"
      fi
      ;;
    *)
      VIOLATIONS=$((VIOLATIONS + 1))
      if [ "$VERBOSE" -eq 1 ]; then
        printf "${RED}[%s]${NC} %s:%s\n    %s\n    %s\n" \
          "$axiom" "$file" "$line" "$snippet" "$reason"
      fi
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
  ' "$file" 2>/dev/null)

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
   )

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
   )

  # ELA_003 — !important (excluding canonical prefers-reduced-motion: reduce resets)
  while IFS=: read -r lineno rest; do
    [ -z "$lineno" ] && continue
    if is_whitelisted_line "$lineno"; then continue; fi
    fail "ELA_003" "$rname" "$lineno" "$(printf '%s' "$rest" | head -c 80)" "!important — use layer order for overrides, not specificity escalation"
  done < <(grep -nE '!important' "$file" 2>/dev/null)

  # ELA_003 — ID selectors
  while IFS=: read -r lineno rest; do
    [ -z "$lineno" ] && continue
    fail "ELA_003" "$rname" "$lineno" "$(printf '%s' "$rest" | head -c 80)" "ID selector — 0-2-0 specificity cap. Use class or attribute."
  done < <(grep -nE '^\s*#[a-zA-Z][a-zA-Z0-9_-]*\s*[{,]' "$file" 2>/dev/null)

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
  ' "$file" 2>/dev/null)

  # ELA_004 — arbitrary numeric spacing (rem/em outside scale)
  while IFS=: read -r lineno rest; do
    [ -z "$lineno" ] && continue
    fail "ELA_004" "$rname" "$lineno" "$(printf '%s' "$rest" | head -c 80)" "Non-scale rem/em value — use --s-5..--s5 tokens"
  done < <(grep -nE '(margin|padding|gap)(-[a-z]+)?\s*:\s*[0-9]+\.?[0-9]*(rem|em)' "$file" 2>/dev/null \
    | grep -vE '(var\(--|/\*|0\.132rem|0\.198rem|0\.296rem|0\.444rem|0\.667rem|1rem|1\.5rem|2\.25rem|3\.375rem|5\.063rem|7\.594rem|0\.5em|1em|1\.5em|0\.25em)' \
   )

  # ELA_006 — archival durability (opt-in)
  if [ "$ARCHIVAL" -eq 1 ]; then
    while IFS=: read -r lineno rest; do
      [ -z "$lineno" ] && continue
      fail "ELA_006" "$rname" "$lineno" "$rest" "content-visibility: auto can hide primary content if script fails"
    done < <(grep -nE '^\s*content-visibility\s*:\s*auto' "$file" 2>/dev/null)

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
    ' "$file" 2>/dev/null)

    # @supports not (...) — gating a "must work" feature behind a negative
    # support query means the base experience differs by browser era.
    while IFS=: read -r lineno rest; do
      [ -z "$lineno" ] && continue
      fail "ELA_006" "$rname" "$lineno" "$(printf '%s' "$rest" | head -c 80)" "@supports not (...) — provide the base experience unconditionally; enhance additively"
    done < <(grep -nE '@supports[^{]*\bnot[[:space:]]*\(' "$file" 2>/dev/null)
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
  ' "$file" 2>/dev/null)
}

# scan_typo_grants <readable-css-file> <report-name> — ELP_034 hard check.
# Content-tier typographic permissions (word-break/word-wrap/overflow-wrap/
# hyphens) granted to body/html/:root/*/heading subjects fail ELA_003: a
# global grant is a site-wide license that display type eventually cashes in
# as a mid-word fracture. Scanner and whitelists live in bin/lib/typo-scope.sh
# (shared with the PostToolUse warning hook).
scan_typo_grants() {
  local file="$1" rname="$2"
  local lineno sel decl
  while IFS="$(printf '\t')" read -r lineno sel decl; do
    [ -z "$lineno" ] && continue
    fail "ELA_003" "$rname" "$lineno" "$(printf '%s { %s }' "$sel" "$decl" | head -c 100)" \
      "Content-tier typographic permission at global/heading scope (ELP_034) — grant word-break/overflow-wrap/hyphens to the content container, never to body/:root/*/headings"
  done < <(typo_scope_scan "$file")
}

# collect_corpus_signals <readable-css-file> <report-name> — record the
# cross-file signals the corpus checks need. Emits TAB-delimited records to
# $CORPUS_TMP:
#   LD      file line snippet   first light-dark() use in the file
#   CS      file                a color-scheme: declaration exists
#   PAINT   file line snippet   body/html/:root block paints an image/gradient
#                               or sets background-size
#   GROUND  file                body/html/:root block paints a ground color
#   TOKEN   file line name hex  custom property whose value is a bare hex
#   BP      file line px        @media min-width breakpoint value
collect_corpus_signals() {
  local file="$1" rname="$2"

  # One block-aware, comment-stripping pass gathers the light-dark()/
  # color-scheme signals (ELP_016) and the painted-ground signals (ELP_035).
  # Comments are stripped first so prose mentioning light-dark() or
  # background never records a signal. A "ground" is background-color with a
  # non-transparent value, or a background shorthand whose color sits OUTSIDE
  # url()/gradient() args (iterative paren-stripping; var()/color functions
  # survive as bare names).
  awk -v rname="$rname" '
    function trim(s) { gsub(/^[[:space:]]+/, "", s); gsub(/[[:space:]]+$/, "", s); return s }
    function rootish_subject(part,    s, n, toks, subj) {
      s = part
      while (gsub(/\([^()]*\)/, "", s) > 0) { }
      gsub(/\[[^]]*\]/, "", s)
      gsub(/[>+~]/, " ", s)
      s = trim(s)
      if (s == "") return 0
      gsub(/[[:space:]]+/, " ", s)
      n = split(s, toks, " ")
      subj = toks[n]
      if (index(subj, ":root") > 0) return 1
      if (subj ~ /^(body|html)$/) return 1
      if (subj ~ /^(body|html)[.:#]/) return 1
      return 0
    }
    function has_bare_color(v,    s) {
      s = v
      while (gsub(/\([^()]*\)/, "", s) > 0) { }
      if (s ~ /#[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]/) return 1
      if (s ~ /(^|[ \t,])(rgb|rgba|hsl|hsla|hwb|lab|lch|oklab|oklch|color|color-mix|light-dark|var)([ \t,]|$)/) return 1
      if (s ~ /(^|[ \t,])(white|black|silver|gray|grey|maroon|red|purple|fuchsia|green|lime|olive|yellow|navy|blue|teal|aqua)([ \t,]|$)/) return 1
      return 0
    }
    function scan_decls(seg, ln,    i, m, decls, decl, val, sel, d, parts, np, j, root) {
      if (depth <= 0) return
      sel = ""
      for (d = depth - 1; d >= 0; d--) if (sels[d] != "") { sel = sels[d]; break }
      if (sel == "") return
      root = 0
      np = split(sel, parts, ",")
      for (j = 1; j <= np; j++) if (rootish_subject(parts[j])) { root = 1; break }
      m = split(seg, decls, ";")
      for (i = 1; i <= m; i++) {
        decl = trim(decls[i])
        if (decl == "") continue
        # ELP_016 signals — any block, not just root-ish ones.
        if (!ld_seen && decl ~ /light-dark[[:space:]]*\(/) {
          ld_seen = 1
          printf "LD\t%s\t%d\t%s\n", rname, ln, substr(decl, 1, 80)
        }
        if (!cs_seen && decl ~ /^color-scheme[[:space:]]*:/) {
          cs_seen = 1
          printf "CS\t%s\n", rname
        }
        if (!root) continue
        val = decl
        sub(/^[^:]*:/, "", val)
        val = tolower(trim(val))
        if (decl ~ /^background-image[[:space:]]*:/) {
          if (val != "none") printf "PAINT\t%s\t%d\t%s\n", rname, ln, substr(decl, 1, 80)
        } else if (decl ~ /^background-size[[:space:]]*:/) {
          printf "PAINT\t%s\t%d\t%s\n", rname, ln, substr(decl, 1, 80)
        } else if (decl ~ /^background-color[[:space:]]*:/) {
          if (val !~ /^(transparent|none|inherit|initial|unset|revert|revert-layer)$/) printf "GROUND\t%s\n", rname
        } else if (decl ~ /^background[[:space:]]*:/) {
          if (val ~ /gradient[[:space:]]*\(/ || val ~ /url[[:space:]]*\(/) printf "PAINT\t%s\t%d\t%s\n", rname, ln, substr(decl, 1, 80)
          if (has_bare_color(val)) printf "GROUND\t%s\n", rname
        }
      }
    }
    BEGIN { depth = 0; pend = ""; in_comment = 0 }
    {
      line = $0
      out = ""
      while (1) {
        if (in_comment) {
          idx = index(line, "*/")
          if (idx == 0) { line = ""; break }
          line = substr(line, idx + 2); in_comment = 0
        } else {
          idx = index(line, "/*")
          if (idx == 0) { out = out line; break }
          out = out substr(line, 1, idx - 1)
          rest2 = substr(line, idx + 2)
          e = index(rest2, "*/")
          if (e == 0) { in_comment = 1; line = ""; break }
          line = substr(rest2, e + 2)
        }
      }
      rest = out
      while (1) {
        ob = index(rest, "{"); cb = index(rest, "}")
        if (ob > 0 && (cb == 0 || ob < cb)) {
          head = pend substr(rest, 1, ob - 1)
          pend = ""
          nsem = 0
          for (k = length(head); k >= 1; k--) if (substr(head, k, 1) == ";") { nsem = k; break }
          if (nsem > 0) { scan_decls(substr(head, 1, nsem), NR); head = substr(head, nsem + 1) }
          head = trim(head)
          if (head ~ /^@/) sels[depth] = ""; else sels[depth] = head
          depth++
          rest = substr(rest, ob + 1)
        } else if (cb > 0) {
          scan_decls(substr(rest, 1, cb - 1), NR)
          depth--
          if (depth < 0) depth = 0
          pend = ""
          rest = substr(rest, cb + 1)
        } else {
          if (depth > 0) scan_decls(rest, NR)
          if (trim(rest) != "") pend = pend rest " "
          break
        }
      }
    }
  ' "$file" 2>/dev/null >> "$CORPUS_TMP"

  # Near-duplicate token signals: custom properties whose value is exactly
  # one bare hex literal (light-dark()/oklch()-wrapped tokens are skipped —
  # documented tripwire limit).
  grep -nE '^[[:space:]]*--[A-Za-z0-9_-]+[[:space:]]*:[[:space:]]*#[0-9a-fA-F]{3,8}[[:space:]]*;' "$file" 2>/dev/null \
    | awk -v rname="$rname" '{
        lineno = $0; sub(/:.*$/, "", lineno)
        decl = $0; sub(/^[0-9]*:/, "", decl)
        name = decl; sub(/^[[:space:]]*/, "", name); sub(/[[:space:]]*:.*$/, "", name)
        hex = decl; sub(/^[^#]*#/, "#", hex); sub(/[[:space:]]*;.*$/, "", hex)
        printf "TOKEN\t%s\t%s\t%s\t%s\n", rname, lineno, name, hex
      }' >> "$CORPUS_TMP" || true

  # Breakpoint signals: @media min-width px values (max-width deliberately
  # ignored — the 640px/641px max/min hand-off idiom is legitimate).
  awk -v rname="$rname" '
    /@media/ {
      line = $0
      while (match(line, /min-width[[:space:]]*:[[:space:]]*[0-9]+px/)) {
        v = substr(line, RSTART, RLENGTH)
        gsub(/[^0-9]/, "", v)
        printf "BP\t%s\t%d\t%s\n", rname, NR, v
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$file" 2>/dev/null >> "$CORPUS_TMP" || true
}

# check_document_context <report-name> [raw-html-file] — per-document ELP_016
# and ELP_035 verdicts for .html files. A complete document cannot get its
# color-scheme or canvas ground from another file in the scan set, so these
# fail immediately regardless of dir/file mode. The raw file is consulted for
# <meta name="color-scheme"> which satisfies ELP_016 without CSS.
check_document_context() {
  local rname="$1" raw="${2:-}"
  local ld_line ld_snip has_cs paint_line paint_snip
  ld_line=$(awk -F'\t' -v f="$rname" '$1=="LD" && $2==f { print $3; exit }' "$CORPUS_TMP")
  if [ -n "$ld_line" ]; then
    has_cs=$(awk -F'\t' -v f="$rname" '$1=="CS" && $2==f { print "y"; exit }' "$CORPUS_TMP")
    if [ -z "$has_cs" ] && [ -n "$raw" ]; then
      grep -qiE '<meta[^>]*name=["'"'"']?color-scheme' "$raw" 2>/dev/null && has_cs="y"
    fi
    if [ -z "$has_cs" ]; then
      ld_snip=$(awk -F'\t' -v f="$rname" '$1=="LD" && $2==f { print $4; exit }' "$CORPUS_TMP")
      fail "ELA_002" "$rname" "$ld_line" "$ld_snip" \
        "light-dark() without a color-scheme declaration in this document (ELP_016) — light-dark() is inert until color-scheme opts the document in; add color-scheme: light dark to :root or a meta tag"
    fi
  fi
  if awk -F'\t' -v f="$rname" '$1=="PAINT" && $2==f { found=1; exit } END { exit !found }' "$CORPUS_TMP"; then
    if ! awk -F'\t' -v f="$rname" '$1=="GROUND" && $2==f { found=1; exit } END { exit !found }' "$CORPUS_TMP"; then
      while IFS="$(printf '\t')" read -r paint_line paint_snip; do
        [ -z "$paint_line" ] && continue
        fail "ELA_002" "$rname" "$paint_line" "$paint_snip" \
          "Background image/gradient painted on an unpainted canvas (ELP_035) — declare background-color on body/html/:root; the UA canvas is not a color you chose (dark-preference browsers show black wherever the image stops)"
      done < <(awk -F'\t' -v f="$rname" '$1=="PAINT" && $2==f { printf "%s\t%s\n", $3, $4 }' "$CORPUS_TMP")
    fi
  fi
}

# corpus_checks — end-of-run verdicts across the .css/.astro scan set (a
# fragment corpus shares one cascade; .html documents were judged per-file).
# In single-file mode the corpus is one file, so ELP_016/ELP_035 downgrade to
# warnings — the missing declaration may legitimately live in a sibling file.
corpus_checks() {
  local ld_rec ld_file ld_line ld_snip
  # ELP_016 — light-dark() somewhere in the fragment corpus needs color-scheme
  # somewhere in the same corpus.
  ld_rec=$(awk -F'\t' '$1=="LD" && $2 !~ /\.html$/ { print; exit }' "$CORPUS_TMP")
  if [ -n "$ld_rec" ]; then
    if ! awk -F'\t' '$1=="CS" && $2 !~ /\.html$/ { found=1; exit } END { exit !found }' "$CORPUS_TMP"; then
      ld_file=$(printf '%s' "$ld_rec" | cut -f2)
      ld_line=$(printf '%s' "$ld_rec" | cut -f3)
      ld_snip=$(printf '%s' "$ld_rec" | cut -f4)
      if [ "$MODE_FILE" -eq 1 ]; then
        warn_note "light-dark() at $ld_file:$ld_line but no color-scheme declaration in this file (ELP_016) — light-dark() is inert until color-scheme opts the page in; verify the project declares it (single-file scan cannot see siblings, so this is a warning, not a failure)"
      else
        fail "ELA_002" "$ld_file" "$ld_line" "$ld_snip" \
          "light-dark() used but no color-scheme declaration anywhere in the scanned corpus (ELP_016) — light-dark() is inert until color-scheme opts the document in; add color-scheme: light dark to :root"
      fi
    fi
  fi

  # ELP_035 — a painted root image/gradient needs a painted ground somewhere
  # in the same fragment corpus.
  if awk -F'\t' '$1=="PAINT" && $2 !~ /\.html$/ { found=1; exit } END { exit !found }' "$CORPUS_TMP"; then
    if ! awk -F'\t' '$1=="GROUND" && $2 !~ /\.html$/ { found=1; exit } END { exit !found }' "$CORPUS_TMP"; then
      local pfile pline psnip
      while IFS="$(printf '\t')" read -r pfile pline psnip; do
        [ -z "$pfile" ] && continue
        if [ "$MODE_FILE" -eq 1 ]; then
          warn_note "background image/gradient on body/html/:root at $pfile:$pline with no background-color ground in this file (ELP_035) — verify the project paints the canvas (single-file scan cannot see siblings)"
        else
          fail "ELA_002" "$pfile" "$pline" "$psnip" \
            "Background image/gradient painted on an unpainted canvas (ELP_035) — no background-color reaches body/html/:root anywhere in the scanned corpus; dark-preference browsers show black wherever the image stops"
        fi
      done < <(awk -F'\t' '$1=="PAINT" && $2 !~ /\.html$/ { printf "%s\t%s\t%s\n", $2, $3, $4 }' "$CORPUS_TMP")
    fi
  fi

  # Warn-tier: near-duplicate hex tokens (drift, token-rules.md). Pairs are
  # compared within one file always, across files only for fragment corpora
  # (.css/.astro) — two unrelated self-contained .html demos do not share a
  # cascade.
  awk -F'\t' '
    function hd(c) { return index("0123456789abcdef", tolower(c)) - 1 }
    function chan(h, i) { return hd(substr(h, 2*i, 1)) * 16 + hd(substr(h, 2*i + 1, 1)) }
    function norm(h,    r, g, b) {
      if (length(h) == 4) return "#" substr(h,2,1) substr(h,2,1) substr(h,3,1) substr(h,3,1) substr(h,4,1) substr(h,4,1)
      if (length(h) == 7) return h
      return ""
    }
    function absv(x) { return x < 0 ? -x : x }
    $1 == "TOKEN" {
      h = norm($5)
      if (h == "") next
      n++; f[n] = $2; l[n] = $3; nm[n] = $4; hx[n] = h; raw[n] = $5
    }
    END {
      for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) {
        if (nm[i] == nm[j]) continue
        if (f[i] != f[j] && (f[i] ~ /\.html$/ || f[j] ~ /\.html$/)) continue
        if (hx[i] == hx[j]) continue
        d1 = absv(chan(hx[i],1) - chan(hx[j],1))
        d2 = absv(chan(hx[i],2) - chan(hx[j],2))
        d3 = absv(chan(hx[i],3) - chan(hx[j],3))
        d = d1; if (d2 > d) d = d2; if (d3 > d) d = d3
        if (d <= 16) {
          key = nm[i] "|" nm[j] "|" hx[i] "|" hx[j]
          if (key in seen) continue
          seen[key] = 1
          printf "near-duplicate color tokens (max channel delta %d ≤ 16): %s %s (%s:%s) vs %s %s (%s:%s) — one ink per role; near-duplicates are drift (token-rules.md)\n", d, nm[i], raw[i], f[i], l[i], nm[j], raw[j], f[j], l[j]
        }
      }
    }
  ' "$CORPUS_TMP" | while IFS= read -r msg; do warn_note "$msg"; done

  # Warn-tier: adjacent min-width breakpoints (≤ 2px apart).
  awk -F'\t' '
    function absv(x) { return x < 0 ? -x : x }
    $1 == "BP" {
      if (($4 "") in where) next
      n++; v[n] = $4 + 0; where[$4 ""] = $2 ":" $3; fl[n] = $2
    }
    END {
      for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) {
        if (v[i] == v[j]) continue
        if (fl[i] != fl[j] && (fl[i] ~ /\.html$/ || fl[j] ~ /\.html$/)) continue
        if (absv(v[i] - v[j]) <= 2) {
          printf "adjacent breakpoints: min-width %dpx (%s) and %dpx (%s) are %dpx apart — one of these is off the grid; pick one value\n", v[i], where[v[i] ""], v[j], where[v[j] ""], absv(v[i] - v[j])
        }
      }
    }
  ' "$CORPUS_TMP" | while IFS= read -r msg; do warn_note "$msg"; done
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
  flush_more
  FILE_SUPPRESSED=0
  FILES_CHECKED=$((FILES_CHECKED + 1))
  case "$file" in
    *.css)
      check_css_content "$file" "$file"
      scan_typo_grants "$file" "$file"
      collect_corpus_signals "$file" "$file"
      ;;
    *.html|*.astro)
      extract_style_blocks "$file"
      check_css_content "$STYLE_TMP" "$file"
      check_inline_attrs "$file"
      scan_typo_grants "$STYLE_TMP" "$file"
      collect_corpus_signals "$STYLE_TMP" "$file"
      case "$file" in
        *.html) check_document_context "$file" "$file" ;;
      esac
      ;;
  esac
  # H2.3 — the escape-hatch registry's per-file limit (≤3) is advisory, but
  # exceeding it should never be silent.
  if [ "$FILE_SUPPRESSED" -gt 3 ]; then
    printf "${YELLOW}advisory: %d suppressions in %s exceed the per-file escape cap (3) — see escape-hatch-registry.md limits${NC}\n" \
      "$FILE_SUPPRESSED" "$file"
  fi
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

flush_more
corpus_checks
flush_more
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

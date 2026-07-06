#!/usr/bin/env bash
# ports-lint.sh — CSS-in-JS detector for framework component sources.
#
# Axiom ELA_005 (CSS-Dominant Composition) forbids styling the DOM from a
# framework runtime: no styled-components, no css`` literals, no runtime
# <style> injection, no bespoke declarations in style objects. The compliant
# port pattern is class + custom-property parameters only:
#
#   <Component className="stack" style={{ '--space': space }}>       OK
#   const styles: React.CSSProperties = { display: 'flex', ... }     FAIL
#   <style>{childStyles}</style>                                     FAIL
#
# Scans: .tsx .jsx .vue .svelte .js .mjs source files.
# Known v1 limits (documented, not silent): opaque bindings such as
# `:style="styles"` where the object is built elsewhere are not resolved —
# the React.CSSProperties and import patterns usually catch those files
# anyway. Markdown reference docs are not scanned (their code fences may
# legitimately show anti-examples).
#
# Usage:
#   bin/ports-lint.sh [--strict] <file|directory> [...]
#
# Default mode prints findings as warnings and exits 0 (PostToolUse hook
# usage). With --strict, any finding exits 1 (CI usage).
#
# Exit codes: 0 — clean (or warn-only mode); 1 — findings in --strict mode;
#             2 — invocation error.

set -uo pipefail

STRICT=0
TARGETS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --strict) STRICT=1; shift ;;
    --help|-h) grep -E '^# ' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) TARGETS="$TARGETS
$1"; shift ;;
  esac
done

[ -z "$(printf '%s' "$TARGETS" | tr -d '[:space:]')" ] && { echo "usage: ports-lint.sh [--strict] <file|dir> [...]" >&2; exit 2; }

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

FINDINGS=0
FILES_SCANNED=0

scan_file() {
  local f="$1" out
  FILES_SCANNED=$((FILES_SCANNED + 1))
  out=$(awk '
    function check_keys(inner, nr,   m, kv, i, key) {
      m = split(inner, kv, ",")
      for (i = 1; i <= m; i++) {
        key = kv[i]
        sub(/:.*/, "", key)
        gsub(/[[:space:]"`\[\]]/, "", key)
        gsub(/'\''/, "", key)
        if (key == "") continue
        if (key ~ /^\.\.\./) continue
        if (key !~ /^--/) {
          print nr "\tbespoke key \"" key "\" in inline style object — only --custom-property primitive parameters may be set from the framework (ELA_005)"
        }
      }
    }
    /React\.CSSProperties/ { print NR "\tstyle-object typing (React.CSSProperties) — emit classes + custom-property parameters, not declaration objects (ELA_005)" }
    /styled\.[A-Za-z]/     { print NR "\tstyled-components tag — CSS-in-JS is forbidden (ELA_005)" }
    /styled\(/             { print NR "\tstyled() call — CSS-in-JS is forbidden (ELA_005)" }
    /[^A-Za-z]css`/        { print NR "\tcss`` template literal — CSS-in-JS is forbidden (ELA_005)" }
    /from ["'\''](styled-components|@emotion|@stitches|goober|@linaria)/ { print NR "\tCSS-in-JS library import — forbidden (ELA_005)" }
    /<style[^>]*>[[:space:]]*\{/ { print NR "\truntime <style> injection from a component — ship primitive CSS once as a stylesheet (ELA_005)" }
    /<style jsx/           { print NR "\tstyled-jsx block — CSS-in-JS is forbidden (ELA_005)" }
    {
      line = $0
      while (match(line, /style=\{\{[^}]*\}\}/)) {
        inner = substr(line, RSTART + 8, RLENGTH - 10)
        check_keys(inner, NR)
        line = substr(line, RSTART + RLENGTH)
      }
      if (match($0, /style=\{\{[^}]*$/)) {
        print NR "\tmulti-line style object — keep style objects single-line with only --custom-property keys so the linter can verify them (ELA_005)"
      }
      line = $0
      while (match(line, /:style="\{[^}]*\}"/)) {
        inner = substr(line, RSTART + 9, RLENGTH - 11)
        check_keys(inner, NR)
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$f" 2>/dev/null)
  if [ -n "$out" ]; then
    while IFS="$(printf '\t')" read -r lineno msg; do
      [ -z "$lineno" ] && continue
      FINDINGS=$((FINDINGS + 1))
      printf "${RED}[ELA_005]${NC} %s:%s\n    %s\n" "$f" "$lineno" "$msg"
    done <<EOF
$out
EOF
  fi
}

printf "${BOLD}ports-lint.sh — CSS-in-JS detector (ELA_005)${NC}\n"
echo "---"

while IFS= read -r target; do
  [ -z "$target" ] && continue
  if [ -f "$target" ]; then
    scan_file "$target"
  elif [ -d "$target" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] && scan_file "$f"
    done < <(find "$target" -type f \( -name "*.tsx" -o -name "*.jsx" -o -name "*.vue" -o -name "*.svelte" -o -name "*.js" -o -name "*.mjs" \) \
      -not -path "*/node_modules/*" -not -path "*/dist/*" -not -path "*/.astro/*" -not -path "*/.git/*" 2>/dev/null)
  else
    echo "warning: $target not found, skipped" >&2
  fi
done <<EOF
$TARGETS
EOF

echo "---"
if [ "$FINDINGS" -eq 0 ]; then
  printf "${GREEN}${BOLD}CLEAN${NC} — %d file(s) scanned; no CSS-in-JS patterns.\n" "$FILES_SCANNED"
  exit 0
fi
if [ "$STRICT" -eq 1 ]; then
  printf "${RED}${BOLD}FAIL${NC} — %d CSS-in-JS finding(s) across %d file(s). Styling lives in CSS (ELA_005).\n" "$FINDINGS" "$FILES_SCANNED"
  exit 1
else
  printf "${YELLOW}${BOLD}WARN${NC} — %d CSS-in-JS finding(s) across %d file(s). Styling lives in CSS (ELA_005).\n" "$FINDINGS" "$FILES_SCANNED"
  exit 0
fi

#!/usr/bin/env bash
# archival-audit.sh — ELA_006 external-dependency sweep.
#
# A five-year page cannot depend on someone else's uptime. This audit flags
# runtime references to third-party hosts in CSS/HTML/Astro sources:
#   1. url(http…) / url(//…) in CSS           (remote fonts, images, cursors)
#   2. @import of a remote stylesheet
#   3. <link href="http…"> in HTML/Astro       (stylesheets, font preloads)
#   4. <script src="http…"> in HTML/Astro
# Relative/self-hosted assets pass; only absolute external references count.
#
# Flag-only by default (exit 0); --strict exits 1 on any finding. Register
# a deliberate external dependency in escapes.md (axiom ELA_006) and fix or
# vendor the rest.
#
# Usage: bin/archival-audit.sh [--strict] <file|directory> [...]
# Exit codes: 0 clean (or report mode); 1 findings in --strict; 2 usage.
#
# bash 3.2 / BSD grep, like every script in bin/.

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
[ -z "$(printf '%s' "$TARGETS" | tr -d '[:space:]')" ] && { echo "usage: archival-audit.sh [--strict] <file|dir> [...]" >&2; exit 2; }

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

FINDINGS=0
FILES_SCANNED=0

scan_file() {
  local f="$1" lineno rest
  FILES_SCANNED=$((FILES_SCANNED + 1))

  # 1+2: remote url() / @import in CSS (also catches <style> blocks verbatim)
  while IFS=: read -r lineno rest; do
    [ -z "$lineno" ] && continue
    FINDINGS=$((FINDINGS + 1))
    printf "${RED}[ELA_006]${NC} %s:%s\n    %s\n    Remote asset dependency — vendor it, or register in escapes.md with expiry\n" \
      "$f" "$lineno" "$(printf '%s' "$rest" | head -c 100)"
  done < <(grep -nE '(url\((["'"'"']?)(https?:)?//|@import[^;]*(["'"'"'(])(https?:)?//)' "$f" 2>/dev/null | head -5)

  # 3+4: <link>/<script> pointing at external hosts
  case "$f" in
    *.html|*.astro)
      while IFS=: read -r lineno rest; do
        [ -z "$lineno" ] && continue
        FINDINGS=$((FINDINGS + 1))
        printf "${RED}[ELA_006]${NC} %s:%s\n    %s\n    External <link>/<script> — self-host it, or register in escapes.md with expiry\n" \
          "$f" "$lineno" "$(printf '%s' "$rest" | head -c 100)"
      done < <(grep -nE '<(link|script)[^>]+(href|src)=["'"'"'](https?:)?//' "$f" 2>/dev/null | head -5)
      ;;
  esac
}

printf "${BOLD}archival-audit.sh — external-dependency sweep (ELA_006)${NC}\n"
echo "---"

while IFS= read -r target; do
  [ -z "$target" ] && continue
  if [ -f "$target" ]; then
    scan_file "$target"
  elif [ -d "$target" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] && scan_file "$f"
    done < <(find "$target" -type f \( -name "*.css" -o -name "*.html" -o -name "*.astro" \) \
      -not -path "*/node_modules/*" -not -path "*/dist/*" -not -path "*/.astro/*" -not -path "*/.git/*" 2>/dev/null)
  else
    echo "warning: $target not found, skipped" >&2
  fi
done <<EOF
$TARGETS
EOF

echo "---"
if [ "$FINDINGS" -eq 0 ]; then
  printf "${GREEN}${BOLD}SELF-CONTAINED${NC} — %d file(s) scanned; no external runtime dependencies.\n" "$FILES_SCANNED"
  exit 0
fi
if [ "$STRICT" -eq 1 ]; then
  printf "${RED}${BOLD}FAIL${NC} — %d external dependenc(ies) across %d file(s). Archival pages own their assets (ELA_006).\n" "$FINDINGS" "$FILES_SCANNED"
  exit 1
else
  printf "${YELLOW}${BOLD}WARN${NC} — %d external dependenc(ies) across %d file(s). Archival pages own their assets (ELA_006).\n" "$FINDINGS" "$FILES_SCANNED"
  exit 0
fi

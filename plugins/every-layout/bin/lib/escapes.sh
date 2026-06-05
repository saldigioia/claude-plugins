#!/usr/bin/env bash
# escapes.sh — parse escapes.md into an allowlist and answer (file, axiom, line)
# lookups.
#
# Sourced by bin/css-strict.sh and bin/js-budget.sh so a registered, unexpired
# escape suppresses the matching axiom violation while an expired or unregistered
# one still fails the gate. The escape registry is the single place intentional
# deviations live (see escapes.md.template and
# skills/css-design-system/references/escape-hatch-registry.md).
#
# Canonical format: a markdown table whose rows are
#   | ESC ID | Target (glob) | Axiom | Lines | Expires | Owner | Justification |
# One (target, axiom[, lines]) entry per row. The match key is
# (Target glob, Axiom, Lines); ESC ID, Owner, and Justification are
# human-readable only. A row is recognised only when its Axiom column is an
# ELA_### id and its Expires column is an ISO date — so the header and separator
# rows, comments, and prose are skipped automatically.
#
# Lines column: `-` (or empty / `any`) means the escape covers EVERY line of the
# matching file (file-level, the default). A value like `9`, `9,10`, or `9-11`
# scopes the escape to those line numbers only — so an unrelated, accidental
# violation of the same axiom elsewhere in the file still fails. js-budget.sh has
# no line concept, so it only matches file-level (`-`) escapes.
#
# Written for bash 3.2 and onetrueawk (macOS): no associative arrays, no
# globstar, no awk {n} interval expressions.
#
# Public API:
#   escapes_load [escapes_file]           Populate ESCAPES_RECORDS / ESCAPES_FILE_USED.
#                                         Defaults to $ESCAPES_FILE, then ./escapes.md.
#                                         Missing file is not an error (empty allowlist).
#   escapes_lookup <file> <axiom> [line]  Print exactly one of:
#                                           "suppressed <ESC_ID>"
#                                           "expired <ESC_ID> <YYYY-MM-DD>"
#                                           ""   (no matching escape)
#
# Expiry is inclusive: an escape is expired when today > Expires. "Today" is
# $ESCAPES_TODAY (YYYY-MM-DD) when set — for reproducible tests — else `date +%F`.
# Target globs are matched with shell `case` patterns, where `*` matches any
# characters including `/`. A leading `./` on the file is stripped before
# matching. When both a valid and an expired escape match the same key, the valid
# one wins (so renewing = adding a fresh row).

ESCAPES_RECORDS=""
ESCAPES_FILE_USED=""

escapes_today() {
  if [ -n "${ESCAPES_TODAY:-}" ]; then
    printf '%s' "$ESCAPES_TODAY"
  else
    date +%F
  fi
}

# escapes_line_matches <line> <spec> — is <line> covered by the Lines <spec>?
# spec `-`/empty/`any` => every line (file-level). Otherwise comma-separated
# values and a-b ranges, e.g. "9", "9,10", "9-11". A line-scoped spec never
# matches an empty <line> (e.g. a file-level js-budget lookup).
escapes_line_matches() {
  local line="$1" spec="$2" part lo hi
  case "$spec" in ""|"-"|any|ANY|"*") return 0 ;; esac
  [ -n "$line" ] || return 1
  local oldifs="$IFS"; IFS=','
  for part in $spec; do
    part="$(printf '%s' "$part" | tr -d '[:space:]')"
    case "$part" in
      *-*)
        lo="${part%%-*}"; hi="${part##*-}"
        if [ "$line" -ge "$lo" ] 2>/dev/null && [ "$line" -le "$hi" ] 2>/dev/null; then
          IFS="$oldifs"; return 0
        fi ;;
      *)
        if [ "$line" = "$part" ]; then IFS="$oldifs"; return 0; fi ;;
    esac
  done
  IFS="$oldifs"; return 1
}

escapes_load() {
  local file="${1:-${ESCAPES_FILE:-escapes.md}}"
  ESCAPES_RECORDS=""
  ESCAPES_FILE_USED=""
  [ -f "$file" ] || return 0
  ESCAPES_FILE_USED="$file"

  # Emit one TAB-delimited record per valid table row:
  #   target\taxiom\tlines\texpires\tesc_id
  ESCAPES_RECORDS=$(awk -F'|' '
    {
      if (NF < 7) next
      esc=$2; target=$3; axiom=$4; lines=$5; expires=$6
      gsub(/^[ \t]+/, "", esc);     gsub(/[ \t]+$/, "", esc)
      gsub(/^[ \t]+/, "", target);  gsub(/[ \t]+$/, "", target)
      gsub(/^[ \t]+/, "", axiom);   gsub(/[ \t]+$/, "", axiom)
      gsub(/^[ \t]+/, "", lines);   gsub(/[ \t]+$/, "", lines)
      gsub(/^[ \t]+/, "", expires); gsub(/[ \t]+$/, "", expires)
      gsub(/`/, "", target)
      if (axiom !~ /^ELA_[0-9][0-9][0-9]$/) next
      if (expires !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) next
      printf "%s\t%s\t%s\t%s\t%s\n", target, axiom, lines, expires, esc
    }
  ' "$file")
  return 0
}

# escapes_lookup <file> <axiom> [line] — see header for output contract.
escapes_lookup() {
  local file="$1" axiom="$2" line="${3:-}"
  [ -n "$ESCAPES_RECORDS" ] || return 0
  case "$file" in ./*) file="${file#./}" ;; esac
  local today; today="$(escapes_today)"
  local best_status=""
  local target ax lines expires esc
  while IFS="$(printf '\t')" read -r target ax lines expires esc; do
    [ -n "$target" ] || continue
    [ "$ax" = "$axiom" ] || continue
    case "$file" in $target) ;; *) continue ;; esac
    escapes_line_matches "$line" "$lines" || continue
    if [[ "$today" > "$expires" ]]; then
      best_status="expired $esc $expires"
    else
      printf 'suppressed %s' "$esc"
      return 0
    fi
  done <<EOF
$ESCAPES_RECORDS
EOF
  printf '%s' "$best_status"
  return 0
}

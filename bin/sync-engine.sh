#!/usr/bin/env bash
#
# sync-engine.sh — keep every vendored copy of the CDN engine byte-identical.
#
# More than one plugin ships `tools/cdn/app.sh`. Plugins are installed
# individually, so each one must carry a REAL file — a symlink into a sibling
# plugin would dangle once the marketplace is cloned and a single plugin is
# installed. That means physical duplication is unavoidable, so the copies have
# to be reconciled by a command and gated at publish time rather than by memory.
#
# Usage:
#   bin/sync-engine.sh            copy the canonical engine over every consumer
#   bin/sync-engine.sh --check    report drift and exit 1 (used by publish.sh)
#   bin/sync-engine.sh --list     show canonical + consumers with their hashes
#
# Optional external working copy (a scratch checkout outside the repo):
#   ENGINE_WORKING_COPY=/path/to/app.sh bin/sync-engine.sh --check
# If that path is a symlink resolving to the canonical file it can never drift
# and is reported as linked. If it is a regular file it is diffed like any other
# consumer. Unset (the default) skips the check entirely, so this stays portable.

set -uo pipefail

# ── configuration ────────────────────────────────────────────────────────────

CANONICAL="plugins/hunt/tools/cdn/app.sh"

# Every other in-repo copy that must match CANONICAL byte-for-byte.
# Add a line when a new plugin vendors the engine.
CONSUMERS=(
  "plugins/wayback-archive/tools/cdn/app.sh"
)

# ── plumbing ─────────────────────────────────────────────────────────────────

die() { printf 'sync-engine: %s\n' "$*" >&2; exit 2; }

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || die "must be run inside the marketplace git repository"
cd "$REPO_ROOT" || die "cannot enter $REPO_ROOT"

[[ -f "$CANONICAL" ]] || die "canonical engine not found at $CANONICAL"

MODE="sync"
case "${1:-}" in
  --check) MODE="check" ;;
  --list)  MODE="list" ;;
  "")      MODE="sync" ;;
  -h|--help) sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "unknown option: $1 (try --help)" ;;
esac

hash_of() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }
short()   { cut -c1-12; }

CANON_HASH="$(hash_of "$CANONICAL")"
CANON_SIZE="$(wc -c < "$CANONICAL" | tr -d ' ')"
CANON_RES="$(grep -cE '^cdn_resolve_[a-z0-9_]+\(\)' "$CANONICAL")"

printf 'canonical  %s\n' "$CANONICAL"
printf '           %s bytes · %s resolvers · %s\n\n' \
  "$CANON_SIZE" "$CANON_RES" "$(printf '%s' "$CANON_HASH" | short)"

# Never propagate an engine that does not even parse.
if ! bash -n "$CANONICAL" 2>/dev/null; then
  die "canonical engine fails 'bash -n' — refusing to sync a broken file"
fi

drift=0
changed=0

report_one() {
  local path="$1" label="$2" h size res
  if [[ ! -f "$path" ]]; then
    printf '  [!] %-52s MISSING\n' "$label"
    drift=$((drift + 1))
    return
  fi
  h="$(hash_of "$path")"
  size="$(wc -c < "$path" | tr -d ' ')"
  res="$(grep -cE '^cdn_resolve_[a-z0-9_]+\(\)' "$path")"
  if [[ "$h" == "$CANON_HASH" ]]; then
    printf '  [ok] %-52s in sync\n' "$label"
  else
    printf '  [!!] %-52s DRIFTED — %s bytes · %s resolvers · %s\n' \
      "$label" "$size" "$res" "$(printf '%s' "$h" | short)"
    drift=$((drift + 1))
  fi
}

for c in "${CONSUMERS[@]}"; do
  case "$MODE" in
    check|list) report_one "$c" "$c" ;;
    sync)
      if [[ -f "$c" ]] && [[ "$(hash_of "$c")" == "$CANON_HASH" ]]; then
        printf '  [ok] %-52s already in sync\n' "$c"
      else
        mkdir -p "$(dirname "$c")" || die "cannot create $(dirname "$c")"
        cp "$CANONICAL" "$c" || die "copy failed: $c"
        chmod +x "$c"
        printf '  [->] %-52s UPDATED from canonical\n' "$c"
        changed=$((changed + 1))
      fi
      ;;
  esac
done

# Optional external working copy.
if [[ -n "${ENGINE_WORKING_COPY:-}" ]]; then
  echo
  w="$ENGINE_WORKING_COPY"
  if [[ -L "$w" ]]; then
    target="$(cd "$(dirname "$w")" && cd "$(dirname "$(readlink "$w")")" 2>/dev/null && pwd)/$(basename "$(readlink "$w")")"
    if [[ "$target" == "$REPO_ROOT/$CANONICAL" ]]; then
      printf '  [ok] %-52s symlinked to canonical (cannot drift)\n' "$w"
    else
      printf '  [!!] %-52s symlink points elsewhere: %s\n' "$w" "$target"
      drift=$((drift + 1))
    fi
  elif [[ -f "$w" ]]; then
    report_one "$w" "$w (working copy, regular file)"
  else
    printf '  [--] %-52s not present, skipped\n' "$w"
  fi
fi

echo
case "$MODE" in
  check)
    if (( drift )); then
      printf 'DRIFT: %d copy/copies differ from canonical.\n' "$drift" >&2
      printf 'Run  bin/sync-engine.sh  to reconcile, then re-verify.\n' >&2
      exit 1
    fi
    printf 'All vendored engine copies are in sync.\n'
    ;;
  list)
    (( drift )) && exit 1
    ;;
  sync)
    if (( changed )); then
      printf 'Synced %d copy/copies. Review the diff and bump the affected plugin version(s).\n' "$changed"
    else
      printf 'Nothing to do — every copy already matches canonical.\n'
    fi
    ;;
esac

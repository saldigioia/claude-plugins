#!/usr/bin/env bash
# ci.sh — single entry point for the plugin's own gates.
#
# Runs everything that must stay green in this repo: script syntax, the
# escape-engine acceptance tests, the eval structural validation, and the
# CSS strict gate against the demo site. Exits non-zero if any step fails.
#
# Usage: bash bin/ci.sh          (from anywhere; resolves its own location)
#
# Written for bash 3.2 (macOS default) like every other script in bin/.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0

step() { printf '\n== %s ==\n' "$1"; }

step "bash -n — syntax-check every script in bin/"
for f in "$ROOT"/bin/*.sh "$ROOT"/bin/lib/*.sh; do
  [ -f "$f" ] || continue
  if bash -n "$f"; then
    printf 'ok   %s\n' "${f#$ROOT/}"
  else
    printf 'FAIL %s\n' "${f#$ROOT/}"
    FAIL=1
  fi
done

step "test-escapes.sh — escape engine acceptance"
( cd "$ROOT" && bash bin/test-escapes.sh ) || FAIL=1

step "test-gates.sh — gate hardening acceptance"
( cd "$ROOT" && bash bin/test-gates.sh ) || FAIL=1

step "run-evals.sh — eval fixture structural validation"
( cd "$ROOT" && bash bin/run-evals.sh ) || FAIL=1

step "css-strict.sh — demo site styles"
( cd "$ROOT" && bash bin/css-strict.sh demos/archive-site/src/styles ) || FAIL=1

step "css-strict.sh — canonical stylesheet"
( cd "$ROOT" && bash bin/css-strict.sh demos/every-layout.css ) || FAIL=1

step "css-strict.sh — demos (HTML-mode)"
( cd "$ROOT" && bash bin/css-strict.sh demos/gallery.html ) || FAIL=1
( cd "$ROOT" && bash bin/css-strict.sh demos/artsheet.html ) || FAIL=1

step "css-strict.sh — stress tests (HTML-mode)"
( cd "$ROOT" && bash bin/css-strict.sh stress-tests ) || FAIL=1

step "ports-lint.sh — demo framework sources"
( cd "$ROOT" && bash bin/ports-lint.sh --strict demos/archive-site/src ) || FAIL=1

step "verdict"
if [ "$FAIL" -eq 0 ]; then
  echo "CI GREEN — all gates passed"
else
  echo "CI RED — at least one gate failed"
fi
exit "$FAIL"

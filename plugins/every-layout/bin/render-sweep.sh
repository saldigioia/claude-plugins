#!/usr/bin/env bash
# render-sweep.sh — the opt-in rendered tier (Campaign 3 C3.1).
#
# Static gates audit values; this harness renders and looks. It drives a
# local playwright (never a bundled one — the default toolchain stays
# dependency-free) across a route list at ten viewport widths, light AND
# dark-emulated, reduced-motion emulated for stable captures, and prints a
# per-route probe table for the defect classes that are invisible to
# file-shaped checks:
#
#   overflow   documentElement scrollWidth > clientWidth (horizontal leak)
#   ground     computed background-color of html/body + a literal pixel
#              sample at the bottom of the page — the ELP_035 dark-canvas
#              probe (an unpainted canvas under a dark-preferring browser)
#   fracture   any word inside a rendered h1–h6 that spans more than one
#              line box — the ELP_034 mid-word fracture signature (a word
#              broken at a word boundary never spans two rects)
#
# Availability: requires `node` and a RESOLVABLE local playwright (from the
# current directory, or from --pw-root DIR's node_modules). When either is
# missing the script prints "SKIP — render tier unavailable" and exits 0
# (exit 3 with --strict): default `bin/ci.sh` stays offline and
# dependency-free forever; this tier is opt-in (`bin/ci.sh --with-render`).
#
# Usage:
#   bin/render-sweep.sh --base http://127.0.0.1:4173 [options]
#   bin/render-sweep.sh --serve-dist demos/archive-site/dist [options]
#   bin/render-sweep.sh --config render-sweep.config.json
#   bin/render-sweep.sh --check          # availability probe only (0 = ok, 3 = unavailable)
#
# Options:
#   --base URL        base URL of an already-served site
#   --serve-dist DIR  serve DIR on an ephemeral port for the sweep (built-in
#                     static server inside the driver; no extra dependency)
#   --routes LIST     comma-separated route paths            (default: /)
#   --widths LIST     comma-separated CSS px widths          (default: 320,360,390,414,640,768,834,1024,1280,1440)
#   --out DIR         screenshots + probes.json destination  (default: tmp/render-sweep)
#   --pw-root DIR     resolve playwright from DIR/node_modules
#   --config FILE     JSON with {base|serveDist, routes, widths, out} —
#                     flags override config values
#   --strict          exit 1 on any probe failure; exit 3 when unavailable
#
# Output: full-page PNGs at <out>/<route-slug>/<scheme>-<width>.png, a TSV
# probe table on stdout, and <out>/probes.json for the model-judged review
# tier (/render-audit). Composition judgment (rank, axis, species, optical
# centering) is deliberately NOT probed here — pretending it is grep-able is
# the failure mode the Window Classics retro documents. The probes catch the
# mechanically observable subset; /render-audit owns the rest.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER="$SCRIPT_DIR/lib/render-sweep.cjs"

BASE=""
SERVE_DIST=""
ROUTES="/"
WIDTHS="320,360,390,414,640,768,834,1024,1280,1440"
OUT="tmp/render-sweep"
PW_ROOT=""
CONFIG=""
STRICT=0
CHECK=0

while [ $# -gt 0 ]; do
  case "$1" in
    --base)       BASE="$2"; shift 2 ;;
    --serve-dist) SERVE_DIST="$2"; shift 2 ;;
    --routes)     ROUTES="$2"; shift 2 ;;
    --widths)     WIDTHS="$2"; shift 2 ;;
    --out)        OUT="$2"; shift 2 ;;
    --pw-root)    PW_ROOT="$2"; shift 2 ;;
    --config)     CONFIG="$2"; shift 2 ;;
    --strict)     STRICT=1; shift ;;
    --check)      CHECK=1; shift ;;
    --help|-h)    grep -E '^# ' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "render-sweep.sh: unknown option $1" >&2; exit 2 ;;
  esac
done

# --- availability -----------------------------------------------------------
unavailable() {
  echo "SKIP — render tier unavailable ($1). Default gates are unaffected; install playwright locally (npm i -D playwright && npx playwright install chromium) or point --pw-root at a project that has it."
  if [ "$STRICT" -eq 1 ] || [ "$CHECK" -eq 1 ]; then exit 3; fi
  exit 0
}

command -v node >/dev/null 2>&1 || unavailable "no node on PATH"

RESOLVE_ENV=""
if [ -n "$PW_ROOT" ]; then
  [ -d "$PW_ROOT/node_modules" ] || unavailable "--pw-root $PW_ROOT has no node_modules"
  RESOLVE_ENV="$PW_ROOT/node_modules"
fi
if ! NODE_PATH="${RESOLVE_ENV}" node -e "require.resolve('playwright')" >/dev/null 2>&1; then
  unavailable "playwright not resolvable$([ -n "$PW_ROOT" ] && echo " from $PW_ROOT")"
fi

if [ "$CHECK" -eq 1 ]; then
  echo "render tier available (node $(node --version), playwright resolvable$([ -n "$PW_ROOT" ] && echo " via $PW_ROOT"))"
  exit 0
fi

# --- config -----------------------------------------------------------------
if [ -n "$CONFIG" ]; then
  [ -f "$CONFIG" ] || { echo "render-sweep.sh: config not found: $CONFIG" >&2; exit 2; }
fi
if [ -z "$BASE" ] && [ -z "$SERVE_DIST" ] && [ -z "$CONFIG" ]; then
  echo "render-sweep.sh: need --base, --serve-dist, or --config (see --help)" >&2
  exit 2
fi

mkdir -p "$OUT"

NODE_PATH="${RESOLVE_ENV}" node "$DRIVER" \
  --base "$BASE" --serve-dist "$SERVE_DIST" --routes "$ROUTES" \
  --widths "$WIDTHS" --out "$OUT" --config "${CONFIG:-}" --strict "$STRICT"
rc=$?

if [ "$rc" -eq 1 ] && [ "$STRICT" -eq 0 ]; then
  # Probe failures are informational unless --strict: the table said what
  # failed; the model-judged tier decides what it means.
  exit 0
fi
exit "$rc"

#!/usr/bin/env bash
# install-git-hooks.sh — installs a pre-commit hook that enforces the axioms
# on every commit. This is the real-teeth enforcement path — Claude Code's
# PostToolUse hook only fires inside Claude sessions, but a git pre-commit
# hook runs on every `git commit` from any tool.
#
# Usage (from the root of the project you want to protect):
#   bash path/to/every-layout-plugin/bin/install-git-hooks.sh [--force]
#
# With --force, overwrites an existing pre-commit hook. Without, aborts if
# one already exists.

set -euo pipefail

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

# Locate the plugin root (this script is in <plugin-root>/bin/)
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Locate the target project root (must be a git repo)
TARGET_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$TARGET_ROOT" ]; then
  echo "error: run this from inside a git repository" >&2
  exit 2
fi

HOOK_PATH="$TARGET_ROOT/.git/hooks/pre-commit"

if [ -f "$HOOK_PATH" ] && [ "$FORCE" -ne 1 ]; then
  echo "error: pre-commit hook already exists at $HOOK_PATH" >&2
  echo "  re-run with --force to overwrite, or wire the plugin's check into your existing hook:" >&2
  echo "    $PLUGIN_ROOT/bin/css-strict.sh \${CSS_DIR:-src/styles}" >&2
  echo "    # optionally: $PLUGIN_ROOT/bin/js-budget.sh \${DIST_DIR:-dist}" >&2
  exit 1
fi

cat > "$HOOK_PATH" <<EOF
#!/usr/bin/env bash
# Pre-commit hook installed by every-layout-plugin.
# Runs axiom gate + JS budget check on each commit.
# Blocks the commit if any axiom is violated.
#
# To bypass for emergency commits (strongly discouraged), use:
#   git commit --no-verify

set -euo pipefail

PLUGIN_ROOT="$PLUGIN_ROOT"

# Configure these to match your project layout
CSS_DIR="\${EVERY_LAYOUT_CSS_DIR:-src/styles}"
DIST_DIR="\${EVERY_LAYOUT_DIST_DIR:-dist}"

echo "[every-layout] axiom gate: \$CSS_DIR"
if [ -d "\$CSS_DIR" ]; then
  "\$PLUGIN_ROOT/bin/css-strict.sh" "\$CSS_DIR" || {
    echo ""
    echo "[every-layout] commit blocked — CSS axioms violated."
    echo "  See skills/css-layout-engine/references/axioms.md for the canonical rules."
    echo "  To register an intentional exception, add an entry to escapes.md."
    echo "  To bypass this check (emergency only), use: git commit --no-verify"
    exit 1
  }
else
  echo "[every-layout] CSS dir \$CSS_DIR not found — skipping axiom gate."
fi

# JS budget only runs if a build output exists. In CI, run \`npm run build\` first.
if [ -d "\$DIST_DIR" ]; then
  echo "[every-layout] JavaScript budget: \$DIST_DIR"
  "\$PLUGIN_ROOT/bin/js-budget.sh" "\$DIST_DIR" || {
    echo ""
    echo "[every-layout] commit blocked — JavaScript budget exceeded."
    echo "  See skills/css-design-system/references/performance-rules.md."
    echo "  To register an intentional exception: escapes.md category ESC_JS_EXCESS"
    exit 1
  }
fi

exit 0
EOF

chmod +x "$HOOK_PATH"

echo "Installed pre-commit hook at: $HOOK_PATH"
echo "It will run on every 'git commit' and block commits that violate the axioms."
echo ""
echo "Configuration (optional — set in your shell or CI):"
echo "  EVERY_LAYOUT_CSS_DIR    (default: src/styles)"
echo "  EVERY_LAYOUT_DIST_DIR   (default: dist)"
echo ""
echo "For CI, run the scripts directly in your GitHub Actions / GitLab CI pipeline:"
echo "  $PLUGIN_ROOT/bin/css-strict.sh src/styles"
echo "  $PLUGIN_ROOT/bin/js-budget.sh dist"

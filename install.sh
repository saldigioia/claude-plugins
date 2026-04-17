#!/usr/bin/env bash
# Rare Data Club — Claude Code plugins bootstrap.
# Adds the marketplace and installs every plugin in it.
set -euo pipefail

MARKETPLACE_SOURCE="saldigioia/claude-plugins"
MARKETPLACE_NAME="rare-data-club"
PLUGINS=(
  "every-layout"
  "wayback-archive"
)

if ! command -v claude >/dev/null 2>&1; then
  echo "error: 'claude' CLI not found on PATH. Install Claude Code first: https://docs.claude.com/en/docs/claude-code/quickstart" >&2
  exit 1
fi

echo "Adding marketplace: ${MARKETPLACE_SOURCE}"
claude plugin marketplace add "${MARKETPLACE_SOURCE}"

for plugin in "${PLUGINS[@]}"; do
  echo "Installing ${plugin}@${MARKETPLACE_NAME}"
  claude plugin install "${plugin}@${MARKETPLACE_NAME}"
done

echo
echo "Done. Installed plugins:"
printf '  - %s@%s\n' "${PLUGINS[@]/%/}" | sed "s/\$/@${MARKETPLACE_NAME}/"

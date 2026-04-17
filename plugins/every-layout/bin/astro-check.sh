#!/usr/bin/env bash
# Run Astro type checking with formatted output
# Usage: astro-check.sh [project-dir]

set -euo pipefail

PROJECT_DIR="${1:-.}"

if [ ! -f "$PROJECT_DIR/astro.config.mjs" ] && [ ! -f "$PROJECT_DIR/astro.config.ts" ]; then
  echo "Error: No astro.config found in $PROJECT_DIR"
  echo "Usage: astro-check.sh [project-dir]"
  exit 1
fi

echo "Running Astro type check in $PROJECT_DIR..."
echo "---"

cd "$PROJECT_DIR"
npx astro check 2>&1 | while IFS= read -r line; do
  # Highlight errors in output
  case "$line" in
    *error*|*Error*)
      printf "\033[31m%s\033[0m\n" "$line"
      ;;
    *warning*|*Warning*)
      printf "\033[33m%s\033[0m\n" "$line"
      ;;
    *)
      echo "$line"
      ;;
  esac
done

EXIT_CODE=${PIPESTATUS[0]}

echo "---"
if [ "$EXIT_CODE" -eq 0 ]; then
  echo "Astro check passed."
else
  echo "Astro check failed with errors."
fi

exit "$EXIT_CODE"

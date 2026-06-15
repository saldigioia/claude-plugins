#!/usr/bin/env bash
#
# Commit and push all updates in a GitHub-hosted plugin marketplace repository.
#
# Usage:
#   ./publish.sh
#   ./publish.sh "Update marketplace plugins"
#
# The script:
#   - Locates the repository root automatically.
#   - Verifies that the repository has a GitHub remote.
#   - Verifies the marketplace manifest accounts for every plugin present:
#       every plugins/<dir> with a .claude-plugin/plugin.json must be registered
#       in .claude-plugin/marketplace.json (and every registered entry must exist
#       and its declared name must match the plugin's own manifest).
#       Override the gate with ALLOW_PLUGIN_DRIFT=1 if you really must.
#   - Shows modified, deleted, and untracked files.
#   - Stages every change in the repository.
#   - Shows the exact staged diff before committing.
#   - Commits with an argument or interactively entered message.
#   - Pushes the current branch to its configured upstream.
#   - Establishes origin/<branch> as the upstream when needed.
#
# Run this script from anywhere inside the marketplace repository.

set -euo pipefail

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

# Cross-check the marketplace manifest against the plugins actually present on disk.
# Fails (non-zero) on any drift: an unregistered plugin, a registered plugin whose
# directory is missing or carries no manifest, or a name mismatch. Prints a status
# table either way so the full plugin roster is always visible before publishing.
verify_marketplace_plugins() {
    local manifest=".claude-plugin/marketplace.json"
    [[ -f "$manifest" ]] || die "Marketplace manifest not found at $manifest."
    command -v python3 >/dev/null 2>&1 ||
        die "python3 is required to verify the marketplace manifest."

    printf '\n%s\n' '=== Verifying marketplace plugins ==='
    python3 - <<'PY'
import json, os, sys

MANIFEST = ".claude-plugin/marketplace.json"
PLUGINS_DIR = "plugins"

try:
    with open(MANIFEST) as fh:
        data = json.load(fh)
except Exception as exc:
    print(f"Cannot read {MANIFEST}: {exc}", file=sys.stderr)
    sys.exit(1)

# registered: normalized source dir -> declared name
registered = {}
for entry in data.get("plugins", []):
    src = entry.get("source", "")
    if not src:
        print(f"Manifest entry {entry.get('name', '?')!r} has no 'source'.", file=sys.stderr)
        sys.exit(1)
    registered[os.path.normpath(src)] = entry.get("name", "")

# present: every plugins/<dir> that carries a plugin manifest
present = {}
if os.path.isdir(PLUGINS_DIR):
    for name in sorted(os.listdir(PLUGINS_DIR)):
        pdir = os.path.join(PLUGINS_DIR, name)
        pm = os.path.join(pdir, ".claude-plugin", "plugin.json")
        if os.path.isfile(pm):
            try:
                with open(pm) as fh:
                    present[os.path.normpath(pdir)] = json.load(fh).get("name", "")
            except Exception:
                present[os.path.normpath(pdir)] = None  # unreadable manifest

problems = []
for pdir, pname in present.items():
    if pdir not in registered:
        problems.append(f"UNREGISTERED: {pdir} (plugin {pname!r}) is present but absent from {MANIFEST}")
for src, rname in registered.items():
    if src not in present:
        if not os.path.isdir(src):
            problems.append(f"MISSING: {rname!r} -> {src} is registered but the directory does not exist")
        else:
            problems.append(f"NOT-A-PLUGIN: {rname!r} -> {src} has no .claude-plugin/plugin.json")
    elif present[src] is None:
        problems.append(f"UNREADABLE: {src}/.claude-plugin/plugin.json could not be parsed")
    elif rname and present[src] and rname != present[src]:
        problems.append(f"NAME-MISMATCH: {src} declares {present[src]!r} but the manifest registers {rname!r}")

for d in sorted(set(registered) | set(present)):
    ok = d in registered and d in present and present.get(d) == registered.get(d)
    label = present.get(d) or registered.get(d) or "?"
    print(f"  [{' ' if ok else '!'}] {label:<22} {d}  ({'ok' if ok else 'DRIFT'})")
print(f"\n  registered: {len(registered)}   present: {len(present)}")

if problems:
    print("\nPlugin accounting problems:", file=sys.stderr)
    for p in problems:
        print(f"  - {p}", file=sys.stderr)
    sys.exit(1)

print("\nAll plugins present are accounted for in the marketplace manifest.")
PY
}

command -v git >/dev/null 2>&1 || die "Git is not installed or not in PATH."

# Locate and enter the repository root.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" ||
    die "This script must be run from inside a Git repository."

cd "$REPO_ROOT"

# Reject detached HEAD states because there is no normal branch to push.
BRANCH="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" ||
    die "HEAD is detached. Check out a branch before publishing."

REMOTE="${GIT_REMOTE:-origin}"

git remote get-url "$REMOTE" >/dev/null 2>&1 ||
    die "Remote '$REMOTE' does not exist."

REMOTE_URL="$(git remote get-url "$REMOTE")"

case "$REMOTE_URL" in
    *github.com* | *githubusercontent.com*)
        ;;
    *)
        printf 'Warning: remote %q does not appear to point to GitHub:\n  %s\n' \
            "$REMOTE" "$REMOTE_URL"
        read -r -p "Continue anyway? [y/N] " answer
        case "$answer" in
            y | Y | yes | YES)
                ;;
            *)
                exit 1
                ;;
        esac
        ;;
esac

# Remove a stale lock only after confirming no Git process is using it.
if [[ -f .git/index.lock ]]; then
    if pgrep -f '[g]it' >/dev/null 2>&1; then
        die ".git/index.lock exists and a Git process appears to be running."
    fi

    printf 'Removing stale .git/index.lock\n'
    rm -f .git/index.lock
fi

printf '\nRepository: %s\n' "$REPO_ROOT"
printf 'Remote:     %s (%s)\n' "$REMOTE" "$REMOTE_URL"
printf 'Branch:     %s\n' "$BRANCH"

# Refuse to publish a marketplace whose manifest disagrees with the plugins on disk.
if [[ "${ALLOW_PLUGIN_DRIFT:-0}" == "1" ]]; then
    printf '\nALLOW_PLUGIN_DRIFT=1 set — skipping marketplace plugin verification.\n'
else
    verify_marketplace_plugins ||
        die "Marketplace manifest is out of sync with plugins/ (see above). Register/remove the plugin, or re-run with ALLOW_PLUGIN_DRIFT=1 to override."
fi

if [[ -z "$(git status --porcelain=v1 --untracked-files=all)" ]]; then
    printf 'Nothing to publish. The working tree is clean.\n'
    exit 0
fi

printf '%s\n' '=== Working-tree changes ==='
git status --short --branch --untracked-files=all

printf '\n%s\n' '=== Staging all changes ==='
git add --all

if git diff --cached --quiet; then
    printf 'Nothing remains staged for commit.\n'
    exit 0
fi

printf '\n%s\n' '=== Staged summary ==='
git diff --cached --stat

printf '\n%s\n' '=== Staged file status ==='
git diff --cached --name-status

printf '\n%s\n' '=== Staged diff ==='
git diff --cached --color=always | "${PAGER:-less}" -R

COMMIT_MESSAGE="${*:-}"

if [[ -z "$COMMIT_MESSAGE" ]]; then
    printf '\n'
    read -r -p "Commit subject: " COMMIT_MESSAGE
fi

[[ -n "${COMMIT_MESSAGE//[[:space:]]/}" ]] ||
    die "The commit message cannot be empty."

printf '\nCommit message:\n  %s\n\n' "$COMMIT_MESSAGE"
read -r -p "Commit and push every staged change? [y/N] " answer

case "$answer" in
    y | Y | yes | YES)
        ;;
    *)
        printf '%s\n' \
            "Aborted. Changes remain staged; run 'git reset' to unstage them."
        exit 1
        ;;
esac

git commit -m "$COMMIT_MESSAGE"

printf '\n=== Pushing %s to %s ===\n' "$BRANCH" "$REMOTE"

if git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' \
    >/dev/null 2>&1; then
    git push
else
    git push --set-upstream "$REMOTE" "$BRANCH"
fi

printf '\nPublished successfully.\n'
printf 'Repository: %s\n' "$REMOTE_URL"
printf 'Branch:     %s\n' "$BRANCH"
printf 'Commit:     %s\n' "$(git rev-parse --short HEAD)"
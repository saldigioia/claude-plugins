#!/usr/bin/env python3
"""
hook_guard.py — PreToolUse guard for catalog-forge.

Structurally enforces the prime directive: `metadata.json` is read-only POS truth.
The canonical record is built FROM it; it is never written or merged into.

Reads the Claude Code hook payload as JSON on stdin. If the tool is about to write or
edit a product `metadata.json`, it denies the call (exit 2 — the stderr reason is shown
to the model). Everything else passes through (exit 0). This is the proposal's
"enforce it structurally" rule made real, so the contract no longer depends on the
skill text being remembered.
"""
import json
import os
import sys

REASON = (
    "catalog-forge: refused — metadata.json is read-only POS truth and is never written. "
    "The canonical record is built FROM it (assemble in canonical.json, or record curator "
    "notes in curation.json). See the canonical-collections skill's prime directive."
)


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        # Never block on a malformed payload — fail open so unrelated edits aren't broken.
        return 0

    ti = payload.get("tool_input") or {}
    # Write/Edit use file_path; cover paths[] defensively for any multi-file variant.
    candidates = [ti.get("file_path")]
    candidates += ti.get("file_paths") or []
    for fp in candidates:
        if not fp:
            continue
        if os.path.basename(str(fp)) == "metadata.json":
            print(REASON, file=sys.stderr)
            return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())

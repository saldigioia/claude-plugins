"""
Dotenv auto-source for wayback-archive.

Called at the top of every entry-point script (bootstrap.py, run_stage.py,
fetch_archive.py) so users who copy tools/.env.example to tools/.env don't
also have to `export` every variable into their shell.

Search order, first match wins per variable (never overrides already-set
environment variables):

  1. <repo_root>/tools/.env       — the documented location per README.md
  2. <repo_root>/.env             — repo-root convention
  3. <repo_root>/tools/wayback_cdx/.env  — the CDX tool's legacy location
  4. <cwd>/.env                   — when invoked from a subdirectory

Silent if python-dotenv is not installed; proxy creds can still be set
via the shell in that case. Returns a list of the paths actually loaded
so callers can report which files contributed.
"""
from __future__ import annotations

from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parents[2]

_SEARCH_PATHS = [
    _REPO_ROOT / "tools" / ".env",
    _REPO_ROOT / ".env",
    _REPO_ROOT / "tools" / "wayback_cdx" / ".env",
    Path.cwd() / ".env",
]

_loaded_paths: list[Path] = []
_loaded = False


def load_env() -> list[Path]:
    """Load any dotenv files that exist. Idempotent; only runs once per process."""
    global _loaded
    if _loaded:
        return list(_loaded_paths)
    _loaded = True

    try:
        from dotenv import load_dotenv  # type: ignore[import-untyped]
    except ImportError:
        return []

    seen: set[Path] = set()
    for path in _SEARCH_PATHS:
        try:
            resolved = path.resolve()
        except OSError:
            continue
        if resolved in seen or not resolved.exists():
            continue
        seen.add(resolved)
        load_dotenv(resolved, override=False)
        _loaded_paths.append(resolved)

    return list(_loaded_paths)


def loaded_paths() -> list[Path]:
    """Return which dotenv files were actually loaded this process."""
    return list(_loaded_paths)


__all__ = ["load_env", "loaded_paths"]

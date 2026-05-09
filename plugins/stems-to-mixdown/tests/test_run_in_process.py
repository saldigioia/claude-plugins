"""End-to-end test of the in-process orchestrator (run.py).

After Phase 3, run.py calls each pass's main() directly via _run_pass()
instead of subprocess. This test exercises the full pipeline through
that path on the mono-stems fixture and asserts the outputs land where
expected. The point is to lock in the contract: run.main() is callable
from Python, not just as a CLI script, and the in-process call shape
doesn't regress to subprocess.
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from stems_to_mixdown import run as run_mod  # noqa: E402


def _invoke_run(argv: list[str]) -> int:
    """Call run.main() with injected argv, return exit code."""
    old_argv = sys.argv
    try:
        sys.argv = ["run"] + argv
        try:
            return run_mod.main()
        except SystemExit as e:
            return e.code if isinstance(e.code, int) else 0
    finally:
        sys.argv = old_argv


def test_run_in_process_mono_stems(tmp_path):
    """run.main() drives the whole pipeline via in-process function calls."""
    fixture = REPO / "tests" / "fixtures" / "mono-stems"
    output_dir = tmp_path / "out"

    rc = _invoke_run([
        "--dir", str(fixture),
        "--output-dir", str(output_dir),
        "--yes",
        "--archival",
    ])
    assert rc == 0, f"run.main() returned {rc}"

    expected = [
        output_dir / "mono-stems_acapella.flac",
        output_dir / "mono-stems_acapella.flac.log.md",
        output_dir / "mono-stems_instrumental.flac",
        output_dir / "mono-stems_instrumental.flac.log.md",
    ]
    for p in expected:
        assert p.is_file(), f"missing expected output: {p}"

    artifacts = output_dir / ".s2m" / "run"
    for name in ("identify.json", "analysis.json", "plan.json",
                "mix.json", "verify.json"):
        assert (artifacts / name).is_file(), f"missing artifact: {name}"


def test_run_in_process_with_master(tmp_path):
    """Master-reference path produces the reference bundle through the
    in-process orchestrator."""
    fixture = REPO / "tests" / "fixtures" / "with-master"
    output_dir = tmp_path / "out"

    rc = _invoke_run([
        "--dir", str(fixture),
        "--output-dir", str(output_dir),
        "--yes",
        "--archival",
    ])
    assert rc == 0, f"run.main() returned {rc}"

    bundle = output_dir / "reference-bundle"
    assert bundle.is_dir(), "reference-bundle directory missing"
    for role in ("master", "instrumental", "acapella"):
        assert (bundle / f"with-master_{role}.flac").is_file(), (
            f"bundle missing {role!r} member"
        )
    assert (bundle / "bundle.log.md").is_file()

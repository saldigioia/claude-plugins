"""Perceptual-invariant baselines.

Runs each fixture through the pipeline (--archival path so we test the
unity-sum behavior; the normalized v1.3 default exercises a different
code path that's verified by test_master_reference.sh and
run-all-passes.sh). For every output, asserts:

- Probe properties (rate, channels, codec, bit depth) match the plan.
- True peak is at or below the planned ceiling within epsilon.

For the with-master fixture, also asserts the recombine null residual
is within the Cmd-19 "pass" threshold (≤ -60 dBTP — the loose
smell-vs-fail boundary; the strict ≤ -90 dBTP within-dither-noise
threshold is verified by test_master_reference.sh's reference battery).

This is the env-independent gate. The MD5 baselines in
expected-audio-md5s.txt are advisory drift detection.
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(REPO / "tests"))

from _invariants import (  # noqa: E402
    assert_format,
    assert_recombine_null,
    assert_true_peak_below,
)


FIXTURES_WITH_GROUPS = [
    # (fixture_dir_name, expected groups)
    ("mono-stems", ["acapella", "instrumental"]),
    ("mixed-rates", ["acapella", "instrumental"]),
    ("dirty-inputs", ["acapella", "instrumental"]),
    ("24-in-32", ["acapella"]),  # only one classified vocal stem
    ("with-master", ["acapella", "instrumental"]),
]


def _run_pipeline_archival(fixture_dir: Path, out_root: Path) -> dict:
    """Run analyze → plan --archival → mix on a fixture. Returns the
    parsed plan.json so caller can introspect format / output paths."""
    out_root.mkdir(parents=True, exist_ok=True)
    a_json = out_root / "analysis.json"
    p_json = out_root / "plan.json"
    mix_dir = out_root / "mixdowns"

    r = subprocess.run(
        ["python3", "-m", "stems_to_mixdown.analyze",
         "--dir", str(fixture_dir), "--force"],
        capture_output=True, text=True, cwd=str(REPO),
    )
    assert r.returncode == 0, f"analyze failed: {r.stderr[-500:]}"
    a_json.write_text(r.stdout)

    r = subprocess.run(
        ["python3", "-m", "stems_to_mixdown.plan",
         "--analysis", str(a_json),
         "--output-dir", str(mix_dir),
         "--archival"],
        capture_output=True, text=True, cwd=str(REPO),
    )
    assert r.returncode == 0, f"plan failed: {r.stderr[-500:]}"
    p_json.write_text(r.stdout)

    r = subprocess.run(
        ["python3", "-m", "stems_to_mixdown.mix",
         "--plan", str(p_json), "--yes"],
        capture_output=True, text=True, cwd=str(REPO),
    )
    assert r.returncode == 0, f"mix failed: {r.stderr[-500:]}"

    return json.loads(p_json.read_text())


@pytest.mark.parametrize("fixture,expected_groups", FIXTURES_WITH_GROUPS)
def test_outputs_match_planned_format(fixture, expected_groups, tmp_path):
    """Every group's output must probe to the format the plan declared.
    No silent depth / rate / channel drift between plan and execution.
    """
    fixture_dir = REPO / "tests" / "fixtures" / fixture
    plan = _run_pipeline_archival(fixture_dir, tmp_path)

    plan_groups = {g["name"]: g for g in plan["groups"]}
    for group_name in expected_groups:
        assert group_name in plan_groups, (
            f"{fixture}: plan missing expected group {group_name!r}"
        )
        g = plan_groups[group_name]
        out_path = Path(g["output_path"])
        assert out_path.is_file(), f"{fixture}/{group_name}: output missing at {out_path}"

        fmt = g["format"]
        bits = fmt["depth"] if fmt["depth"] not in (0, None) else None
        assert_format(
            out_path,
            rate=fmt["rate"],
            channels=fmt["channels"],
            bits=bits,
        )


@pytest.mark.parametrize("fixture,expected_groups", FIXTURES_WITH_GROUPS)
def test_outputs_below_true_peak_ceiling(fixture, expected_groups, tmp_path):
    """No clipping. The unity-sum path can produce true peaks up to ~0
    dBTP; the planned pre-attenuation should land us comfortably under.
    Use a generous ceiling here (0.5 dBTP epsilon) — the strict
    -1 dBTP target is enforced by the normalized path, not archival.
    """
    fixture_dir = REPO / "tests" / "fixtures" / fixture
    plan = _run_pipeline_archival(fixture_dir, tmp_path)

    for g in plan["groups"]:
        if g["name"] not in expected_groups:
            continue
        out_path = Path(g["output_path"])
        # Archival outputs aren't loudness-conditioned; the only invariant
        # is "no clipping past 0 dBTP". The pre-attenuation policy lands
        # the sum below 0; we assert with a tolerant epsilon.
        assert_true_peak_below(out_path, max_dbtp=0.0, epsilon=0.5)


def test_with_master_recombine_null(tmp_path):
    """For the with-master fixture, the unity-sum bundle produces a
    recombine null `(instrumental + acapella) - master` whose residual
    must be within the Cmd-19 pass threshold.

    The strict -90 dBTP within-dither-noise check is verified by
    test_master_reference.sh's reference battery. Here we use the
    loose -60 dBTP smell-vs-fail boundary as a sanity check that the
    bundle is structurally consistent with the master.
    """
    fixture_dir = REPO / "tests" / "fixtures" / "with-master"
    plan = _run_pipeline_archival(fixture_dir, tmp_path)

    rb = plan.get("reference_bundle")
    assert rb is not None, "with-master fixture should plan a reference bundle"

    members = {m["role"]: Path(m["output_path"]) for m in rb["members"]}
    for role in ("master", "instrumental", "acapella"):
        assert role in members, f"bundle missing {role!r} member in plan"

    assert_recombine_null(
        instrumental=members["instrumental"],
        acapella=members["acapella"],
        master=members["master"],
        tmpdir=tmp_path,
        threshold_dbtp=-60.0,
    )

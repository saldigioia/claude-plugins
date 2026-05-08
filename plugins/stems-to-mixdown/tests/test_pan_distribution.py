"""Pan-coefficient + auto-pan distribution tests (v1.3 / Cmd 20).

Run via:
    python3 -m pytest tests/test_pan_distribution.py -v
or:
    python3 tests/test_pan_distribution.py
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))
from stems_to_mixdown.plan import (  # noqa: E402
    auto_pan_for_group, auto_pan_positions,
    pan_coefficients, resolve_pan_map,
)


def _stem(name, channels=1, classification="other"):
    return {"filename": name, "channels": channels, "classification": classification}


# --- pan_coefficients --------------------------------------------------------

def _close(a: float, b: float, tol: float = 1e-3) -> bool:
    return abs(a - b) <= tol


PAN_COEF_CASES = [
    # (pan_position, pan_law_db, expected_L, expected_R, comment)
    (0.0, -3.0, 10 ** (-3.0 / 20), 10 ** (-3.0 / 20), "centered, default pan law"),
    (-1.0, -3.0, 10 ** (-3.0 / 20) * math.sqrt(2), 0.0, "fully left, default pan law"),
    (1.0, -3.0, 0.0, 10 ** (-3.0 / 20) * math.sqrt(2), "fully right, default pan law"),
    (0.0, -2.5, 10 ** (-2.5 / 20), 10 ** (-2.5 / 20), "centered, PT pan law"),
    (0.0, 0.0, 1.0, 1.0, "centered, 0 dB pan law (degenerate)"),
    (0.5, -3.0, None, None, "right-of-center, sanity bounds"),
]


def test_pan_coefficients_table():
    failures = []
    for p, law, want_l, want_r, comment in PAN_COEF_CASES:
        got_l, got_r = pan_coefficients(p, law)
        # Sanity: coefficients always non-negative
        if got_l < 0 or got_r < 0:
            failures.append(f"{comment}: negative coef ({got_l}, {got_r})")
        if want_l is not None and not _close(got_l, want_l):
            failures.append(f"{comment}: L expected {want_l}, got {got_l}")
        if want_r is not None and not _close(got_r, want_r):
            failures.append(f"{comment}: R expected {want_r}, got {got_r}")
    return failures


# --- auto_pan_positions ------------------------------------------------------

AUTO_POSITION_CASES = [
    (1, [0.0]),
    (2, [-0.5, 0.5]),
    (3, [-0.7, 0.0, 0.7]),
    (4, [-0.7, -0.7 / 3, 0.7 / 3, 0.7]),
]


def test_auto_pan_positions_table():
    failures = []
    for n, want in AUTO_POSITION_CASES:
        got = auto_pan_positions(n)
        if len(got) != len(want):
            failures.append(f"n={n}: length mismatch ({len(got)} vs {len(want)})")
            continue
        for g, w in zip(got, want):
            if not _close(g, w):
                failures.append(f"n={n}: {got} vs expected {want}")
                break
    return failures


# --- auto_pan_for_group: vocals/bass center, others spread ------------------

def test_auto_pan_vocals_center():
    stems = [_stem("vox.wav", classification="vocal"),
             _stem("bass.wav", classification="bass"),
             _stem("perc1.wav", classification="drums"),
             _stem("perc2.wav", classification="drums"),
             _stem("perc3.wav", classification="drums")]
    out = auto_pan_for_group(stems)
    failures = []
    if out["vox.wav"] != 0.0:
        failures.append(f"vocal not centered: {out['vox.wav']}")
    if out["bass.wav"] != 0.0:
        failures.append(f"bass not centered: {out['bass.wav']}")
    perc_positions = [out["perc1.wav"], out["perc2.wav"], out["perc3.wav"]]
    if not all(_close(p, w) for p, w in zip(perc_positions, [-0.7, 0.0, 0.7])):
        failures.append(f"3 percussion not spread to ±0.7/0: {perc_positions}")
    return failures


# --- resolve_pan_map: precedence (manifest > auto > default) -----------------

def test_pan_map_manifest_wins():
    stems = [_stem("a.wav"), _stem("b.wav"), _stem("c.wav")]
    manifest = {"pan": {"a.wav": -50, "b.wav": 50}}
    out, src = resolve_pan_map(manifest, stems, use_auto_pan=True)
    failures = []
    if out["a.wav"] != -0.5:
        failures.append(f"manifest -50 → {out['a.wav']} (expected -0.5)")
    if out["b.wav"] != 0.5:
        failures.append(f"manifest 50 → {out['b.wav']}  (expected 0.5)")
    # c was not in manifest; auto_pan_for_group with 3 'other' stems → ±0.7/0
    # but auto only fills the slot 'c' didn't get a manifest value, while
    # auto_pan_for_group ran against ALL 3 stems. So 'c' gets one of the auto
    # positions. We only check it's a sensible number here.
    if not (-1.0 <= out["c.wav"] <= 1.0):
        failures.append(f"c (auto) out of range: {out['c.wav']}")
    if src != "manifest+auto":
        failures.append(f"source label = {src!r}, expected 'manifest+auto'")
    return failures


def test_pan_map_default_centers_mono():
    stems = [_stem("a.wav"), _stem("b.wav", channels=2)]  # mixed mono/stereo
    out, src = resolve_pan_map({}, stems, use_auto_pan=False)
    failures = []
    if out.get("a.wav") != 0.0:
        failures.append(f"mono default not 0.0: {out.get('a.wav')}")
    if "b.wav" in out:
        failures.append(f"stereo stem should not be in pan map: {out!r}")
    if src != "default":
        failures.append(f"source label = {src!r}, expected 'default'")
    return failures


def run_all() -> list[str]:
    fails: list[str] = []
    fails += test_pan_coefficients_table()
    fails += test_auto_pan_positions_table()
    fails += test_auto_pan_vocals_center()
    fails += test_pan_map_manifest_wins()
    fails += test_pan_map_default_centers_mono()
    return fails


# pytest hooks ---------------------------------------------------------------

try:
    import pytest

    def test_pan_coefficients():
        fails = test_pan_coefficients_table()
        assert not fails, "; ".join(fails)

    def test_auto_pan_positions():
        fails = test_auto_pan_positions_table()
        assert not fails, "; ".join(fails)

    def test_auto_pan_for_group():
        fails = test_auto_pan_vocals_center()
        assert not fails, "; ".join(fails)

    def test_resolve_pan_map_manifest_wins():
        fails = test_pan_map_manifest_wins()
        assert not fails, "; ".join(fails)

    def test_resolve_pan_map_default():
        fails = test_pan_map_default_centers_mono()
        assert not fails, "; ".join(fails)

except ImportError:
    pass


if __name__ == "__main__":
    fails = run_all()
    if fails:
        for f in fails:
            print(f"FAIL: {f}")
        sys.exit(1)
    print("OK — pan distribution tests passed")

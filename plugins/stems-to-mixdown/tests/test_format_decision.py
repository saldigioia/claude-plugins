"""Table-driven tests for plan.decide_output_format.

Covers every row of the matrix in references/format-decisions.md plus the
manifest-override and FLAC-depth-clamp cases. Run via:

    python3 -m pytest tests/test_format_decision.py -v

or, without pytest installed, plain `python3 tests/test_format_decision.py`
which falls back to a tiny in-process runner.
"""

from __future__ import annotations

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from plan import decide_output_format, resolve_pan_law, ALLOWED_PAN_LAWS  # noqa: E402


def stem(*, rate: int, depth: int, channels: int = 2, lossy: bool = False) -> dict:
    """Minimal StemInfo-shaped dict for decide_output_format input."""
    return {
        "filename": f"sine_{rate}_{depth}.wav",
        "is_lossy": lossy,
        "sample_rate": rate,
        "bit_depth": 0 if lossy else depth,
        "channels": channels,
    }


CASES = [
    # ---- All lossless, uniform ------------------------------------------------
    (
        "all_lossless_uniform_24_48k",
        [stem(rate=48000, depth=24), stem(rate=48000, depth=24)],
        None,
        {"format": "flac", "rate": 48000, "depth": 24, "lie": False},
    ),
    (
        "all_lossless_uniform_16_44k",
        [stem(rate=44100, depth=16), stem(rate=44100, depth=16)],
        None,
        {"format": "flac", "rate": 44100, "depth": 16, "lie": False},
    ),
    # ---- Mixed depths: smallest wins ------------------------------------------
    (
        "mixed_depths_smallest_wins",
        [stem(rate=48000, depth=24), stem(rate=48000, depth=16)],
        None,
        {"format": "flac", "rate": 48000, "depth": 16, "lie": False},
    ),
    # ---- Mixed rates: highest wins --------------------------------------------
    (
        "mixed_rates_highest_wins",
        [stem(rate=48000, depth=24), stem(rate=96000, depth=24)],
        None,
        {"format": "flac", "rate": 96000, "depth": 24, "lie": False},
    ),
    # ---- 32-bit lossless: FLAC clamps to 24 (Phase 3 fix) ---------------------
    (
        "32bit_input_clamps_to_24_for_flac",
        [stem(rate=48000, depth=32)],
        None,
        {"format": "flac", "rate": 48000, "depth": 24, "lie": False},
    ),
    # ---- Lossy in chain: 16 / 44.1 cap ----------------------------------------
    (
        "any_lossy_caps_to_44k_16",
        [stem(rate=96000, depth=24), stem(rate=44100, depth=0, lossy=True)],
        None,
        {"format": "flac", "rate": 44100, "depth": 16, "lie": False},
    ),
    # ---- Manifest force: rate higher than source = lie ------------------------
    (
        "manifest_force_higher_rate_is_lie",
        [stem(rate=44100, depth=16)],
        {"rate": 96000},
        {"format": "flac", "rate": 96000, "depth": 16, "lie": True},
    ),
    # ---- Manifest force: 24-bit out from lossy = lie --------------------------
    (
        "manifest_force_24_from_lossy",
        [stem(rate=44100, depth=0, lossy=True)],
        {"depth": 24},
        {"format": "flac", "rate": 44100, "depth": 24, "lie": True},
    ),
    # ---- Manifest format MP3 ---------------------------------------------------
    (
        "manifest_format_mp3",
        [stem(rate=44100, depth=16)],
        {"format": "mp3"},
        {"format": "mp3", "rate": 44100, "depth": 0, "lie": False},
    ),
    # ---- Mono input: depth/rate path unchanged --------------------------------
    (
        "mono_input_24_48k",
        [stem(rate=48000, depth=24, channels=1)],
        None,
        {"format": "flac", "rate": 48000, "depth": 24, "lie": False},
    ),
]


def assert_matches(actual: dict, expected: dict, label: str) -> None:
    for key, want in expected.items():
        got = actual.get(key)
        assert got == want, f"{label}: {key} = {got!r}, expected {want!r}"


def run_format_cases() -> list[str]:
    failures: list[str] = []
    for name, group_stems, manifest_output, expected in CASES:
        try:
            fmt = decide_output_format(group_stems, manifest_output)
            assert_matches(fmt, expected, name)
        except AssertionError as e:
            failures.append(str(e))
    return failures


def run_pan_law_cases() -> list[str]:
    failures: list[str] = []
    # Default
    pl, was_default = resolve_pan_law(None)
    if (pl, was_default) != (-3.0, True):
        failures.append(f"resolve_pan_law(None) = {(pl, was_default)}, expected (-3.0, True)")
    # Explicit allowed values
    for v in ALLOWED_PAN_LAWS:
        pl, was_default = resolve_pan_law({"pan_law": v})
        if (pl, was_default) != (v, False):
            failures.append(f"resolve_pan_law(pan_law={v}) = {(pl, was_default)}")
    # Disallowed value should raise SystemExit
    try:
        resolve_pan_law({"pan_law": -1.5})
    except SystemExit:
        pass
    else:
        failures.append("resolve_pan_law(pan_law=-1.5) should have raised SystemExit")
    return failures


# pytest hooks --------------------------------------------------------------

try:
    import pytest

    @pytest.mark.parametrize("case", CASES, ids=lambda c: c[0])
    def test_format_decision(case):
        name, group_stems, manifest_output, expected = case
        fmt = decide_output_format(group_stems, manifest_output)
        assert_matches(fmt, expected, name)

    def test_pan_law_default():
        pl, was_default = resolve_pan_law(None)
        assert (pl, was_default) == (-3.0, True)

    @pytest.mark.parametrize("v", ALLOWED_PAN_LAWS)
    def test_pan_law_allowed(v):
        pl, was_default = resolve_pan_law({"pan_law": v})
        assert (pl, was_default) == (v, False)

    def test_pan_law_disallowed_raises():
        with pytest.raises(SystemExit):
            resolve_pan_law({"pan_law": -1.5})

except ImportError:
    pass


# Standalone fallback -------------------------------------------------------

if __name__ == "__main__":
    fails = run_format_cases() + run_pan_law_cases()
    if fails:
        for line in fails:
            print(f"FAIL: {line}")
        sys.exit(1)
    print(f"OK — {len(CASES)} format cases + pan-law cases passed")

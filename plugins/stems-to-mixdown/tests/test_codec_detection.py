"""Codec/container -> lossy classification tests.

The original bug: every .m4a was treated as lossy because the test was
`container in LOSSY_CONTAINERS`. ALAC (Apple Lossless) wraps in m4a too —
that file would silently get capped to 16/44.1 in the format-decision matrix.
The fix is in stems_to_mixdown/discover.py:infer_lossy(), which is codec-driven.

Run via:

    python3 -m pytest tests/test_codec_detection.py -v

or, without pytest installed, plain `python3 tests/test_codec_detection.py`.
"""

from __future__ import annotations

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))
from stems_to_mixdown.discover import infer_lossy  # noqa: E402


# (codec, container, expected_is_lossy, comment)
CASES = [
    # The headline regression: ALAC in m4a is lossless, NOT lossy AAC.
    ("alac", "mov,mp4,m4a,3gp,3g2,mj2", False, "ALAC in m4a is the bug fix"),
    ("aac",  "mov,mp4,m4a,3gp,3g2,mj2", True,  "AAC in m4a stays lossy"),
    # m4a alone (single-name container) — still codec-driven
    ("alac", "m4a", False, "ALAC in m4a (short container)"),
    ("aac",  "m4a", True,  "AAC in m4a (short container)"),

    # Lossless codecs in any container
    ("flac", "flac", False, "FLAC native"),
    ("flac", "ogg",  False, "FLAC in ogg is still lossless"),
    ("pcm_s24le", "wav", False, "24-bit PCM WAV"),
    ("pcm_s16le", "wav", False, "16-bit PCM WAV"),
    ("pcm_s32le", "wav", False, "32-bit PCM WAV"),
    ("pcm_f32le", "wav", False, "32-bit float PCM WAV"),
    ("pcm_s24be", "aiff", False, "AIFF 24-bit"),
    ("wavpack", "wv", False, "WavPack"),

    # Lossy codecs in any container
    ("mp3",    "mp3", True, "MP3 native"),
    ("vorbis", "ogg", True, "Vorbis in ogg"),
    ("opus",   "ogg", True, "Opus in ogg"),
    ("ac3",    "ac3", True, "AC3"),

    # Edge: unknown codec in unknown container -> default lossless
    # (the format-decision matrix is conservative either way; misclassifying
    # a lossless file as lossy is the bug, the inverse is harmless).
    ("?", "", False, "unknown defaults to lossless (conservative)"),

    # Edge: future PCM variant ffmpeg might add — pcm_ prefix catches it
    ("pcm_s64le_planar_imaginary", "wav", False, "future pcm_* variant"),

    # Edge: container mp3 with unknown codec — last-resort hint kicks in
    ("?", "mp3", True, "container hint for mp3"),
]


def run_cases() -> list[str]:
    failures: list[str] = []
    for codec, container, expected, comment in CASES:
        got = infer_lossy(codec, container)
        if got is not expected:
            failures.append(
                f"infer_lossy({codec!r}, {container!r}) = {got}, "
                f"expected {expected} — {comment}"
            )
    return failures


# pytest hooks --------------------------------------------------------------

try:
    import pytest

    @pytest.mark.parametrize(
        "codec,container,expected,comment", CASES,
        ids=lambda v: v if isinstance(v, str) else "",
    )
    def test_infer_lossy(codec, container, expected, comment):
        assert infer_lossy(codec, container) is expected, comment

except ImportError:
    pass


# Standalone fallback -------------------------------------------------------

if __name__ == "__main__":
    fails = run_cases()
    if fails:
        for line in fails:
            print(f"FAIL: {line}")
        sys.exit(1)
    print(f"OK — {len(CASES)} codec/container cases passed")

"""Perceptual invariants for stems-to-mixdown test outputs.

These helpers assert what Cmd 1, Cmd 7, and Cmd 19 actually care about:
the right format, no clipping, and (with a master) recombine-null
within dither noise. Audio-MD5 baselines are still written for drift
detection (see check_audio_md5_drift.sh) but they are advisory; these
invariants are the gate.

All helpers shell out to ffprobe / ffmpeg via the package's _measure
module, so the results match what the pipeline itself reports.
"""
from __future__ import annotations

import json
import subprocess
from pathlib import Path

# Make the package importable when these are loaded by pytest from tests/
import sys
REPO = Path(__file__).resolve().parent.parent
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

from stems_to_mixdown import _measure  # noqa: E402


def probe_audio(path: Path) -> dict:
    """Return a small dict of audio properties: rate, channels, codec,
    bits_per_raw_sample (string or None), duration_sec.
    """
    r = subprocess.run(
        ["ffprobe", "-v", "error", "-show_streams", "-show_format",
         "-of", "json", str(path)],
        capture_output=True, text=True, check=True,
    )
    data = json.loads(r.stdout)
    stream = next((s for s in data.get("streams", [])
                   if s.get("codec_type") == "audio"), {})
    fmt = data.get("format", {})
    return {
        "rate": int(stream.get("sample_rate", 0)),
        "channels": int(stream.get("channels", 0)),
        "codec": stream.get("codec_name"),
        "bits_per_raw_sample": stream.get("bits_per_raw_sample"),
        "duration_sec": float(fmt.get("duration", 0.0)),
    }


def measure(path: Path) -> dict:
    """Return loudness measurements: true_peak_dbtp, integrated_lufs,
    loudness_range."""
    return _measure.measure_loudness_file(path)


def assert_format(path: Path, *, rate: int, channels: int,
                  codec: str | None = None, bits: int | None = None) -> None:
    """Assert path probes to the expected format.

    `bits` is matched as an int against the string returned by ffprobe;
    only checked when supplied (lossy outputs don't expose bit depth).
    """
    info = probe_audio(path)
    assert info["rate"] == rate, (
        f"{path.name}: sample rate {info['rate']} != expected {rate}"
    )
    assert info["channels"] == channels, (
        f"{path.name}: channels {info['channels']} != expected {channels}"
    )
    if codec is not None:
        assert info["codec"] == codec, (
            f"{path.name}: codec {info['codec']!r} != expected {codec!r}"
        )
    if bits is not None:
        actual_bits = info["bits_per_raw_sample"]
        assert actual_bits is not None and int(actual_bits) == bits, (
            f"{path.name}: bits_per_raw_sample {actual_bits!r} != expected {bits}"
        )


def assert_true_peak_below(path: Path, max_dbtp: float,
                           epsilon: float = 0.1) -> None:
    """Assert the file's true peak is at or below max_dbtp (with epsilon
    headroom for inter-sample-peak measurement noise).
    """
    m = measure(path)
    tp = m.get("true_peak_dbtp")
    assert tp is not None, f"{path.name}: could not measure true peak"
    assert tp <= max_dbtp + epsilon, (
        f"{path.name}: true peak {tp:.3f} dBTP exceeds ceiling "
        f"{max_dbtp:+.1f} (+{epsilon} epsilon)"
    )


def assert_lufs_within(path: Path, target_lufs: float,
                       epsilon: float = 1.0) -> None:
    """Assert integrated LUFS is within ±epsilon of target_lufs.

    Loudnorm's two-pass mode hits its target within ~0.3 LU on real
    program material; the default epsilon is loose to tolerate short
    test fixtures where the integrator hasn't fully converged.
    """
    m = measure(path)
    lufs = m.get("integrated_lufs")
    assert lufs is not None, f"{path.name}: could not measure LUFS-I"
    assert abs(lufs - target_lufs) <= epsilon, (
        f"{path.name}: LUFS-I {lufs:.2f} not within ±{epsilon} of "
        f"target {target_lufs:+.1f}"
    )


def assert_durations_match(a: Path, b: Path,
                           epsilon_sec: float = 0.001) -> None:
    """Assert two files have matching duration within epsilon seconds.

    Useful when checking that the bundle's three synced versions agree
    on length, or that the master and recombined sum line up.
    """
    da = probe_audio(a)["duration_sec"]
    db = probe_audio(b)["duration_sec"]
    assert abs(da - db) <= epsilon_sec, (
        f"duration mismatch: {a.name}={da:.4f}s vs {b.name}={db:.4f}s "
        f"(epsilon {epsilon_sec}s)"
    )


def measure_recombine_null(instrumental: Path, acapella: Path,
                           master: Path, tmpdir: Path) -> float:
    """Compute `(instrumental + acapella) - master` and return the
    residual's true peak in dBTP. Lower is better; ≤ -90 is within
    dither noise (the strict pass), ≤ -60 is the "smell vs fail"
    boundary.

    Mirrors the filter graph used by verify.py's reference battery
    so the residual matches what `verify.py` reports. Phase inversion
    is via `volume=-1.0`; amix needs `weights=1 1` (straight sum).
    """
    cmd = [
        "ffmpeg", "-nostdin", "-hide_banner",
        "-i", str(instrumental),
        "-i", str(acapella),
        "-i", str(master),
        "-filter_complex",
        "[0:a][1:a]amix=inputs=2:duration=longest:normalize=0:weights=1 1[sum];"
        "[2:a]volume=-1.0[masterneg];"
        "[sum][masterneg]amix=inputs=2:duration=longest:normalize=0:weights=1 1[null];"
        "[null]ebur128=peak=true[ebr]",
        "-map", "[ebr]", "-f", "null", "-",
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise AssertionError(
            f"recombine null computation failed: {r.stderr[-500:]}"
        )
    summary = _measure.parse_ebur128_summary(r.stderr)
    return summary["true_peak_dbtp"]


def assert_recombine_null(instrumental: Path, acapella: Path, master: Path,
                          tmpdir: Path,
                          threshold_dbtp: float = -60.0) -> None:
    """Assert the recombine null `(instrumental + acapella) - master`
    has residual true peak below threshold_dbtp.

    Default threshold -60 dBTP is the "smell vs fail" boundary from the
    Cmd 19 doctrine. Pass -90 for the dither-noise floor used in the
    explicit reference battery.
    """
    residual = measure_recombine_null(instrumental, acapella, master, tmpdir)
    assert residual <= threshold_dbtp, (
        f"recombine null residual {residual:.2f} dBTP exceeds threshold "
        f"{threshold_dbtp:+.1f} dBTP. Bundle is structurally inconsistent "
        f"with the master (Cmd 19)."
    )

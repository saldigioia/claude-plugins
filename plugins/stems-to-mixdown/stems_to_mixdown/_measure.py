"""Shared parsers for ffmpeg measurement output.

`ebur128`'s Summary block is the only place where the True peak is reported,
and it lives under a `True peak:` section header. Earlier parsers in this
codebase grabbed any line starting with `Peak:` once the Summary block
opened, which is correct under `peak=true` (the only Peak line in the
section is the True peak) but silently wrong if `peak=true|sample` is ever
enabled — sample peak appears first and would be returned as if it were
the true peak.

This module is the canonical parser. It tracks the current section header
inside the Summary block and only attaches `Peak:` values to the section
they appear under, so the True peak is always the True peak.
"""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

SILENCE_RMS_DBFS_THRESHOLD = -120.0  # below this, treat the channel as silent

_NUM = re.compile(r"(-?\d+\.\d+|inf)")


def _to_float(token: str) -> float | None:
    """Parse a signed float or `inf` token; return None on miss."""
    if token == "inf":
        return float("inf")
    if token == "-inf":
        return float("-inf")
    try:
        return float(token)
    except ValueError:
        return None


def parse_ebur128_summary(stderr: str) -> dict:
    """Return measurement dict from an ffmpeg `ebur128` stderr stream.

    Keys: integrated_lufs, loudness_range, true_peak_dbtp, sample_peak_dbfs.
    Missing values are None. Robust to ffmpeg's optional sections — adding
    a Sample peak: section won't pollute true_peak_dbtp, and removing the
    True peak: section (peak=none) leaves true_peak_dbtp at None instead of
    falling through to sample peak.
    """
    out: dict[str, float | None] = {
        "integrated_lufs": None,
        "loudness_range": None,
        "true_peak_dbtp": None,
        "sample_peak_dbfs": None,
    }
    in_summary = False
    section: str | None = None  # "Integrated loudness" / "Loudness range" / "True peak" / "Sample peak"

    for raw in stderr.splitlines():
        if "Summary:" in raw:
            in_summary = True
            continue
        if not in_summary:
            continue
        line = raw.strip()
        if not line:
            continue

        # Section headers in the summary appear as bare labels ending with ":".
        # ffmpeg writes them indented but `.strip()` already removed that.
        # Any of: "Integrated loudness:", "Loudness range:", "True peak:",
        # "Sample peak:" — possibly with a trailing value on broadcast variants.
        if line.endswith(":") and line[:-1] in (
            "Integrated loudness", "Loudness range", "True peak", "Sample peak"
        ):
            section = line[:-1]
            continue

        if line.startswith("I:"):
            m = _NUM.search(line)
            if m and "LUFS" in line:
                v = _to_float(m.group(1))
                if v is not None:
                    out["integrated_lufs"] = v
            continue

        if line.startswith("LRA:") and "LRA low" not in line and "LRA high" not in line:
            m = _NUM.search(line)
            if m and "LU" in line:
                v = _to_float(m.group(1))
                if v is not None:
                    out["loudness_range"] = v
            continue

        if line.startswith("Peak:"):
            m = re.search(r"(-?\d+\.\d+|inf|-inf)\s*dBFS", line)
            if not m:
                continue
            v = _to_float(m.group(1))
            if v is None:
                continue
            if section == "True peak":
                out["true_peak_dbtp"] = v
            elif section == "Sample peak":
                out["sample_peak_dbfs"] = v
            # If we're in a Peak: line with no preceding section header
            # (older ffmpeg variants), assume True peak when the only
            # measurement filter requested was peak=true. Conservative —
            # leave it None and let the caller fall back if it cares.
            continue

    return out


def measure_loudness_file(path: Path) -> dict:
    """Run ebur128 on a file path and return parse_ebur128_summary's dict."""
    r = subprocess.run(
        ["ffmpeg", "-nostdin", "-hide_banner", "-i", str(path),
         "-af", "ebur128=peak=true", "-f", "null", "-"],
        capture_output=True, text=True,
    )
    return parse_ebur128_summary(r.stderr)


def parse_astats_dc_and_silence(stderr: str) -> tuple[float, list[int]]:
    """Parse `astats=metadata=1:reset=0` stderr.

    Returns (max_abs_dc_offset_across_channels, zero-indexed list of silent
    channels). astats emits per-channel blocks headed `Channel: N` (1-indexed)
    followed by `DC offset:` and `RMS level dB:` lines, then an Overall block.
    A channel is silent if its RMS is `-inf` or below SILENCE_RMS_DBFS_THRESHOLD.
    """
    # ffmpeg prefixes each astats line with `[Parsed_astats_N @ 0x...] `, so
    # use re.search not re.match. A blank "Channel:" header without a number
    # is the start of an Overall section (channel-aggregate) — skip it.
    dc_offsets: list[float] = []
    rms_for_ch: dict[int, float] = {}
    current_ch: int | None = None
    for raw in stderr.splitlines():
        line = raw.strip()
        m = re.search(r"\bChannel:\s+(\d+)\b", line)
        if m:
            current_ch = int(m.group(1))
            continue
        if current_ch is None:
            continue
        m = re.search(r"\bDC offset:\s+(-?\d+\.\d+)", line)
        if m:
            dc_offsets.append(abs(float(m.group(1))))
            continue
        m = re.search(r"\bRMS level dB:\s+(-?inf|-?\d+\.\d+)", line)
        if m:
            v = m.group(1)
            rms_for_ch[current_ch] = float("-inf") if "inf" in v else float(v)
    silent: list[int] = []
    for ch, rms in rms_for_ch.items():
        if rms == float("-inf") or rms < SILENCE_RMS_DBFS_THRESHOLD:
            silent.append(ch - 1)  # zero-indexed for our records
    max_dc = max(dc_offsets) if dc_offsets else 0.0
    return max_dc, silent


def measure_dc_offset_file(path: Path) -> tuple[float, list[int]]:
    """Run astats on a file and return (max_abs_dc_offset, silent_channels)."""
    r = subprocess.run(
        ["ffmpeg", "-nostdin", "-hide_banner", "-i", str(path),
         "-af", "astats=metadata=1:reset=0", "-f", "null", "-"],
        capture_output=True, text=True,
    )
    return parse_astats_dc_and_silence(r.stderr)


def tool_version(tool: str) -> str:
    """Return the first line of `<tool> -version` (or `--version` for sox).

    Used by sidecar logs to record exact tool versions so a future engineer
    can reconstruct what produced the output. Returns "unknown" on any
    failure rather than raising — sidecar generation is downstream of mix
    success and shouldn't fail the run.
    """
    try:
        flag = "--version" if tool == "sox" else "-version"
        r = subprocess.run([tool, flag], capture_output=True, text=True)
        return r.stdout.strip().split("\n")[0]
    except Exception:
        return "unknown"

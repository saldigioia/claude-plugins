"""Shared helpers for the mix pipeline.

Idempotency, encode-stage filter chains, codec argument synthesis, file
hashing, shell escaping, metadata composition. Imported by mix.py and
the sibling _mix_* private modules. None of these are part of the
public API.
"""
from __future__ import annotations

import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path

from stems_to_mixdown import _measure
from stems_to_mixdown._version import __version__


IDEMPOTENCY_TAG = "stems-to-mixdown idempotency-key"

# Re-export so callers can `from stems_to_mixdown._mix_helpers import tool_version`
# without reaching across to _measure directly.
tool_version = _measure.tool_version


def measure_output(path: Path) -> dict:
    """Re-measure an output file: true peak, LUFS-I, LRA."""
    summary = _measure.measure_loudness_file(path)
    return {
        "true_peak_dbtp": summary["true_peak_dbtp"],
        "integrated_lufs": summary["integrated_lufs"],
        "loudness_range": summary["loudness_range"],
    }


def build_dither_chain(target_format: str, target_depth: int) -> list[str]:
    """Return the encode-stage dither / sample-format-conversion filter chain.

    Mirrors the v1.2 logic: 16-bit targets get triangular high-pass dither;
    24-bit FLAC/WAV/AIFF passes through an s32 container; mp3 always reduces
    to s16. v1.3 uses `aformat=sample_fmts=...` for the non-dither cases —
    `aresample=osf=...` loses channel-layout metadata when chained after
    loudnorm + alimiter, breaking the encoder's auto-channel selection.
    aresample is still used for the dither variants because that's the only
    filter that exposes `dither_method`.
    """
    chain: list[str] = []
    if target_format == "flac":
        if target_depth <= 16:
            chain.append("aresample=osf=s16:dither_method=triangular_hp")
            chain.append("aformat=channel_layouts=stereo")
        elif target_depth == 24:
            chain.append("aformat=sample_fmts=s32:channel_layouts=stereo")
    elif target_format in ("wav", "aiff"):
        if target_depth <= 16:
            chain.append("aresample=osf=s16:dither_method=triangular_hp")
            chain.append("aformat=channel_layouts=stereo")
        else:
            chain.append("aformat=sample_fmts=s32:channel_layouts=stereo")
    elif target_format == "mp3":
        chain.append("aresample=osf=s16:dither_method=triangular_hp")
        chain.append("aformat=channel_layouts=stereo")
    return chain


def build_codec_args(fmt: dict) -> list[str]:
    target_codec = fmt["codec"]
    target_format = fmt["format"]
    target_depth = fmt["depth"]
    args: list[str] = []
    if target_format == "flac":
        compression_level = fmt.get("compression_level", 8)
        args += ["-c:a", "flac", "-compression_level", str(compression_level)]
        if target_depth in (16, 24):
            args += ["-bits_per_raw_sample", str(target_depth)]
        elif target_depth == 32:
            args += ["-sample_fmt", "s32"]
    elif target_format == "wav":
        args += ["-c:a", target_codec]
    elif target_format == "aiff":
        args += ["-c:a", target_codec, "-f", "aiff"]
    elif target_format == "mp3":
        args += ["-c:a", "libmp3lame", "-q:a", "0"]
    return args


def hash_file(path: Path, chunk: int = 1 << 20) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(chunk), b""):
            h.update(block)
    return h.hexdigest()


def compute_idempotency_key(directory: Path, group: dict) -> tuple[str, dict[str, str]]:
    """Stable SHA-256 over the live input contents, filter graph, and
    normalization config.

    Returns (key, live_shas). Inputs are re-hashed from disk every run so a
    file replaced under the same name with different content invalidates the
    cache; the plan's `stem_shas` block records the analyze-time hashes for
    drift-detection comparison. v1.3 also incorporates the normalization
    config and the archival flag so flipping --archival or changing
    --target-lufs invalidates correctly.
    """
    live_shas: dict[str, str] = {}
    parts: list[str] = []
    for fn in group["stem_files"]:
        sha = hash_file(directory / fn)
        live_shas[fn] = sha
        parts.append(f"{fn}:{sha}")
    parts.append("--filter--")
    parts.append(group["filter_graph"])
    parts.append("--normalization--")
    parts.append(json.dumps(group.get("normalization"), sort_keys=True, default=str))
    parts.append("--archival--")
    parts.append(str(group.get("archival", False)))
    payload = "\n".join(parts).encode("utf-8")
    return hashlib.sha256(payload).hexdigest(), live_shas


def shell_escape(arg: str) -> str:
    if not arg or any(c in arg for c in ' \t"\'$`\\'):
        return "'" + arg.replace("'", "'\\''") + "'"
    return arg


def gather_metadata(plan: dict, group: dict) -> dict[str, str]:
    """Compose metadata to embed: project + group + skill comment + manifest overrides."""
    md: dict[str, str] = {}
    manifest_md = (plan.get("manifest") or {}).get("metadata") or {}
    # From manifest (priority)
    for k in ("artist", "album", "date", "genre"):
        if manifest_md.get(k):
            md[k.upper()] = str(manifest_md[k])
    # Title is set by skill
    md["TITLE"] = f"{plan['project']} ({group['name']})"
    md["COMMENT"] = (manifest_md.get("comment") or
                     f"Mixed by stems-to-mixdown v{__version__} on "
                     f"{datetime.now(timezone.utc).date().isoformat()}. See sidecar log.")
    return md

"""Optional production-metadata probes (LLM-reference only).

All three helpers below populate `production_metadata` on a discovered stem
so an operator (Claude or a human) reading analysis.json has the bext / iXML /
MediaInfo context to make better mixdown choices. **None** of this metadata
flows into output FLAC tags. Output tags are driven solely by the manifest's
`metadata:` block. See `references/pro-audio-metadata.md`.

Each helper soft-imports / soft-shells-out and returns `{}` when the
underlying tool isn't available. None of them raise — the discovery pass
must keep running with or without the optional probes.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

try:
    from wavinfo import WavInfoReader  # type: ignore
except ImportError:
    WavInfoReader = None  # production-metadata enrichment degrades gracefully

WAV_EXTS = {".wav", ".wave", ".rf64"}  # wavinfo / BWF MetaEdit only handle these

# Cap for BWF coding-history strings inside analysis.json. Coding history can
# run many hundreds of lines on heavily-processed material; we keep enough to
# be useful for an LLM operator without blowing up the JSON.
CODING_HISTORY_MAX_BYTES = 2048


def _truncate(text: str | None, max_bytes: int) -> str | None:
    if text is None:
        return None
    encoded = text.encode("utf-8", errors="replace")
    if len(encoded) <= max_bytes:
        return text
    return encoded[:max_bytes].decode("utf-8", errors="ignore") + "...[truncated]"


def enrich_with_wavinfo(path: Path) -> dict[str, Any]:
    """
    Read BWF / iXML / fmt-chunk metadata via wavinfo.

    Returns a dict with keys: bwf, ixml, umid, fmt_valid_bits, fmt_container_bits.
    Empty dict if wavinfo is unavailable, the file is not a WAV/RF64, or
    parsing fails. Never raises.

    Critically, fmt_valid_bits exposes wValidBitsPerSample for
    WAVE_FORMAT_EXTENSIBLE files — the field that ffprobe and MediaInfo
    flatten to the container size. This is the source of truth for honest
    bit depth.
    """
    if WavInfoReader is None:
        return {}
    if path.suffix.lower() not in WAV_EXTS:
        return {}
    try:
        info = WavInfoReader(str(path))
    except Exception as e:  # noqa: BLE001 — wavinfo raises a variety of exceptions
        sys.stderr.write(f"[info] wavinfo failed on {path.name}: {e}\n")
        return {}

    out: dict[str, Any] = {}

    # Honest bit depth: wValidBitsPerSample for extensible, wBitsPerSample otherwise.
    # wavinfo's `fmt.bits_per_sample` is the valid-bits value when present.
    fmt = getattr(info, "fmt", None)
    if fmt is not None:
        valid = getattr(fmt, "bits_per_sample", None)
        if valid:
            out["fmt_valid_bits"] = int(valid)
        # Container size is exposed differently across wavinfo versions; try a few.
        container_bits = (
            getattr(fmt, "container_size", None)
            or getattr(fmt, "container_bits_per_sample", None)
            or getattr(fmt, "wBitsPerSample", None)
        )
        if container_bits:
            out["fmt_container_bits"] = int(container_bits)

    # bext (BWF) chunk
    bext = getattr(info, "bext", None)
    if bext is not None:
        bwf = {
            "description": getattr(bext, "description", None),
            "originator": getattr(bext, "originator", None),
            "originator_reference": getattr(bext, "originator_reference", None),
            "origination_date": getattr(bext, "origination_date", None),
            "origination_time": getattr(bext, "origination_time", None),
            "time_reference": getattr(bext, "time_reference", None),
            "coding_history": _truncate(
                getattr(bext, "coding_history", None), CODING_HISTORY_MAX_BYTES
            ),
        }
        # Only include keys that actually have values, so analysis.json stays
        # readable on files that have no bext at all.
        bwf = {k: v for k, v in bwf.items() if v not in (None, "", b"")}
        if bwf:
            out["bwf"] = bwf

    # iXML chunk — wavinfo exposes a parsed object in newer versions and raw
    # XML in older ones. Defensively try both.
    ixml = getattr(info, "ixml", None)
    if ixml is not None:
        ixml_data: dict[str, Any] = {}
        for key in ("project", "scene", "take", "tape", "circled", "wild_track",
                    "false_start", "no_good", "user_bits", "speed_note", "note"):
            value = getattr(ixml, key, None)
            if value not in (None, "", b""):
                ixml_data[key] = value
        if ixml_data:
            out["ixml"] = ixml_data

    # UMID — sometimes lives on bext, sometimes on the reader itself.
    umid = getattr(info, "umid", None) or getattr(bext, "umid", None) if bext else None
    if umid:
        # UMID may be bytes; render as hex for JSON.
        if isinstance(umid, (bytes, bytearray)):
            umid = umid.hex()
        out["umid"] = umid

    return out


def mediainfo_probe(path: Path) -> dict[str, Any]:
    """
    Run `mediainfo --Output=JSON` and return a normalized dict for cross-check.

    Returns {} if mediainfo isn't installed or fails. Never raises. The dict
    contains: sample_rate, bit_depth (the BitDepth field — usually container
    size), bit_depth_detected (BitDepth_Detected — sometimes the valid bits),
    channels, duration_ms, format. Used for probe_disagreement red flags.
    """
    if shutil.which("mediainfo") is None:
        return {}
    try:
        result = subprocess.run(
            ["mediainfo", "--Output=JSON", str(path)],
            capture_output=True, text=True, check=True,
        )
        data = json.loads(result.stdout or "{}")
    except (subprocess.CalledProcessError, json.JSONDecodeError) as e:
        sys.stderr.write(f"[info] mediainfo failed on {path.name}: {e}\n")
        return {}

    tracks = (data.get("media") or {}).get("track") or []
    audio = next((t for t in tracks if t.get("@type") == "Audio"), None)
    if not audio:
        return {}

    def _int(v: Any) -> int | None:
        try:
            return int(v) if v is not None else None
        except (TypeError, ValueError):
            return None

    def _float(v: Any) -> float | None:
        try:
            return float(v) if v is not None else None
        except (TypeError, ValueError):
            return None

    return {
        "sample_rate": _int(audio.get("SamplingRate")),
        "bit_depth": _int(audio.get("BitDepth")),
        "bit_depth_detected": _int(audio.get("BitDepth_Detected")),
        "channels": _int(audio.get("Channels")),
        "duration_ms": _float(audio.get("Duration")) and _float(audio.get("Duration")) * 1000,
        "format": audio.get("Format"),
        "compression_mode": audio.get("Compression_Mode"),
    }


def run_bwfmetaedit_report(path: Path, out_dir: Path) -> dict[str, str]:
    """
    Run BWF MetaEdit on a single WAV and write its read-only reports to out_dir.

    Returns a mapping of report-type -> file path. Empty dict if bwfmetaedit
    isn't installed or fails. Never raises.

    Reports written:
    - <basename>.bwf.core.txt   — FADGI CORE fields
    - <basename>.bwf.tech.txt   — fmt-chunk technical metadata
    - <basename>.bwf.xml        — full BWF metadata as XML

    These are advisory artifacts. They are NOT subject to Commandment 13's
    determinism contract because BWF MetaEdit's output may include
    version-banner timestamps. The plugin's reproducibility commitment
    covers the mixdown pipeline, not these audit exports.
    """
    if shutil.which("bwfmetaedit") is None:
        return {}
    if path.suffix.lower() not in WAV_EXTS:
        return {}
    out_dir.mkdir(parents=True, exist_ok=True)
    base = path.stem
    targets = {
        "core": (out_dir / f"{base}.bwf.core.txt", ["--out-core"]),
        "tech": (out_dir / f"{base}.bwf.tech.txt", ["--out-tech"]),
        "xml":  (out_dir / f"{base}.bwf.xml",       ["--out-xml"]),
    }
    written: dict[str, str] = {}
    for kind, (target, flags) in targets.items():
        try:
            result = subprocess.run(
                ["bwfmetaedit", *flags, str(path)],
                capture_output=True, text=True, check=False,
            )
            # bwfmetaedit writes the export to stdout for --out-* variants
            if result.returncode == 0 and result.stdout:
                target.write_text(result.stdout)
                written[kind] = str(target)
        except Exception as e:  # noqa: BLE001
            sys.stderr.write(f"[info] bwfmetaedit {kind} failed on {path.name}: {e}\n")
    return written

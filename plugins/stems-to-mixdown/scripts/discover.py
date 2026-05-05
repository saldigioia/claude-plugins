"""Pass 1 — Discovery.

Walks a directory of audio stems, probes every file via ffprobe, classifies
each by filename heuristic (or manifest override), runs ITU-R BS.1770
loudness measurement and astats DC/silence detection, and packs the result
into StemInfo dataclasses.

This module owns the StemInfo shape. analyze.py imports `StemInfo` and
`discover_stems` from here; sanity.py reads the dataclass for its checks.
"""

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _enrichment  # noqa: E402
import _measure  # noqa: E402
from _classification import classify_by_filename  # noqa: E402

AUDIO_EXTS = {".wav", ".flac", ".aiff", ".aif", ".mp3", ".m4a", ".aac", ".ogg", ".opus"}
WAV_EXTS = {".wav", ".wave", ".rf64"}  # wavinfo / BWF MetaEdit only handle these
LOSSY_FORMATS = {"mp3", "aac", "vorbis", "opus"}
LOSSY_CONTAINERS = {"mp3", "aac", "ogg", "m4a", "opus"}


@dataclass
class MasterReferenceInfo:
    """Probe result for the user-supplied master file (Cmd 19).

    The master is the witness, not the source. This struct captures everything
    Pass 2 needs to enforce rate / depth / duration / channels parity, plus the
    measurements verify.py reports as deltas. The skill never modifies the
    master — only the bundle copy gets re-encoded if the container differs.
    """
    path: str
    sha256: str
    codec: str
    container: str
    is_lossy: bool
    sample_rate: int
    bit_depth: int  # 0 if lossy
    bit_depth_source: str
    sample_fmt: str
    channels: int
    channel_layout: str
    duration_sec: float
    duration_samples: int
    true_peak_dbtp: float | None = None
    integrated_lufs: float | None = None
    loudness_range: float | None = None
    # Where the path came from. "manifest" | "cli". Useful for the report.
    source: str = "manifest"
    # Tolerance the operator chose (or default) for length comparison.
    duration_tolerance_samples: int = 1


@dataclass
class StemInfo:
    path: str
    filename: str
    size_bytes: int
    sha256: str
    codec: str
    container: str
    is_lossy: bool
    sample_rate: int
    bit_depth: int  # 0 if not applicable (e.g. lossy)
    bit_depth_source: str  # "wavinfo" | "ffprobe_bits_per_raw_sample" | "ffprobe_sample_fmt" | "lossy"
    sample_fmt: str
    channels: int
    channel_layout: str
    duration_sec: float
    duration_samples: int
    classification: str
    classification_source: str  # "manifest" | "regex" | "default"
    true_peak_dbtp: float | None = None
    integrated_lufs: float | None = None
    loudness_range: float | None = None
    dc_offset_max: float | None = None
    silent_channels: list[int] = field(default_factory=list)
    fully_silent: bool = False
    tags: dict[str, str] = field(default_factory=dict)
    # Production metadata is *for the LLM operator's reference only*. Nothing
    # in this block ever auto-flows into output embedded tags. Output tags
    # are driven solely by the manifest's `metadata:` block. See
    # references/pro-audio-metadata.md.
    production_metadata: dict[str, Any] = field(default_factory=dict)


def require_tools() -> None:
    missing = [t for t in ("ffprobe", "ffmpeg") if shutil.which(t) is None]
    if missing:
        sys.stderr.write(f"[fatal] missing required tools: {', '.join(missing)}\n")
        sys.exit(2)
    if shutil.which("sox") is None:
        sys.stderr.write("[info] sox not found; engine is ffmpeg, sox is optional\n")


def sha256_file(path: Path, chunk: int = 1 << 20) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(chunk), b""):
            h.update(block)
    return h.hexdigest()


def ffprobe_json(path: Path) -> dict[str, Any]:
    result = subprocess.run(
        ["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def measure_loudness(path: Path) -> tuple[float | None, float | None, float | None]:
    """Returns (true_peak_dbtp, integrated_lufs, loudness_range)."""
    summary = _measure.measure_loudness_file(path)
    return (
        summary["true_peak_dbtp"],
        summary["integrated_lufs"],
        summary["loudness_range"],
    )


def measure_dc_offset(path: Path, channels: int) -> tuple[float, list[int]]:
    """Returns (max abs DC offset across channels, list of fully-silent channel indices)."""
    return _measure.measure_dc_offset_file(path)


def probe_master_reference(master_path: Path, source: str,
                            duration_tolerance_samples: int) -> MasterReferenceInfo | None:
    """Probe the user-supplied master file. Returns None on hard failure
    (file missing, unreadable, no audio stream) — the caller produces the
    Pass 2 red flag for the missing-file case.

    The master gets the same probe shape as a stem, minus classification (the
    master isn't a stem, it isn't classified, it isn't summed). LUFS-I + dBTP
    are measured because verify.py reports them as deltas vs each deliverable.
    """
    if not master_path.is_file():
        sys.stderr.write(f"[warn] master reference not found: {master_path}\n")
        return None
    try:
        probed = ffprobe_json(master_path)
    except subprocess.CalledProcessError as e:
        sys.stderr.write(f"[warn] ffprobe failed on master {master_path.name}: {e.stderr}\n")
        return None

    audio_streams = [s for s in probed.get("streams", []) if s.get("codec_type") == "audio"]
    if not audio_streams:
        sys.stderr.write(f"[warn] no audio stream in master {master_path.name}\n")
        return None
    stream = audio_streams[0]
    fmt = probed.get("format", {})
    codec = stream.get("codec_name", "?")
    container = (fmt.get("format_name") or "").split(",")[0]
    is_lossy = codec in LOSSY_FORMATS or container in LOSSY_CONTAINERS

    # Bit depth resolution: same priority order as stems, with the wavinfo
    # honesty fix when applicable.
    wavinfo_data = _enrichment.enrich_with_wavinfo(master_path)
    sample_fmt_str = stream.get("sample_fmt", "")
    if is_lossy:
        bit_depth = 0
        bit_depth_source = "lossy"
    elif wavinfo_data.get("fmt_valid_bits"):
        bit_depth = int(wavinfo_data["fmt_valid_bits"])
        bit_depth_source = "wavinfo"
    else:
        bits_per_raw = stream.get("bits_per_raw_sample")
        if bits_per_raw and str(bits_per_raw).isdigit():
            bit_depth = int(bits_per_raw)
            bit_depth_source = "ffprobe_bits_per_raw_sample"
        else:
            bit_depth = {
                "u8": 8, "u8p": 8, "s16": 16, "s16p": 16,
                "s32": 32, "s32p": 32, "flt": 32, "fltp": 32,
                "dbl": 64, "dblp": 64,
            }.get(sample_fmt_str, 0)
            bit_depth_source = "ffprobe_sample_fmt"

    sample_rate = int(stream.get("sample_rate", 0))
    channels = int(stream.get("channels", 0))
    channel_layout = stream.get("channel_layout", "?")
    duration_sec = float(fmt.get("duration") or stream.get("duration") or 0.0)
    duration_samples = int(round(duration_sec * sample_rate)) if sample_rate else 0

    true_peak = lufs = lra = None
    if duration_sec > 0:
        true_peak, lufs, lra = measure_loudness(master_path)

    return MasterReferenceInfo(
        path=str(master_path),
        sha256=sha256_file(master_path),
        codec=codec,
        container=container,
        is_lossy=is_lossy,
        sample_rate=sample_rate,
        bit_depth=bit_depth,
        bit_depth_source=bit_depth_source,
        sample_fmt=sample_fmt_str,
        channels=channels,
        channel_layout=channel_layout,
        duration_sec=duration_sec,
        duration_samples=duration_samples,
        true_peak_dbtp=true_peak,
        integrated_lufs=lufs,
        loudness_range=lra,
        source=source,
        duration_tolerance_samples=duration_tolerance_samples,
    )


def discover_stems(directory: Path, recursive: bool, manifest: dict[str, Any],
                   bwf_report_dir: Path | None = None,
                   exclude_paths: set[Path] | None = None) -> list[StemInfo]:
    """Walk `directory` and return a StemInfo per audio file.

    `exclude_paths` is a set of resolved absolute paths to ignore — used by
    analyze.py to skip the user-supplied master reference when it happens to
    live alongside the stems (a common convenience layout). The master is a
    witness, not a stem (Cmd 19); summing it as if it were one would silently
    produce a track with the master mixed in.
    """
    classifications_override = manifest.get("classifications") or {}
    exclude_paths = exclude_paths or set()
    pattern = "**/*" if recursive else "*"
    stems: list[StemInfo] = []
    for path in sorted(directory.glob(pattern)):
        if not path.is_file():
            continue
        if path.suffix.lower() not in AUDIO_EXTS:
            continue
        if path.name == "stems.manifest.yaml":
            continue
        try:
            if path.resolve() in exclude_paths:
                continue
        except OSError:
            pass
        try:
            probed = ffprobe_json(path)
        except subprocess.CalledProcessError as e:
            sys.stderr.write(f"[warn] ffprobe failed on {path.name}: {e.stderr}\n")
            continue
        audio_streams = [s for s in probed.get("streams", []) if s.get("codec_type") == "audio"]
        if not audio_streams:
            sys.stderr.write(f"[warn] no audio stream in {path.name}; skipping\n")
            continue
        stream = audio_streams[0]
        fmt = probed.get("format", {})
        codec = stream.get("codec_name", "?")
        container = (fmt.get("format_name") or "").split(",")[0]
        is_lossy = codec in LOSSY_FORMATS or container in LOSSY_CONTAINERS

        # Run optional production-metadata probes BEFORE deriving bit_depth so we
        # can prefer wavinfo's wValidBitsPerSample over ffprobe's container size.
        # See references/pro-audio-metadata.md for the source-of-truth rule.
        wavinfo_data = _enrichment.enrich_with_wavinfo(path)
        mediainfo_data = _enrichment.mediainfo_probe(path)

        # Bit depth resolution, in priority order:
        #   1. wavinfo's wValidBitsPerSample (the only source that gets 24-in-32 right)
        #   2. ffprobe's bits_per_raw_sample (typically N/A for WAV; populated for video codecs)
        #   3. ffprobe's sample_fmt mapping (container size — over-reports 24-in-32 as 32)
        #   4. 0 if lossy
        sample_fmt_str = stream.get("sample_fmt", "")
        if is_lossy:
            bit_depth = 0
            bit_depth_source = "lossy"
        elif wavinfo_data.get("fmt_valid_bits"):
            bit_depth = int(wavinfo_data["fmt_valid_bits"])
            bit_depth_source = "wavinfo"
        else:
            bits_per_raw = stream.get("bits_per_raw_sample")
            if bits_per_raw and str(bits_per_raw).isdigit():
                bit_depth = int(bits_per_raw)
                bit_depth_source = "ffprobe_bits_per_raw_sample"
            else:
                bit_depth = {
                    "u8": 8, "u8p": 8,
                    "s16": 16, "s16p": 16,
                    "s32": 32, "s32p": 32,
                    "flt": 32, "fltp": 32,
                    "dbl": 64, "dblp": 64,
                }.get(sample_fmt_str, 0)
                bit_depth_source = "ffprobe_sample_fmt"

        sample_rate = int(stream.get("sample_rate", 0))
        channels = int(stream.get("channels", 0))
        channel_layout = stream.get("channel_layout", "?")
        duration_sec = float(fmt.get("duration") or stream.get("duration") or 0.0)
        duration_samples = int(round(duration_sec * sample_rate)) if sample_rate else 0

        # Classification: manifest > regex > default
        rel_name = path.name
        if rel_name in classifications_override:
            classification = classifications_override[rel_name]
            classification_source = "manifest"
        else:
            classification = classify_by_filename(path.stem)
            classification_source = "regex" if classification != "other" else "default"

        # Measurements (skip if duration is 0 — broken file)
        true_peak = lufs = lra = None
        dc_max = 0.0
        silent_channels: list[int] = []
        fully_silent = False
        if duration_sec > 0:
            true_peak, lufs, lra = measure_loudness(path)
            dc_max, silent_channels = measure_dc_offset(path, channels)
            fully_silent = (channels > 0 and len(silent_channels) == channels)

        tags = {k.lower(): v for k, v in (fmt.get("tags") or {}).items()}

        # Assemble production_metadata for LLM-reference use only.
        production_metadata: dict[str, Any] = {}
        if wavinfo_data.get("bwf"):
            production_metadata["bwf"] = wavinfo_data["bwf"]
        if wavinfo_data.get("ixml"):
            production_metadata["ixml"] = wavinfo_data["ixml"]
        if wavinfo_data.get("umid"):
            production_metadata["umid"] = wavinfo_data["umid"]
        if mediainfo_data:
            production_metadata["mediainfo"] = mediainfo_data
        # Record both the valid bits and the container size so an LLM operator
        # can see at a glance that a file is, e.g., 24-in-32.
        if wavinfo_data.get("fmt_valid_bits") or wavinfo_data.get("fmt_container_bits"):
            production_metadata["fmt"] = {
                k: v for k, v in {
                    "valid_bits": wavinfo_data.get("fmt_valid_bits"),
                    "container_bits": wavinfo_data.get("fmt_container_bits"),
                }.items() if v is not None
            }

        # Optional BWF MetaEdit reports — advisory artifacts written next to
        # the inputs. Only invoked when --bwf-report was passed.
        if bwf_report_dir is not None:
            written = _enrichment.run_bwfmetaedit_report(path, bwf_report_dir)
            if written:
                production_metadata["bwf_reports"] = written

        stems.append(StemInfo(
            path=str(path),
            filename=path.name,
            size_bytes=path.stat().st_size,
            sha256=sha256_file(path),
            codec=codec,
            container=container,
            is_lossy=is_lossy,
            sample_rate=sample_rate,
            bit_depth=bit_depth,
            bit_depth_source=bit_depth_source,
            sample_fmt=sample_fmt_str,
            channels=channels,
            channel_layout=channel_layout,
            duration_sec=duration_sec,
            duration_samples=duration_samples,
            classification=classification,
            classification_source=classification_source,
            true_peak_dbtp=true_peak,
            integrated_lufs=lufs,
            loudness_range=lra,
            dc_offset_max=dc_max,
            silent_channels=silent_channels,
            fully_silent=fully_silent,
            tags=tags,
            production_metadata=production_metadata,
        ))
    return stems

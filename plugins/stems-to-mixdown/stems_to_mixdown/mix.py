#!/usr/bin/env python3
"""
mix.py — Pass 4 (Execute).

Reads plan.json (from Pass 3), runs the actual mixdown via ffmpeg with the
planned filter graph, writes outputs and sidecar .log.md files.

Behavior:
    - Idempotent: if output exists with matching SHA-256 of inputs+graph in
      sidecar, skip (unless --force-overwrite).
    - Writes intermediate at 32-bit float to a temp path, then encodes to
      target format with dither if reducing bit depth.
    - Sidecar log records every input SHA, exact ffmpeg command, filter graph,
      pre/post measurements, attenuation applied, tool versions, timestamp.

Exit codes:
    0  = all groups mixed successfully
    1  = one or more groups failed
    2  = structural error
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# Allow `python3 stems_to_mixdown/mix.py` invocation alongside `python3 -m stems_to_mixdown.mix`
if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from stems_to_mixdown import _measure  # noqa: E402
from stems_to_mixdown._version import __version__  # noqa: E402

IDEMPOTENCY_TAG = "stems-to-mixdown idempotency-key"


# ---------------------------------------------------------------------------
# Tool helpers
# ---------------------------------------------------------------------------

tool_version = _measure.tool_version


def measure_output(path: Path) -> dict:
    """Re-measure an output file: true peak, LUFS-I, LRA."""
    summary = _measure.measure_loudness_file(path)
    return {
        "true_peak_dbtp": summary["true_peak_dbtp"],
        "integrated_lufs": summary["integrated_lufs"],
        "loudness_range": summary["loudness_range"],
    }


# ---------------------------------------------------------------------------
# Encode-stage helpers (shared by archival and normalized paths)
# ---------------------------------------------------------------------------

def _build_dither_chain(target_format: str, target_depth: int) -> list[str]:
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


def _build_codec_args(fmt: dict) -> list[str]:
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


# ---------------------------------------------------------------------------
# Two-pass loudnorm (v1.3 / Cmd 9 revised)
# ---------------------------------------------------------------------------

def parse_loudnorm_json(stderr: str) -> dict:
    """Extract the `print_format=json` block from loudnorm's stderr output.

    ffmpeg loudnorm prints either a `[Parsed_loudnorm_0 @ 0x...]` line
    followed by JSON, or just JSON, depending on log level. Find the last
    JSON object that looks like loudnorm's measurement block and return
    it parsed (string values intact — that's what loudnorm wants on the
    second pass).
    """
    # Take everything from the first `{` to the matching closing `}` at the
    # bottom of the output. loudnorm's JSON is the only multi-line JSON that
    # appears in its stderr.
    end = stderr.rfind("}")
    if end == -1:
        return {}
    start = stderr.rfind("{", 0, end + 1)
    if start == -1:
        return {}
    blob = stderr[start:end + 1]
    try:
        data = json.loads(blob)
    except json.JSONDecodeError:
        return {}
    # Must look like loudnorm output
    if "input_i" not in data or "target_offset" not in data:
        return {}
    return data


def _true_peak_to_linear(dbtp: float) -> float:
    """Convert a dBTP ceiling to the linear ratio that alimiter wants
    (limit=0.891 for -1 dBTP, etc.). Clamps to a safe ceiling.
    """
    return max(0.001, min(1.0, 10 ** (dbtp / 20.0)))


def render_unity_sum_intermediate(directory: Path, group: dict,
                                   intermediate_path: Path) -> tuple[bool, str]:
    """Render the group's unity sum to a 32-bit float WAV intermediate at
    the target rate. Returns (ok, stderr_tail). The intermediate keeps
    full precision for the first-pass measurement; encode-stage filtering
    (dither, s32 conversion, compression) runs only on the second pass.
    """
    target_rate = group["format"]["rate"]
    cmd = ["ffmpeg", "-nostdin", "-hide_banner", "-y"]
    for fn in group["stem_files"]:
        cmd += ["-i", str(directory / fn)]
    cmd += [
        "-filter_complex", group["filter_graph"],
        "-map", "[mix]",
        "-c:a", "pcm_f32le", "-ar", str(target_rate),
        str(intermediate_path),
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    return (r.returncode == 0), r.stderr[-2000:] if r.stderr else ""


def measure_loudnorm_first_pass(intermediate_path: Path,
                                 norm_cfg: dict) -> dict:
    """Run loudnorm in first-pass measurement mode and parse the JSON
    summary. Returns the parsed measurements dict (input_i, input_tp,
    input_lra, input_thresh, target_offset, ...) or {} on failure.
    """
    target_lufs = norm_cfg["target_lufs"]
    target_tp = norm_cfg["target_true_peak"]
    lra = norm_cfg.get("lra_target", 11.0)
    cmd = [
        "ffmpeg", "-nostdin", "-hide_banner",
        "-i", str(intermediate_path),
        "-af", f"loudnorm=I={target_lufs}:LRA={lra}:TP={target_tp}:print_format=json",
        "-f", "null", "-",
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    return parse_loudnorm_json(r.stderr)


def build_normalized_command(intermediate_path: Path, output_path: Path,
                              fmt: dict, norm_cfg: dict,
                              measurements: dict,
                              metadata: dict[str, str]) -> tuple[list[str], str]:
    """Build the second-pass ffmpeg command: loudnorm (apply with measured
    params) + alimiter (true-peak ceiling) + dither/format conversion +
    encode. Returns (cmd, filter_chain_string_for_log).
    """
    target_lufs = norm_cfg["target_lufs"]
    target_tp = norm_cfg["target_true_peak"]
    lra = norm_cfg.get("lra_target", 11.0)

    loudnorm_args = (
        f"loudnorm=I={target_lufs}:LRA={lra}:TP={target_tp}"
        f":measured_I={measurements.get('input_i', '0.0')}"
        f":measured_LRA={measurements.get('input_lra', '0.0')}"
        f":measured_TP={measurements.get('input_tp', '0.0')}"
        f":measured_thresh={measurements.get('input_thresh', '0.0')}"
        f":offset={measurements.get('target_offset', '0.0')}"
        f":linear=true:print_format=summary"
    )
    limiter_args = (
        # alimiter takes a linear limit value in [0, 1]. -1 dBTP → 0.891
        f"alimiter=limit={_true_peak_to_linear(target_tp):.6f}:level=disabled"
    )
    dither_chain = _build_dither_chain(fmt["format"], fmt["depth"])
    full_chain = ",".join([loudnorm_args, limiter_args] + dither_chain)

    cmd = [
        "ffmpeg", "-nostdin", "-hide_banner", "-y",
        "-i", str(intermediate_path),
        "-af", full_chain,
        # ffmpeg's loudnorm filter internally upsamples to 192 kHz, so pin
        # the output sample rate explicitly. Without -ar, every normalized
        # FLAC ships at 192 kHz regardless of the planned target.
        "-ar", str(fmt["rate"]),
    ]
    cmd += _build_codec_args(fmt)
    for k, v in metadata.items():
        cmd += ["-metadata", f"{k}={v}"]
    cmd += [str(output_path)]
    return cmd, full_chain


def execute_group_normalized(directory: Path, group: dict, plan: dict,
                              output_path: Path, idempotency_key: str,
                              live_shas: dict[str, str]) -> dict:
    """Render unity-sum to an intermediate, then two-pass loudnorm + alimiter
    + dither + encode to the final output. Cmd 9 (revised in v1.3).
    """
    norm_cfg = group["normalization"]
    fmt = group["format"]
    started_at = datetime.now(timezone.utc).isoformat()

    # Stage 1: unity-sum render to a 32-bit float intermediate.
    with tempfile.NamedTemporaryFile(
        prefix=f"s2m_{plan['project']}_{group['name']}_",
        suffix=".wav",
        dir=str(output_path.parent),
        delete=False,
    ) as tmp:
        intermediate = Path(tmp.name)
    try:
        ok, err_tail = render_unity_sum_intermediate(directory, group, intermediate)
        if not ok:
            return {
                "status": "error",
                "reason": "unity-sum intermediate render failed",
                "stderr_tail": err_tail,
                "output": str(output_path),
            }

        # Measure unity-sum loudness for the sidecar (LUFS-I + dBTP +
        # LRA — informational so the operator can see what the unprocessed
        # mix looks like before normalization).
        unity_summary = _measure.measure_loudness_file(intermediate)

        # Stage 2: first-pass loudnorm — measure.
        measurements = measure_loudnorm_first_pass(intermediate, norm_cfg)
        if not measurements:
            return {
                "status": "error",
                "reason": "loudnorm first-pass measurement failed",
                "output": str(output_path),
            }

        # Stage 3: second-pass loudnorm + alimiter + dither + encode.
        metadata = _gather_metadata(plan, group)
        cmd, filter_chain = build_normalized_command(
            intermediate, output_path, fmt, norm_cfg, measurements, metadata,
        )
        sys.stderr.write(
            f"[mix:normalized] running: {' '.join(_shell_escape(c) for c in cmd)}\n"
        )
        r = subprocess.run(cmd, capture_output=True, text=True)
        finished_at = datetime.now(timezone.utc).isoformat()
        if r.returncode != 0:
            return {
                "status": "error",
                "reason": "second-pass loudnorm/encode failed",
                "stderr_tail": r.stderr[-2000:],
                "output": str(output_path),
                "command": cmd,
            }
    finally:
        try:
            intermediate.unlink()
        except OSError:
            pass

    output_measurements = measure_output(output_path)

    sidecar = render_sidecar_log(
        directory=directory, plan=plan, group=group,
        cmd=cmd, filter_graph=group["filter_graph"],
        started_at=started_at, finished_at=finished_at,
        output_measurements=output_measurements,
        idempotency_key=idempotency_key,
        live_shas=live_shas,
        normalization={
            "config": norm_cfg,
            "first_pass_measurements": measurements,
            "second_pass_filter_chain": filter_chain,
            "unity_sum_measurements": unity_summary,
        },
    )
    log_path = Path(str(output_path) + ".log.md")
    log_path.write_text(sidecar)

    return {
        "status": "ok",
        "output": str(output_path),
        "output_measurements": output_measurements,
        "unity_sum_measurements": unity_summary,
        "loudnorm_measurements": measurements,
        "idempotency_key": idempotency_key,
        "log": str(log_path),
    }


# ---------------------------------------------------------------------------
# Mix execution
# ---------------------------------------------------------------------------

def execute_group(directory: Path, group: dict, plan: dict, force_overwrite: bool) -> dict:
    """
    Execute a single group's mixdown. Returns a result dict for the sidecar log.
    """
    output_path = Path(group["output_path"])
    output_path.parent.mkdir(parents=True, exist_ok=True)

    fmt = group["format"]
    target_codec = fmt["codec"]
    target_format = fmt["format"]
    target_depth = fmt["depth"]
    dither_required = fmt["dither_required"]

    # Idempotency check: SHA-anchored. The key combines the live input SHAs
    # (re-hashed from disk every run) with the exact filter graph; if the
    # sidecar already records this key, the output is bit-equivalent and
    # there's nothing to do.
    log_path = Path(str(output_path) + ".log.md")
    idempotency_key, live_shas = compute_idempotency_key(directory, group)
    if output_path.exists() and log_path.exists() and not force_overwrite:
        try:
            existing_log = log_path.read_text()
            if f"{IDEMPOTENCY_TAG}: `{idempotency_key}`" in existing_log:
                return {
                    "status": "skipped",
                    "reason": "output exists with matching idempotency key in sidecar",
                    "idempotency_key": idempotency_key,
                    "output": str(output_path),
                }
        except Exception:
            pass  # fall through to remix

    # v1.3: when normalization is set, the canonical output goes through
    # the unity-sum-then-loudnorm pipeline. Archival mode (and bundle
    # internals) keep the v1.2 single-shot path below.
    if group.get("normalization") is not None:
        return execute_group_normalized(
            directory, group, plan, output_path, idempotency_key, live_shas,
        )

    # Build the ffmpeg command
    cmd = ["ffmpeg", "-nostdin", "-hide_banner", "-y"]
    for fn in group["stem_files"]:
        cmd += ["-i", str(directory / fn)]

    # The filter graph from the plan ends with [mix]. Add encode-side filtering.
    filter_graph = group["filter_graph"]
    encode_filter_chain = []

    # Sample format / dither at encode stage
    if target_format == "flac":
        if target_depth <= 16:
            # Reduce to 16-bit with dither
            encode_filter_chain.append("aresample=osf=s16:dither_method=triangular_hp")
        elif target_depth == 24:
            encode_filter_chain.append("aresample=osf=s32")  # 24 fits in s32 container
        # 32-bit FLAC is unusual; let codec handle from float
    elif target_format == "wav":
        if target_depth <= 16:
            encode_filter_chain.append("aresample=osf=s16:dither_method=triangular_hp")
        else:
            encode_filter_chain.append("aresample=osf=s32")
    elif target_format == "aiff":
        if target_depth <= 16:
            encode_filter_chain.append("aresample=osf=s16:dither_method=triangular_hp")
        else:
            encode_filter_chain.append("aresample=osf=s32")
    elif target_format == "mp3":
        # MP3 codec wants s16/s32; dither down to s16 is reasonable for V0
        encode_filter_chain.append("aresample=osf=s16:dither_method=triangular_hp")

    if encode_filter_chain:
        filter_graph = filter_graph + ";[mix]" + ",".join(encode_filter_chain) + "[final]"
        map_label = "[final]"
    else:
        map_label = "[mix]"

    cmd += ["-filter_complex", filter_graph, "-map", map_label]

    # Codec-specific args
    if target_format == "flac":
        compression_level = fmt.get("compression_level", 8)
        cmd += ["-c:a", "flac", "-compression_level", str(compression_level)]
        # Honest container-vs-stored-depth disclosure. Without this flag the
        # encoder may inherit bits_per_raw_sample from upstream metadata or
        # fall back to the s32 container size — silent 32-in-32 output for a
        # 24-bit-honest plan. Cmd 1.
        if target_depth in (16, 24):
            cmd += ["-bits_per_raw_sample", str(target_depth)]
        elif target_depth == 32:
            cmd += ["-sample_fmt", "s32"]
    elif target_format == "wav":
        cmd += ["-c:a", target_codec]
    elif target_format == "aiff":
        cmd += ["-c:a", target_codec, "-f", "aiff"]
    elif target_format == "mp3":
        cmd += ["-c:a", "libmp3lame", "-q:a", "0"]

    # Embed metadata
    md_pairs = _gather_metadata(plan, group)
    for k, v in md_pairs.items():
        cmd += ["-metadata", f"{k}={v}"]

    cmd += [str(output_path)]

    sys.stderr.write(f"[mix] running: {' '.join(_shell_escape(c) for c in cmd)}\n")
    started_at = datetime.now(timezone.utc).isoformat()
    result = subprocess.run(cmd, capture_output=True, text=True)
    finished_at = datetime.now(timezone.utc).isoformat()

    if result.returncode != 0:
        sys.stderr.write(f"[mix] FAILED for group '{group['name']}'\n")
        sys.stderr.write(result.stderr[-2000:] + "\n")
        return {
            "status": "error",
            "reason": "ffmpeg returned non-zero",
            "stderr_tail": result.stderr[-2000:],
            "output": str(output_path),
            "command": cmd,
        }

    # Re-measure the output
    output_measurements = measure_output(output_path)

    # Write sidecar log
    sidecar = render_sidecar_log(
        directory=directory, plan=plan, group=group,
        cmd=cmd, filter_graph=filter_graph,
        started_at=started_at, finished_at=finished_at,
        output_measurements=output_measurements,
        idempotency_key=idempotency_key,
        live_shas=live_shas,
    )
    log_path.write_text(sidecar)

    return {
        "status": "ok",
        "output": str(output_path),
        "output_measurements": output_measurements,
        "idempotency_key": idempotency_key,
        "log": str(log_path),
    }


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


def execute_preview(canonical_path: Path, group: dict) -> dict:
    """Produce <stem>.preview.flac via single-pass loudnorm next to the canonical.

    For headphone listening, never for delivery. The preview is normalized to
    -14 LUFS-I / -1.5 dBTP, which deliberately differs from the canonical's
    unity-sum gain decision. Cmd 17.
    """
    if not canonical_path.exists():
        return {"status": "skipped", "reason": "canonical mix missing"}

    canonical = Path(canonical_path)
    preview_path = canonical.with_suffix("")
    if preview_path.suffix == ".degenerate":  # canonical was <name>.degenerate.flac
        preview_path = preview_path.with_suffix("")
    preview_path = Path(str(preview_path) + ".preview.flac")
    fmt = group["format"]
    target_depth = fmt["depth"]
    compression_level = fmt.get("compression_level", 8)

    target_rate = fmt["rate"]
    # ffmpeg's loudnorm filter internally upsamples to 192 kHz, so pin the
    # output rate explicitly via -ar — otherwise the preview ships at 192 kHz
    # regardless of the canonical's rate.
    cmd = [
        "ffmpeg", "-nostdin", "-hide_banner", "-y",
        "-i", str(canonical),
        # Single-pass loudnorm. The 2-pass approach would be more accurate but
        # adds a probe pass; for a listening copy single-pass is fine and the
        # sidecar labels it explicitly as such.
        "-af", "loudnorm=I=-14:LRA=11:TP=-1.5",
        "-ar", str(target_rate),
        "-c:a", "flac",
        "-compression_level", str(compression_level),
    ]
    # Honest container-vs-stored-depth disclosure for the preview too.
    if target_depth in (16, 24):
        cmd += ["-bits_per_raw_sample", str(target_depth)]
    elif target_depth == 32:
        cmd += ["-bits_per_raw_sample", "24"]  # FLAC clamps; honest for the preview path
    cmd += [
        "-metadata", f"TITLE=PREVIEW — {canonical.stem}",
        "-metadata", "COMMENT=Loudness-normalized preview for headphone listening, NOT for delivery (stems-to-mixdown Cmd 17). Canonical mixdown is the unity-sum FLAC alongside this file.",
        str(preview_path),
    ]
    sys.stderr.write(f"[preview] running: {' '.join(_shell_escape(c) for c in cmd)}\n")
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        return {"status": "error", "reason": "loudnorm encode failed",
                "stderr_tail": result.stderr[-1500:],
                "preview": str(preview_path)}

    # Drop a one-line sidecar so the preview's purpose is unambiguous on disk.
    label = (
        f"# {preview_path.name} — PREVIEW, not the deliverable\n\n"
        f"This file is a loudness-normalized preview of `{canonical.name}` "
        f"for headphone listening. It was produced by ffmpeg's single-pass "
        f"`loudnorm=I=-14:LRA=11:TP=-1.5` and is **not** the canonical "
        f"mixdown. The canonical is the unity-sum FLAC at "
        f"`{canonical.name}` with its own sidecar log. Cmd 17.\n"
    )
    Path(str(preview_path) + ".log.md").write_text(label)
    return {"status": "ok", "preview": str(preview_path)}


def execute_solo(directory: Path, group: dict, plan: dict) -> dict:
    """Bounce each stem individually through the canonical format/dither path.

    Each output lands at <output_dir>/qc/<project>_<stemname>.flac. The
    same pan-law upmix (for mono stems), per-stem manifest gain, uniform
    pre-attenuation, and target rate/depth/dither apply — so the qc bounces
    are honest single-stem renderings of how that stem appears in the
    canonical mix, not raw copies.
    """
    fmt = group["format"]
    target_codec = fmt["codec"]
    target_format = fmt["format"]
    target_depth = fmt["depth"]
    target_rate = fmt["rate"]
    target_channels = fmt["channels"]
    pan_law_db = group.get("pan_law_db", 0.0)
    pan_coef = 10 ** (pan_law_db / 20.0)
    per_stem_gains = group.get("per_stem_gains") or {}
    pre_atten = group.get("pre_attenuation_db", 0.0)
    compression_level = fmt.get("compression_level", 8)
    project = plan["project"]

    canonical_output = Path(group["output_path"])
    qc_dir = canonical_output.parent / "qc"
    qc_dir.mkdir(parents=True, exist_ok=True)

    results: list[dict] = []
    for fn in group["stem_files"]:
        ipath = directory / fn
        if not ipath.is_file():
            results.append({"stem": fn, "status": "skipped", "reason": "input missing"})
            continue
        stem_label = Path(fn).stem
        opath = qc_dir / f"{project}_{stem_label}.flac"

        # Determine input channel count (cheap probe)
        try:
            probe = subprocess.run(
                ["ffprobe", "-v", "error", "-show_entries", "stream=channels,sample_rate",
                 "-of", "json", str(ipath)],
                capture_output=True, text=True, check=True,
            )
            stream = (json.loads(probe.stdout).get("streams") or [{}])[0]
            in_channels = int(stream.get("channels", 2))
            in_rate = int(stream.get("sample_rate", target_rate))
        except Exception:
            in_channels, in_rate = 2, target_rate

        chain_parts: list[str] = []
        if in_channels == 1 and target_channels == 2:
            chain_parts.append(f"pan=stereo|c0={pan_coef:.6f}*c0|c1={pan_coef:.6f}*c0")
        if in_rate != target_rate:
            chain_parts.append(f"aresample=resampler=soxr:precision=28:osr={target_rate}")
        gain = per_stem_gains.get(fn, 0.0)
        if gain != 0.0:
            chain_parts.append(f"volume={gain:+.3f}dB")
        if pre_atten != 0.0:
            chain_parts.append(f"volume={pre_atten:+.3f}dB")
        # Final encode-side filtering identical to execute_group's canonical.
        if target_format == "flac":
            if target_depth <= 16:
                chain_parts.append("aresample=osf=s16:dither_method=triangular_hp")
            elif target_depth in (24, 32):
                chain_parts.append("aresample=osf=s32")

        af = ",".join(chain_parts) if chain_parts else "anull"
        cmd = ["ffmpeg", "-nostdin", "-hide_banner", "-y",
               "-i", str(ipath), "-af", af,
               "-c:a", "flac", "-compression_level", str(compression_level)]
        if target_depth in (16, 24):
            cmd += ["-bits_per_raw_sample", str(target_depth)]
        elif target_depth == 32:
            cmd += ["-bits_per_raw_sample", "24"]  # FLAC clamps; mirror canonical
        cmd += [
            "-metadata", f"TITLE=QC SOLO — {project} ({stem_label})",
            "-metadata", "COMMENT=Per-stem QC bounce. Same format/dither/pan-law/pre-atten as the canonical mix; useful for ear-checking. Not a deliverable.",
            str(opath),
        ]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            results.append({"stem": fn, "status": "error",
                            "stderr_tail": r.stderr[-1500:],
                            "output": str(opath)})
            continue
        results.append({"stem": fn, "status": "ok", "output": str(opath)})

    return {"qc_dir": str(qc_dir), "stems": results}


def execute_reference_bundle(plan: dict, canonical_outputs: dict[str, str],
                              force_overwrite: bool) -> dict:
    """Write the three-synced-versions bundle (Cmd 19).

    For each member in plan.reference_bundle.members:
    - role=master: copy the master file as-is when its codec/depth/rate already
      match the bundle format; otherwise re-encode the bundle copy (only — the
      original is never modified). The master file itself is sacrosanct.
    - role=instrumental / acapella: copy the canonical mixdown (already at the
      bundle format because Pass 2 enforces parity).

    Writes a `bundle.log.md` sidecar with the master's SHA, the three output
    paths, and the rationale block. The sidecar is the bundle's provenance
    record (Cmd 13).
    """
    rb = plan["reference_bundle"]
    bundle_dir = Path(rb["directory"])
    bundle_dir.mkdir(parents=True, exist_ok=True)
    fmt = rb["format"]
    target_codec = fmt["codec"]
    target_depth = fmt["depth"]
    target_rate = fmt["rate"]
    target_format = fmt["format"]
    compression_level = fmt.get("compression_level", 8)

    member_results: list[dict] = []
    any_member_error = False
    for member in rb["members"]:
        role = member["role"]
        out_path = Path(member["output_path"])
        if out_path.exists() and not force_overwrite:
            member_results.append({
                "role": role, "status": "skipped",
                "reason": "exists; use --force-overwrite to rebuild",
                "output": str(out_path),
            })
            continue

        if role == "master":
            src = Path(member["source"])
            if not src.is_file():
                any_member_error = True
                member_results.append({
                    "role": role, "status": "error",
                    "reason": f"master source not found: {src}",
                })
                continue

            if not member.get("needs_reencode"):
                # Pure copy — the master already matches the bundle format.
                # Preserves byte-for-byte identity, fastest path.
                shutil.copy2(src, out_path)
                member_results.append({
                    "role": role, "status": "ok",
                    "output": str(out_path),
                    "method": "copy",
                    "source_sha256": member.get("source_sha256"),
                })
                continue

            # Re-encode into the bundle format. Cmd 19 forbids resampling /
            # requantizing the original; the re-encode is allowed only because
            # the bundle copy is a derivative, and only when format genuinely
            # differs. Pass 2 already refused on rate / depth / channels
            # mismatch — the only legal re-encode here is container/codec
            # conversion (e.g. WAV master into a FLAC bundle).
            cmd = ["ffmpeg", "-nostdin", "-hide_banner", "-y", "-i", str(src)]
            af_parts: list[str] = []
            if target_format == "flac":
                if target_depth <= 16:
                    af_parts.append("aresample=osf=s16:dither_method=triangular_hp")
                elif target_depth in (24, 32):
                    af_parts.append("aresample=osf=s32")
            if af_parts:
                cmd += ["-af", ",".join(af_parts)]
            cmd += ["-c:a", target_codec]
            if target_format == "flac":
                cmd += ["-compression_level", str(compression_level)]
                if target_depth in (16, 24):
                    cmd += ["-bits_per_raw_sample", str(target_depth)]
                elif target_depth == 32:
                    cmd += ["-bits_per_raw_sample", "24"]
            cmd += [
                "-metadata", f"TITLE={plan['project']} (master / bundle copy)",
                "-metadata", "COMMENT=Reference-bundle copy of master, re-encoded into bundle format. Original is unmodified. See bundle.log.md.",
                str(out_path),
            ]
            r = subprocess.run(cmd, capture_output=True, text=True)
            if r.returncode != 0:
                any_member_error = True
                member_results.append({
                    "role": role, "status": "error",
                    "reason": "ffmpeg re-encode failed",
                    "stderr_tail": r.stderr[-1500:],
                })
                continue
            member_results.append({
                "role": role, "status": "ok",
                "output": str(out_path),
                "method": "reencode",
                "source_sha256": member.get("source_sha256"),
            })
            continue

        # role in {instrumental, acapella}: produce a unity-sum version of
        # this group, regardless of whether the canonical was normalized.
        # Null tests against the master only work on un-normalized inputs
        # (Cmd 19 + Cmd 9 revised). When the run is --archival the canonical
        # IS the unity sum and we can copy; when normalized we re-render
        # from the group's filter graph in the bundle's target format.
        group_def = next(
            (g for g in plan.get("groups", []) if g.get("name") == role),
            None,
        )
        if group_def is None:
            any_member_error = True
            member_results.append({
                "role": role, "status": "error",
                "reason": f"plan has no group named '{role}'",
            })
            continue

        if group_def.get("normalization") is None:
            # Archival path: canonical is unity-sum, copy it.
            canon_path = canonical_outputs.get(role)
            if not canon_path or not Path(canon_path).is_file():
                any_member_error = True
                member_results.append({
                    "role": role, "status": "error",
                    "reason": f"canonical mixdown for '{role}' not found",
                })
                continue
            shutil.copy2(canon_path, out_path)
            member_results.append({
                "role": role, "status": "ok",
                "output": str(out_path),
                "method": "copy",
                "source": canon_path,
            })
            continue

        # Normalized canonical: render unity-sum into the bundle.
        directory = Path(plan["directory"])
        cmd = ["ffmpeg", "-nostdin", "-hide_banner", "-y"]
        for fn in group_def["stem_files"]:
            cmd += ["-i", str(directory / fn)]
        encode_chain = _build_dither_chain(target_format, target_depth)
        if encode_chain:
            filter_graph = (group_def["filter_graph"]
                            + ";[mix]" + ",".join(encode_chain) + "[final]")
            map_label = "[final]"
        else:
            filter_graph = group_def["filter_graph"]
            map_label = "[mix]"
        cmd += ["-filter_complex", filter_graph, "-map", map_label]
        cmd += _build_codec_args(rb["format"])
        cmd += [
            "-metadata",
            f"TITLE={plan['project']} (bundle / {role}, unity-sum for null tests)",
            "-metadata",
            "COMMENT=Reference-bundle copy: unity-sum render (no normalization). "
            "The canonical mixdown alongside this bundle is the listening master; "
            "this file is the witness against the released master. (Cmd 19, Cmd 9 revised)",
            str(out_path),
        ]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            any_member_error = True
            member_results.append({
                "role": role, "status": "error",
                "reason": "bundle unity-sum re-render failed",
                "stderr_tail": r.stderr[-1500:],
            })
            continue
        member_results.append({
            "role": role, "status": "ok",
            "output": str(out_path),
            "method": "render_unity_sum",
        })

    # Bundle sidecar log
    log_path = bundle_dir / "bundle.log.md"
    started = datetime.now(timezone.utc).isoformat()
    log_lines = [
        f"# {plan['project']} — reference bundle\n",
        f"_Written by stems-to-mixdown v{__version__} at {started}_\n",
        "## Doctrine\n",
        "The master is the witness, not the source (Cmd 19). This bundle exists for "
        "synchronized A/B listening and Pass 5 null-test verification. The master "
        "file at the source path is **never modified**; if a re-encode was required "
        "to match the bundle format, only the bundle copy is re-encoded.\n",
        "## Format\n",
        f"- {fmt['format']} / {fmt['rate']} Hz / {fmt['depth']}-bit / {fmt['channels']}ch",
        f"- Compression level: {compression_level}" if target_format == "flac" else "",
        "",
        "## Members\n",
        "| Role | Output | Method | Source SHA-256 |",
        "|---|---|---|---|",
    ]
    for r in member_results:
        sha = (r.get("source_sha256") or "")[:16]
        log_lines.append(
            f"| {r['role']} | `{r.get('output','—')}` | "
            f"{r.get('method', r.get('status'))} | "
            f"{sha + '…' if sha else '—'} |"
        )
    log_lines += [
        "",
        "## Rationale\n",
        rb["rationale"],
        "",
        "## Verify\n",
        "Pass 5 will run the reference battery against this bundle:\n",
        "- **Recombine null:** `(instrumental + acapella) - master` → residual dBTP. "
        "Pass ≤ -90; smell -60 to -90; fail > -60.",
        "- **Inverse-stems nulls:** `master - acapella` ≈ instrumental and "
        "`master - instrumental` ≈ acapella. Should null roughly the same.",
        "- **LUFS-I and dBTP deltas vs master** for both deliverables — "
        "informational, not normalized (Cmd 9).",
        "",
        f"Run: `python3 stems_to_mixdown/verify.py --plan <plan.json>`",
        "",
    ]
    log_path.write_text("\n".join(line for line in log_lines if line is not None))

    status = "error" if any_member_error else "ok"
    return {
        "status": status,
        "directory": str(bundle_dir),
        "members": member_results,
        "log": str(log_path),
    }


def execute_master_listening(plan: dict, force_overwrite: bool) -> dict:
    """v1.3: produce <project>_master_listening.<ext> — a normalized
    listening copy of the master file, sitting alongside the canonical
    mixdowns (NOT inside the reference-bundle/ dir, because the bundle's
    contract is unity-sum). Cmd 9 (revised) + Cmd 19.
    """
    ml = plan.get("master_listening")
    if not ml:
        return {"status": "skipped", "reason": "no master_listening member in plan"}

    src = Path(ml["source"])
    out_path = Path(ml["output_path"])
    if not src.is_file():
        return {"status": "error", "reason": f"master not found: {src}",
                "output": str(out_path)}
    out_path.parent.mkdir(parents=True, exist_ok=True)

    if out_path.exists() and not force_overwrite:
        return {"status": "skipped", "reason": "exists; use --force-overwrite to rebuild",
                "output": str(out_path)}

    norm_cfg = ml["normalization"]
    fmt = ml["format"]

    # Stage 1: copy the master into a 32-bit float intermediate so loudnorm
    # operates on full-precision data regardless of the master's container.
    with tempfile.NamedTemporaryFile(
        prefix=f"s2m_{plan['project']}_master_listening_",
        suffix=".wav",
        dir=str(out_path.parent),
        delete=False,
    ) as tmp:
        intermediate = Path(tmp.name)
    started_at = datetime.now(timezone.utc).isoformat()
    try:
        cmd1 = [
            "ffmpeg", "-nostdin", "-hide_banner", "-y",
            "-i", str(src),
            "-c:a", "pcm_f32le", "-ar", str(fmt["rate"]),
            str(intermediate),
        ]
        r1 = subprocess.run(cmd1, capture_output=True, text=True)
        if r1.returncode != 0:
            return {"status": "error", "reason": "intermediate render failed",
                    "stderr_tail": r1.stderr[-1500:], "output": str(out_path)}

        measurements = measure_loudnorm_first_pass(intermediate, norm_cfg)
        if not measurements:
            return {"status": "error", "reason": "loudnorm first-pass failed",
                    "output": str(out_path)}

        metadata = {
            "TITLE": f"{plan['project']} (master listening copy)",
            "COMMENT": (
                f"Loudness-normalized listening copy of the master at "
                f"{norm_cfg['target_lufs']} LUFS-I / {norm_cfg['target_true_peak']} dBTP. "
                f"The original master file is unmodified; the unity-sum master inside "
                f"reference-bundle/ is what null tests run against. (Cmd 9 revised, Cmd 19)"
            ),
        }
        cmd2, filter_chain = build_normalized_command(
            intermediate, out_path, fmt, norm_cfg, measurements, metadata,
        )
        sys.stderr.write(
            f"[master_listening] running: {' '.join(_shell_escape(c) for c in cmd2)}\n"
        )
        r2 = subprocess.run(cmd2, capture_output=True, text=True)
        if r2.returncode != 0:
            return {"status": "error", "reason": "second-pass loudnorm failed",
                    "stderr_tail": r2.stderr[-1500:], "output": str(out_path)}
    finally:
        try:
            intermediate.unlink()
        except OSError:
            pass

    finished_at = datetime.now(timezone.utc).isoformat()
    output_measurements = measure_output(out_path)

    # Sidecar log for the listening copy.
    log_path = Path(str(out_path) + ".log.md")
    log_lines = [
        f"# {out_path.name} — provenance log\n",
        f"_Written by stems-to-mixdown v{__version__} at {finished_at}_\n",
        "## What this is\n",
        "Normalized listening copy of the master reference. The bundle in "
        "`reference-bundle/` keeps the master at unity sum so null tests "
        "against the deliverables work; this file exists as a comfortable "
        "A/B reference at the same loudness target as the canonical mixdowns. "
        "(Cmd 9 revised, Cmd 19.)\n",
        "## Source\n",
        f"- **Master:** `{src}`",
        f"- **Source SHA-256:** `{ml.get('source_sha256', '')[:32]}…`",
        "",
        "## Normalization\n",
        f"- **Target:** {norm_cfg['target_lufs']} LUFS-I, "
        f"{norm_cfg['target_true_peak']} dBTP, LRA cap {norm_cfg['lra_target']} LU "
        f"(loudnorm two-pass linear=true + alimiter)",
        f"- **Loudnorm first-pass:** I={measurements.get('input_i')} LUFS, "
        f"TP={measurements.get('input_tp')} dBTP, "
        f"LRA={measurements.get('input_lra')} LU",
        f"- **Output:** I={output_measurements.get('integrated_lufs')} LUFS, "
        f"TP={output_measurements.get('true_peak_dbtp')} dBTP, "
        f"LRA={output_measurements.get('loudness_range')} LU",
        "",
        "## Timestamps\n",
        f"- Started: {started_at}",
        f"- Finished: {finished_at}",
        "",
    ]
    log_path.write_text("\n".join(log_lines))

    return {
        "status": "ok",
        "output": str(out_path),
        "log": str(log_path),
        "loudnorm_measurements": measurements,
        "output_measurements": output_measurements,
    }


def _shell_escape(arg: str) -> str:
    if not arg or any(c in arg for c in ' \t"\'$`\\'):
        return "'" + arg.replace("'", "'\\''") + "'"
    return arg


def _gather_metadata(plan: dict, group: dict) -> dict[str, str]:
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


# ---------------------------------------------------------------------------
# Sidecar log rendering
# ---------------------------------------------------------------------------

def render_sidecar_log(directory: Path, plan: dict, group: dict, cmd: list[str],
                       filter_graph: str, started_at: str, finished_at: str,
                       output_measurements: dict,
                       idempotency_key: str = "",
                       live_shas: dict[str, str] | None = None,
                       normalization: dict | None = None) -> str:
    fmt = group["format"]
    live_shas = live_shas or {}
    lines = []
    lines.append(f"# {Path(group['output_path']).name} — provenance log\n")
    lines.append(f"_Written by stems-to-mixdown v{__version__} at {finished_at}_\n")
    if idempotency_key:
        lines.append(f"{IDEMPOTENCY_TAG}: `{idempotency_key}`\n")

    lines.append("## Summary\n")
    lines.append(f"- **Project:** `{plan['project']}`")
    lines.append(f"- **Group:** `{group['name']}`")
    lines.append(f"- **Output format:** {fmt['format']} / {fmt['rate']} Hz / "
                 f"{fmt['depth'] or 'lossy'}-bit / {fmt['channels']}ch")
    lines.append(f"- **Format rationale:** {fmt['rationale']}")
    lines.append(f"- **Pre-attenuation:** {group['pre_attenuation_db']:+.3f} dB ({group['pre_attenuation_rationale']})")
    if group.get("has_mono_stems"):
        pan_law_db = group.get("pan_law_db", 0.0)
        pan_law_coef = group.get("pan_law_coefficient", 1.0)
        default_note = " (default — manifest output.pan_law unset)" if group.get("pan_law_was_default") else ""
        lines.append(f"- **Pan law:** {pan_law_db:+.1f} dB → coefficient {pan_law_coef:.6f} per channel on mono→stereo upmix{default_note}")
    if fmt.get("lie"):
        lines.append(f"- **⚠️ DEGENERATE OUTPUT:** exceeds source ceiling. See rationale.")
    lines.append("")

    lines.append("## Inputs\n")
    lines.append("| Filename | SHA-256 | Codec | Rate | Depth | Channels | Duration | True Peak | LUFS-I |")
    lines.append("|---|---|---|---|---|---|---|---|---|")
    # Pull stem details from analysis (we have the plan, but per-stem details live in analysis;
    # we reconstruct a slim view from the plan + a fresh probe of the inputs).
    plan_shas = group.get("stem_shas") or {}
    drift_notes: list[str] = []
    for fn in group["stem_files"]:
        ipath = directory / fn
        try:
            probe = subprocess.run(
                ["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(ipath)],
                capture_output=True, text=True, check=True,
            )
            data = json.loads(probe.stdout)
            stream = next((s for s in data.get("streams", []) if s.get("codec_type") == "audio"), {})
            fmtinfo = data.get("format", {})
            sha = live_shas.get(fn) or hash_file(ipath)
            plan_sha = plan_shas.get(fn)
            if plan_sha and plan_sha != sha:
                drift_notes.append(
                    f"`{fn}`: analyze-time SHA `{plan_sha[:12]}…` ≠ mix-time SHA `{sha[:12]}…`"
                )
            lines.append(
                f"| `{fn}` | `{sha[:16]}…` | {stream.get('codec_name','?')} | "
                f"{stream.get('sample_rate','?')} Hz | "
                f"{stream.get('bits_per_raw_sample') or stream.get('sample_fmt','?')} | "
                f"{stream.get('channels','?')} | "
                f"{float(fmtinfo.get('duration', 0)):.3f}s | "
                f"— | — |"
            )
        except Exception as e:
            lines.append(f"| `{fn}` | _probe failed: {e}_ | | | | | | | |")
    if drift_notes:
        lines.append("")
        lines.append("**Input drift:** content changed between Pass 1 (analyze) and Pass 4 (mix). "
                     "The mix used the live content; re-run analyze to refresh the plan if the change was unintentional.")
        for note in drift_notes:
            lines.append(f"- {note}")
    lines.append("")

    lines.append("## Per-stem manifest gains\n")
    if any(v != 0.0 for v in (group.get("per_stem_gains") or {}).values()):
        for fn, gain in group["per_stem_gains"].items():
            if gain != 0.0:
                lines.append(f"- `{fn}` → `{gain:+.3f} dB`")
    else:
        lines.append("None.")
    lines.append("")

    lines.append("## Filter graph\n```")
    lines.append(filter_graph)
    lines.append("```\n")

    lines.append("## Exact command\n```")
    lines.append(" ".join(_shell_escape(c) for c in cmd))
    lines.append("```\n")

    lines.append("## Measurements\n")
    lines.append(f"- **Predicted mix peak (pre-attenuation):** "
                 f"{group['measured_peak_dbtp']:.2f} dBTP" if group['measured_peak_dbtp'] is not None
                 else "- **Predicted mix peak:** unavailable")
    lines.append(f"- **Output true peak:** "
                 f"{output_measurements['true_peak_dbtp']:.2f} dBTP" if output_measurements.get('true_peak_dbtp') is not None
                 else "- **Output true peak:** unavailable")
    lines.append(f"- **Output LUFS-I:** "
                 f"{output_measurements['integrated_lufs']:.2f} LUFS" if output_measurements.get('integrated_lufs') is not None
                 else "- **Output LUFS-I:** unavailable")
    lines.append(f"- **Output LRA:** "
                 f"{output_measurements['loudness_range']:.2f} LU" if output_measurements.get('loudness_range') is not None
                 else "- **Output LRA:** unavailable")
    lines.append("")

    # v1.3: normalization stages are recorded explicitly so the unity-sum
    # intermediate's measurements are preserved next to the final output's.
    if normalization is not None:
        cfg = normalization.get("config") or {}
        unity = normalization.get("unity_sum_measurements") or {}
        meas = normalization.get("first_pass_measurements") or {}
        lines.append("## Normalization (Cmd 9 revised)\n")
        lines.append(f"- **Target:** {cfg.get('target_lufs')} LUFS-I, "
                     f"{cfg.get('target_true_peak')} dBTP, LRA cap {cfg.get('lra_target')} LU "
                     f"({cfg.get('method', 'loudnorm+alimiter')}; "
                     f"{'two-pass, linear=true' if cfg.get('two_pass') else 'single-pass'})")
        lines.append(f"- **Unity-sum intermediate:** "
                     f"I={unity.get('integrated_lufs')} LUFS, "
                     f"TP={unity.get('true_peak_dbtp')} dBTP, "
                     f"LRA={unity.get('loudness_range')} LU")
        lines.append(f"- **Loudnorm first-pass measurements:** "
                     f"I={meas.get('input_i')} LUFS, "
                     f"TP={meas.get('input_tp')} dBTP, "
                     f"LRA={meas.get('input_lra')} LU, "
                     f"thresh={meas.get('input_thresh')}, "
                     f"target_offset={meas.get('target_offset')} dB")
        lines.append(f"- **Final filter chain:** `{normalization.get('second_pass_filter_chain', '')}`")
        lines.append("")

    lines.append("## Tool versions\n")
    lines.append(f"- ffmpeg: `{tool_version('ffmpeg')}`")
    lines.append(f"- ffprobe: `{tool_version('ffprobe')}`")
    lines.append(f"- sox: `{tool_version('sox')}`")
    lines.append("")

    lines.append("## Timestamps\n")
    lines.append(f"- Started: {started_at}")
    lines.append(f"- Finished: {finished_at}")
    lines.append("")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description="stems-to-mixdown / Pass 4 (mix)")
    parser.add_argument("--plan", required=True, type=Path, help="Path to plan.json from Pass 3")
    parser.add_argument("--force-overwrite", action="store_true",
                        help="Re-mix even if output already exists with matching sidecar")
    parser.add_argument("--yes", action="store_true",
                        help="Skip the plan-summary confirmation prompt")
    parser.add_argument("--preview", action="store_true",
                        help=("Additionally produce <project>_<group>.preview.flac "
                              "via single-pass loudnorm (I=-14, LRA=11, TP=-1.5). "
                              "For headphone listening, NOT for delivery (Cmd 17). "
                              "The canonical mixdown is unchanged."))
    parser.add_argument("--solo", action="store_true",
                        help=("Bounce each stem individually through the same "
                              "format/dither path. Outputs land in "
                              "<output_dir>/qc/<project>_<stemname>.flac. Useful "
                              "for ear-checking without DAW access. Pre-attenuation, "
                              "manifest gain trims, and the pan-law upmix are all "
                              "applied per-stem to match the canonical mix's "
                              "treatment of that stem."))
    args = parser.parse_args()

    if not args.plan.is_file():
        sys.stderr.write(f"[fatal] plan file not found: {args.plan}\n")
        return 2
    with args.plan.open("r") as f:
        plan = json.load(f)

    directory = Path(plan["directory"])

    sys.stderr.write(f"\n=== stems-to-mixdown v{__version__} / mix ===\n")
    sys.stderr.write(f"Project: {plan['project']}\n")
    sys.stderr.write(f"Groups: {[g['name'] for g in plan['groups']]}\n")
    sys.stderr.write(f"Output dir: {plan['output_directory']}\n\n")

    if not args.yes:
        sys.stderr.write("Proceed? [type 'yes' to continue, anything else to abort] ")
        sys.stderr.flush()
        ans = sys.stdin.readline().strip().lower()
        if ans != "yes":
            sys.stderr.write("Aborted.\n")
            return 0

    results = []
    any_error = False
    canonical_outputs: dict[str, str] = {}
    for group in plan["groups"]:
        sys.stderr.write(f"\n--- Group: {group['name']} ---\n")
        result = execute_group(directory, group, plan, args.force_overwrite)
        results.append({"group": group["name"], **result})
        if result["status"] == "error":
            any_error = True
        else:
            # Track canonical paths so the bundle can copy them into reference-bundle/.
            canonical_outputs[group["name"]] = result.get("output", "")
        sys.stderr.write(f"[{result['status']}] {result.get('output','')}\n")
        if args.preview and result.get("output"):
            preview = execute_preview(Path(result["output"]), group)
            result["preview"] = preview
            sys.stderr.write(f"[preview {preview['status']}] {preview.get('preview','')}\n")
            if preview.get("status") == "error":
                any_error = True
        if args.solo:
            solo = execute_solo(directory, group, plan)
            result["solo"] = solo
            ok = sum(1 for s in solo["stems"] if s["status"] == "ok")
            err = sum(1 for s in solo["stems"] if s["status"] == "error")
            sys.stderr.write(f"[solo] {ok} ok, {err} error in {solo['qc_dir']}\n")
            if err:
                any_error = True

    # Reference bundle (Cmd 19). Runs only when plan.reference_bundle is set
    # and no canonical groups errored. The bundle is the deliverable for the
    # operator who supplied a master reference.
    if plan.get("reference_bundle") is not None and not any_error:
        sys.stderr.write(f"\n--- Reference bundle ---\n")
        bundle_result = execute_reference_bundle(plan, canonical_outputs,
                                                  args.force_overwrite)
        results.append({"group": "reference-bundle", **bundle_result})
        if bundle_result["status"] == "error":
            any_error = True
        sys.stderr.write(f"[{bundle_result['status']}] {bundle_result.get('directory','')}\n")
    elif plan.get("reference_bundle") is not None and any_error:
        sys.stderr.write(f"\n[skip] reference bundle: at least one canonical group errored; "
                         f"the bundle requires all canonical mixdowns to succeed.\n")

    # v1.3: master listening copy (Cmd 9 revised + Cmd 19). Runs only when
    # the plan includes master_listening and no canonical groups errored.
    if plan.get("master_listening") is not None and not any_error:
        sys.stderr.write(f"\n--- Master listening copy ---\n")
        ml_result = execute_master_listening(plan, args.force_overwrite)
        results.append({"group": "master-listening", **ml_result})
        if ml_result.get("status") == "error":
            any_error = True
        sys.stderr.write(
            f"[{ml_result.get('status')}] {ml_result.get('output','')}\n"
        )

    sys.stdout.write(json.dumps({"results": results}, indent=2, default=str))
    sys.stdout.write("\n")
    return 1 if any_error else 0


if __name__ == "__main__":
    sys.exit(main())

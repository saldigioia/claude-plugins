"""Two-pass loudnorm pipeline (Cmd 9 revised in v1.3).

Renders the group's unity sum to a 32-bit float intermediate, runs
loudnorm in measurement mode (first pass), then runs loudnorm in apply
mode + alimiter (true-peak ceiling) + dither + encode (second pass).
The unity-sum intermediate gets a separate informational measurement so
the sidecar can show the operator what the unprocessed mix looked like
before normalization.
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from stems_to_mixdown import _measure
from stems_to_mixdown._mix_helpers import (
    build_codec_args,
    build_dither_chain,
    gather_metadata,
    measure_output,
    shell_escape,
)
from stems_to_mixdown._mix_sidecar import render_sidecar_log


def parse_loudnorm_json(stderr: str) -> dict:
    """Extract the `print_format=json` block from loudnorm's stderr output.

    ffmpeg loudnorm prints either a `[Parsed_loudnorm_0 @ 0x...]` line
    followed by JSON, or just JSON, depending on log level. Find the last
    JSON object that looks like loudnorm's measurement block and return
    it parsed (string values intact — that's what loudnorm wants on the
    second pass).
    """
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
    dither_chain = build_dither_chain(fmt["format"], fmt["depth"])
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
    cmd += build_codec_args(fmt)
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

        unity_summary = _measure.measure_loudness_file(intermediate)

        measurements = measure_loudnorm_first_pass(intermediate, norm_cfg)
        if not measurements:
            return {
                "status": "error",
                "reason": "loudnorm first-pass measurement failed",
                "output": str(output_path),
            }

        metadata = gather_metadata(plan, group)
        cmd, filter_chain = build_normalized_command(
            intermediate, output_path, fmt, norm_cfg, measurements, metadata,
        )
        sys.stderr.write(
            f"[mix:normalized] running: {' '.join(shell_escape(c) for c in cmd)}\n"
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

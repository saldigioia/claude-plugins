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
from stems_to_mixdown._mix_helpers import (  # noqa: E402
    IDEMPOTENCY_TAG,
    compute_idempotency_key,
    gather_metadata as _gather_metadata,
    measure_output,
    shell_escape as _shell_escape,
)
from stems_to_mixdown._mix_sidecar import render_sidecar_log  # noqa: E402
from stems_to_mixdown._mix_normalize import execute_group_normalized  # noqa: E402
from stems_to_mixdown._mix_bundle import (  # noqa: E402
    execute_master_listening, execute_reference_bundle,
)


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

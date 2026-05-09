"""Optional QC paths invoked by mix.py's main() orchestrator.

Both functions are opt-in via CLI flags and have nothing to do with
the canonical archival or normalized deliverable:

- execute_preview (--preview): single-pass loudnorm copy for headphone
  listening, labeled `*.preview.flac` with a sidecar that explicitly
  marks it as not the deliverable. Cmd 17.
- execute_solo (--solo): per-stem QC bounces under <out>/qc/, each
  rendered through the same pan-law upmix / per-stem gain /
  pre-attenuation / dither chain the canonical mix used. Useful for
  ear-checking; not a deliverable.

Kept out of mix.py because they're peripheral to the per-group
canonical bouncer (execute_group) that is the heart of Pass 4.
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

from stems_to_mixdown._mix_helpers import shell_escape


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
    sys.stderr.write(f"[preview] running: {' '.join(shell_escape(c) for c in cmd)}\n")
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

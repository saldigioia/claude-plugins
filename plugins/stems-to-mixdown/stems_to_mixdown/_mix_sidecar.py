"""Sidecar log rendering for the mix pipeline.

Single function: render_sidecar_log. Composes the markdown provenance
log written next to each canonical output (input SHAs, exact ffmpeg
command, filter graph, before/after measurements, tool versions,
SHA-anchored idempotency key, optional normalization stage record).
"""
from __future__ import annotations

import json
import subprocess
from pathlib import Path

from stems_to_mixdown._mix_helpers import (
    IDEMPOTENCY_TAG,
    hash_file,
    shell_escape,
    tool_version,
)
from stems_to_mixdown._version import __version__


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
    lines.append(" ".join(shell_escape(c) for c in cmd))
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

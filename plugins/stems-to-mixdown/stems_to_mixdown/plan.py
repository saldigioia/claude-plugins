#!/usr/bin/env python3
"""
plan.py — Pass 3 (Plan / Dry-Run).

Reads analysis.json, applies the format-decision matrix, measures the actual
mixdown peak via a 32-bit-float null-sink pass, computes pre-attenuation if
needed, and emits plan.json on stdout. Markdown plan goes to stderr for human
review.

This script does NOT mix audio to disk. It only plans. Pass 4 (mix.py) executes.

Exit codes:
    0  = plan generated successfully
    1  = plan generation failed
    2  = structural error
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# Allow `python3 stems_to_mixdown/plan.py` invocation alongside `python3 -m stems_to_mixdown.plan`
if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from stems_to_mixdown import _measure  # noqa: E402
from stems_to_mixdown._plan_pan import (  # noqa: E402,F401
    ALLOWED_PAN_LAWS, DEFAULT_PAN_LAW_DB,
    auto_pan_for_group, auto_pan_positions,
    pan_coefficients, resolve_pan_law, resolve_pan_map,
)
from stems_to_mixdown._plan_format_decision import decide_output_format  # noqa: E402
from stems_to_mixdown._plan_render import render_plan_markdown, what_this_means  # noqa: E402,F401

# ---------------------------------------------------------------------------
# Group derivation
# ---------------------------------------------------------------------------

def derive_groups(stems: list[dict], manifest: dict) -> dict[str, list[str]]:
    """Return {group_name: [filename, ...]}, applying manifest overrides."""
    manifest_groups = (manifest or {}).get("groups") or {}

    # Automatic groups, only if not overridden in manifest
    auto: dict[str, list[str]] = {}
    vocals = [s["filename"] for s in stems if s["classification"] == "vocal"]
    non_vocals = [s["filename"] for s in stems if s["classification"] != "vocal"]
    if "acapella" not in manifest_groups and vocals:
        auto["acapella"] = vocals
    if "instrumental" not in manifest_groups and non_vocals:
        auto["instrumental"] = non_vocals

    # Manifest groups override / add
    groups = {**auto}
    for name, files in manifest_groups.items():
        groups[name] = list(files)

    # Validate: every file referenced must exist in the stems list
    valid_filenames = {s["filename"] for s in stems}
    for name, files in groups.items():
        missing = [f for f in files if f not in valid_filenames]
        if missing:
            raise SystemExit(
                f"[fatal] manifest group '{name}' references files not in directory: {missing}. "
                f"Fix the manifest; no silent skipping. (Cmd 12)"
            )

    # Drop empty groups
    groups = {n: f for n, f in groups.items() if f}
    return groups


# ---------------------------------------------------------------------------
# Filter graph construction
# ---------------------------------------------------------------------------

def build_filter_graph(group_stems: list[dict], target_rate: int, target_channels: int,
                       per_stem_gains: dict[str, float], pre_atten_db: float = 0.0,
                       pan_law_db: float = DEFAULT_PAN_LAW_DB,
                       pan_map: dict[str, float] | None = None) -> str:
    """
    Construct an ffmpeg filter_complex graph for the group.
    - Mono stems are upmixed to stereo via pan, placed at their declared
      pan position (default 0 = center) using the constant-power curve
      renormalized to the declared pan law (Cmd 16 + Cmd 20).
    - Stereo stems are NOT re-panned (Cmd 20: the plugin doesn't decorate
      stereo). The pan map applies to mono inputs only.
    - Stems with non-target rate get aresample.
    - Per-stem gain trim from manifest.
    - Uniform pre-attenuation in dB applied to every stem.
    - Final stage is amix=normalize=0 with weights=1.
    """
    pan_map = pan_map or {}
    chains = []
    labels = []
    for i, s in enumerate(group_stems):
        chain = f"[{i}:a]"
        # Channel reconciliation + per-stem pan placement (mono only).
        if s["channels"] == 1 and target_channels == 2:
            pan_position = pan_map.get(s["filename"], 0.0)
            l_coef, r_coef = pan_coefficients(pan_position, pan_law_db)
            chain += f"pan=stereo|c0={l_coef:.6f}*c0|c1={r_coef:.6f}*c0,"
        # Rate reconciliation
        if s["sample_rate"] != target_rate:
            chain += f"aresample=resampler=soxr:precision=28:osr={target_rate},"
        # Per-stem manifest gain
        gain = per_stem_gains.get(s["filename"], 0.0)
        if gain != 0.0:
            chain += f"volume={gain:+.3f}dB,"
        # Uniform pre-attenuation
        if pre_atten_db != 0.0:
            chain += f"volume={pre_atten_db:+.3f}dB,"
        chain = chain.rstrip(",")
        if chain == f"[{i}:a]":
            # No filtering needed for this stem; pass raw stream label
            labels.append(f"[{i}:a]")
            continue
        out_label = f"[a{i}]"
        chains.append(chain + out_label)
        labels.append(out_label)
    n = len(group_stems)
    weights = " ".join(["1"] * n)
    inputs = "".join(labels)
    mix = f"{inputs}amix=inputs={n}:duration=longest:normalize=0:weights={weights}[mix]"
    parts = chains + [mix]
    return ";".join(parts)


# ---------------------------------------------------------------------------
# Peak measurement (the honest one)
# ---------------------------------------------------------------------------

def measure_mix_peak(directory: Path, group_stems: list[dict],
                     filter_graph: str) -> tuple[float | None, float | None]:
    """
    Run the planned mix to a null sink at 32-bit float, measure true peak via ebur128.
    Returns (true_peak_dbtp, integrated_lufs).
    """
    cmd = ["ffmpeg", "-nostdin", "-hide_banner"]
    for s in group_stems:
        cmd += ["-i", str(directory / s["filename"])]
    cmd += [
        "-filter_complex", filter_graph + ";[mix]ebur128=peak=true[out]",
        "-map", "[out]",
        "-f", "null", "-",
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    summary = _measure.parse_ebur128_summary(result.stderr)
    return summary["true_peak_dbtp"], summary["integrated_lufs"]


# ---------------------------------------------------------------------------
# Pre-attenuation policy
# ---------------------------------------------------------------------------

def compute_pre_attenuation(measured_peak_dbtp: float | None) -> tuple[float, str]:
    """Returns (pre_attenuation_db, rationale)."""
    if measured_peak_dbtp is None:
        return 0.0, "Peak measurement unavailable; sum as-is."
    if measured_peak_dbtp < -3.0:
        return 0.0, f"Peak {measured_peak_dbtp:.2f} dBTP — comfortable headroom, no attenuation. (Cmd 3)"
    if measured_peak_dbtp <= -1.0:
        return 0.0, f"Peak {measured_peak_dbtp:.2f} dBTP — acceptable, no attenuation. (Cmd 3)"
    # Attenuate to land at -3 dBTP
    atten = -(measured_peak_dbtp + 3.0)
    rationale = (f"Peak {measured_peak_dbtp:.2f} dBTP → pre-attenuate {atten:+.2f} dB "
                 f"(uniform across stems; relative balance preserved). (Cmd 2, Cmd 3)")
    return atten, rationale


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description="stems-to-mixdown / Pass 3 (plan)")
    parser.add_argument("--analysis", required=True, type=Path,
                        help="Path to analysis.json from Pass 1+2")
    parser.add_argument("--output-dir", type=Path, default=None,
                        help=("Override output directory. Default: a sibling "
                              "directory `<parent>/<dirname>-mixdowns/` so the "
                              "source folder is never written into."))
    parser.add_argument("--auto-pan", action="store_true", default=False,
                        help=("Spread mono stems classified the same (e.g. several "
                              "percussion stems) across the stereo field with the "
                              "default-distribution rule. Vocals and bass stay center. "
                              "Stereo stems pass through unchanged. Cmd 20."))
    parser.add_argument("--archival", action="store_true", default=False,
                        help=("Produce unity-sum unprocessed output (the v1.2 behavior). "
                              "Inverse of the default normalized listening master. "
                              "Cmd 9 (revised in v1.3)."))
    parser.add_argument("--target-lufs", type=float, default=None,
                        help=("Integrated-loudness target in LUFS-I. Default -14 "
                              "(Spotify / YouTube / Tidal / Amazon convention). "
                              "-16 for Apple-Music-first delivery; -23 for EBU R128 "
                              "broadcast. Manifest output.target_lufs overrides. (Cmd 9)"))
    parser.add_argument("--target-true-peak", type=float, default=None,
                        help=("True-peak ceiling in dBTP. Default -1.0 (modern "
                              "streaming standard); -1.5 for conservative AAC/Ogg "
                              "transcoding headroom; -2.0 for ATSC A/85 broadcast. "
                              "Manifest output.target_true_peak overrides. (Cmd 9)"))
    args = parser.parse_args()

    if not args.analysis.is_file():
        sys.stderr.write(f"[fatal] analysis file not found: {args.analysis}\n")
        return 2

    with args.analysis.open("r") as f:
        analysis = json.load(f)

    directory = Path(analysis["directory"])
    manifest = analysis.get("manifest") or {}
    stems = analysis["stems"]

    # Determine project name
    project = (manifest.get("project") or directory.name).strip()
    project = re.sub(r"[^\w\-.]+", "_", project)

    # Output directory. The default is a sibling of the source dir so the
    # source folder is never written into — archival source folders should be
    # read-only. Use --output-dir to override.
    output_dir = args.output_dir or (directory.parent / f"{directory.name}-mixdowns")

    # Derive groups
    groups = derive_groups(stems, manifest)
    stems_by_filename = {s["filename"]: s for s in stems}
    per_stem_gains = (manifest.get("gains") or {})
    manifest_output = manifest.get("output")

    pan_law_db, pan_law_was_default = resolve_pan_law(manifest_output)
    pan_law_coef = 10 ** (pan_law_db / 20.0)
    # Auto-pan: CLI > manifest > false. CLI is opt-in only — the manifest's
    # output.auto_pan: true is also respected so manifests stay reproducible.
    manifest_auto_pan = bool((manifest_output or {}).get("auto_pan"))
    use_auto_pan = bool(args.auto_pan) or manifest_auto_pan

    # Cmd 9 (revised in v1.3): default deliverable is normalized to a
    # streaming-compatible LUFS-I + true-peak ceiling. --archival or
    # output.archival: true reverts to the v1.2 unity-sum behavior.
    manifest_archival = bool((manifest_output or {}).get("archival"))
    archival = bool(args.archival) or manifest_archival
    manifest_target_lufs = (manifest_output or {}).get("target_lufs")
    manifest_target_tp = (manifest_output or {}).get("target_true_peak")
    target_lufs = (
        float(args.target_lufs) if args.target_lufs is not None
        else float(manifest_target_lufs) if manifest_target_lufs is not None
        else -14.0
    )
    target_true_peak = (
        float(args.target_true_peak) if args.target_true_peak is not None
        else float(manifest_target_tp) if manifest_target_tp is not None
        else -1.0
    )
    normalization_template: dict[str, Any] | None
    if archival:
        normalization_template = None
    else:
        normalization_template = {
            "target_lufs": target_lufs,
            "target_true_peak": target_true_peak,
            "lra_target": 11.0,
            "two_pass": True,
            "method": "loudnorm+alimiter",
        }

    plan_groups = []
    any_lie = False
    for group_name, filenames in groups.items():
        group_stems = [stems_by_filename[fn] for fn in filenames]
        fmt = decide_output_format(group_stems, manifest_output)
        any_lie = any_lie or fmt["lie"]

        has_mono = any(s["channels"] == 1 for s in group_stems)
        if has_mono:
            note = f"Pan law: {pan_law_db:+.1f} dB (K={pan_law_coef:.4f} per channel on mono→stereo)"
            if pan_law_was_default:
                note += " [default; set output.pan_law to declare]"
            note += ". (Cmd 16)"
            fmt["rationale"] = fmt["rationale"] + " " + note

        # Per-stem pan map (Cmd 20). Manifest pan: > auto-pan (if enabled) >
        # default 0.0 for every mono stem. Stereo stems are absent from the
        # map by design.
        pan_map, pan_source = resolve_pan_map(manifest, group_stems, use_auto_pan)

        # Build the filter graph WITHOUT pre-attenuation, measure, then build the real one
        scout_graph = build_filter_graph(group_stems, fmt["rate"], fmt["channels"],
                                         per_stem_gains, pre_atten_db=0.0,
                                         pan_law_db=pan_law_db, pan_map=pan_map)
        measured_peak, measured_lufs = measure_mix_peak(directory, group_stems, scout_graph)
        pre_atten, pre_atten_rationale = compute_pre_attenuation(measured_peak)

        # Build the final filter graph with pre-attenuation
        final_graph = build_filter_graph(group_stems, fmt["rate"], fmt["channels"],
                                         per_stem_gains, pre_atten_db=pre_atten,
                                         pan_law_db=pan_law_db, pan_map=pan_map)

        # Output filename
        suffix = ".degenerate" if fmt["lie"] else ""
        ext = {"flac": ".flac", "wav": ".wav", "aiff": ".aiff", "mp3": ".mp3"}[fmt["format"]]
        output_filename = f"{project}_{group_name}{suffix}{ext}"
        output_path = str(output_dir / output_filename)

        stem_shas = {fn: stems_by_filename[fn].get("sha256", "") for fn in filenames}

        plan_groups.append({
            "name": group_name,
            "stem_files": filenames,
            "stem_shas": stem_shas,
            "format": fmt,
            "filter_graph": final_graph,
            "scout_filter_graph": scout_graph,
            "measured_peak_dbtp": measured_peak,
            "measured_lufs": measured_lufs,
            "pre_attenuation_db": pre_atten,
            "pre_attenuation_rationale": pre_atten_rationale,
            "per_stem_gains": {fn: per_stem_gains.get(fn, 0.0) for fn in filenames},
            "pan_law_db": pan_law_db,
            "pan_law_coefficient": pan_law_coef,
            "pan_law_was_default": pan_law_was_default,
            "pan_map": {fn: pan_map[fn] for fn in filenames if fn in pan_map},
            "pan_source": pan_source,
            "has_mono_stems": has_mono,
            "output_path": output_path,
            # v1.3: per-group normalization config. None when --archival
            # (the v1.2 unity-sum behavior); a dict when the group should
            # be loudness-conditioned. mix.py reads this and runs the
            # two-pass loudnorm + alimiter pipeline against the unity-sum
            # intermediate when present.
            "normalization": normalization_template,
            "archival": archival,
        })

    # Reference bundle (Cmd 19). Plans the three-synced-versions deliverable
    # when analysis.master_reference is present and Pass 2 was clean. Pass 4
    # writes <output-dir>/reference-bundle/{master, instrumental, acapella}.<ext>
    # all at the matched format. Mix.py copies/re-encodes the master into the
    # bundle dir; the canonical mixdowns alongside become the bundle's other two.
    master_ref = analysis.get("master_reference")
    reference_bundle: dict[str, Any] | None = None
    if master_ref is not None:
        # Pick the bundle's format from the canonical groups: prefer the
        # "instrumental" group's format when both are present (it's the most
        # common stem set); fall back to the first group otherwise. The bundle's
        # rate / depth / format must match what Pass 2 enforced parity against.
        bundle_format = None
        for g in plan_groups:
            if g["name"] in ("instrumental", "acapella"):
                bundle_format = g["format"]
                break
        if bundle_format is None and plan_groups:
            bundle_format = plan_groups[0]["format"]
        if bundle_format is not None:
            bundle_dir = output_dir / "reference-bundle"
            ext = {"flac": ".flac", "wav": ".wav", "aiff": ".aiff", "mp3": ".mp3"}[bundle_format["format"]]
            # Bundle members: master + each canonical group's mixdown.
            members = [{
                "role": "master",
                "source": master_ref["path"],
                "source_sha256": master_ref["sha256"],
                "source_codec": master_ref["codec"],
                "source_container": master_ref["container"],
                "output_path": str(bundle_dir / f"{project}_master{ext}"),
                "needs_reencode": (
                    master_ref["codec"] != bundle_format["codec"]
                    or master_ref["bit_depth"] != bundle_format["depth"]
                    or master_ref["sample_rate"] != bundle_format["rate"]
                    or (master_ref.get("container") or "") != bundle_format["container"]
                ),
            }]
            for g in plan_groups:
                if g["name"] not in ("instrumental", "acapella"):
                    continue
                members.append({
                    "role": g["name"],
                    "source": g["output_path"],  # the canonical mixdown
                    "source_sha256": None,       # filled in at mix time
                    "output_path": str(bundle_dir / f"{project}_{g['name']}{ext}"),
                    "needs_reencode": False,     # canonical already matches bundle format
                })
            reference_bundle = {
                "directory": str(bundle_dir),
                "format": bundle_format,
                "master_reference": master_ref,
                "members": members,
                "rationale": (
                    f"Three perfectly synchronized versions: master + instrumental + "
                    f"acapella, all at {bundle_format['format']} {bundle_format['rate']} Hz / "
                    f"{bundle_format['depth']}-bit / {bundle_format['channels']}ch. "
                    f"The master is the witness, not the source (Cmd 19). Verify will "
                    f"null-test (instrumental + acapella) against the master and report "
                    f"the residual."
                ),
            }

    # v1.3: when normalization is on AND a master is present, plan a sibling
    # <project>_master_listening.<ext> alongside the canonicals. The bundle
    # itself stays unity-sum (Cmd 19 — null tests need un-normalized inputs);
    # this is the listener-friendly version of the master.
    master_listening: dict[str, Any] | None = None
    if normalization_template is not None and master_ref is not None:
        # Pick the bundle's format if present, otherwise the first group's.
        ml_format = None
        if reference_bundle is not None:
            ml_format = reference_bundle["format"]
        elif plan_groups:
            ml_format = plan_groups[0]["format"]
        if ml_format is not None:
            ml_ext = {"flac": ".flac", "wav": ".wav", "aiff": ".aiff", "mp3": ".mp3"}[ml_format["format"]]
            master_listening = {
                "source": master_ref["path"],
                "source_sha256": master_ref["sha256"],
                "output_path": str(output_dir / f"{project}_master_listening{ml_ext}"),
                "format": ml_format,
                "normalization": dict(normalization_template),
                "rationale": (
                    "Normalized listening copy of the master at "
                    f"{normalization_template['target_lufs']} LUFS-I / "
                    f"{normalization_template['target_true_peak']} dBTP. "
                    "Sits alongside the canonical mixdowns for A/B listening. "
                    "The original master file is unmodified; the unity-sum "
                    "version inside reference-bundle/ is what null tests run "
                    "against. (Cmd 9 revised, Cmd 19)"
                ),
            }

    plan = {
        "schema_version": "4",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "directory": str(directory),
        "output_directory": str(output_dir),
        "project": project,
        "manifest": manifest,
        "groups": plan_groups,
        "any_lie": any_lie,
        "reference_bundle": reference_bundle,
        "master_listening": master_listening,
    }

    sys.stderr.write(render_plan_markdown(plan))
    sys.stderr.write("\n")
    sys.stdout.write(json.dumps(plan, indent=2, default=str))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

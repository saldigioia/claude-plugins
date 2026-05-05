#!/usr/bin/env python3
"""
verify.py — Pass 5 (Verify).

Re-probes every mixdown produced by Pass 4, confirms the output format matches
plan.json, confirms no clipping, and (optionally) runs a null test against a
user-supplied reference bounce.

The null test phase-inverts the reference, sums it with the skill's output,
and measures the residual true peak. Below -90 dBFS = passes within dither
noise; -60 to -90 = subtly different (dither method, sample-level offset);
above -60 = structurally different.

Exit codes:
    0  = all outputs verified, null test (if requested) passed
    1  = verification failures
    2  = structural error
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _measure  # noqa: E402
from _version import __version__  # noqa: E402


def ffprobe_json(path: Path) -> dict:
    r = subprocess.run(
        ["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)],
        capture_output=True, text=True, check=True,
    )
    return json.loads(r.stdout)


def measure_true_peak(path: Path) -> float | None:
    return _measure.measure_loudness_file(path)["true_peak_dbtp"]


# ---------------------------------------------------------------------------
# Mono-fold compatibility (Cmd 6 — phase is real)
# ---------------------------------------------------------------------------

# Reference loudness targets per docs/research/2C-reference-loudness.md.
# Re-pin LAST_VERIFIED on platform-policy change, not on a calendar.
LOUDNESS_TARGETS_LAST_VERIFIED = "2026-05-05"
DEFAULT_LOUDNESS_PLATFORMS = ("Spotify", "Apple Music", "EBU R128")
LOUDNESS_TARGETS = {
    # name: (integrated_lufs_target, max_true_peak_dbtp, behavior_note)
    "Spotify":     (-14.0, -1.0, "boost+attenuate"),
    "Apple Music": (-16.0, -1.0, "boost+attenuate; AES TD1008"),
    "YouTube":     (-14.0, -1.0, "attenuate-only"),
    "Tidal":       (-14.0, -1.0, "attenuate-only; album-level"),
    "SoundCloud":  (-14.0, -1.0, "attenuate-only"),
    "Amazon Music":(-14.0, -2.0, "attenuate-only; -2 dBTP ceiling"),
    "EBU R128":    (-23.0, -1.0, "broadcast spec (EBU Tech 3343)"),
    "ATSC A/85":   (-24.0, -2.0, "US broadcast (CALM Act)"),
}


def loudness_deltas(integrated_lufs: float | None, true_peak_dbtp: float | None,
                    platforms: tuple[str, ...]) -> list[dict]:
    """Per-platform delta lines: how this output compares to each target.

    Returns a list of {platform, target_lufs, target_dbtp, lufs_delta,
    headroom_delta, note}. Negative lufs_delta = quieter than target;
    positive = hotter. Positive headroom_delta = comfortable; negative =
    over the ceiling. Skips platforms whose target isn't in LOUDNESS_TARGETS.
    """
    out: list[dict] = []
    for name in platforms:
        target = LOUDNESS_TARGETS.get(name)
        if target is None:
            continue
        target_lufs, target_dbtp, note = target
        row = {
            "platform": name,
            "target_lufs_i": target_lufs,
            "target_true_peak_dbtp": target_dbtp,
            "note": note,
            "lufs_delta": (round(integrated_lufs - target_lufs, 2)
                           if integrated_lufs is not None else None),
            "headroom_delta_db": (round(target_dbtp - true_peak_dbtp, 2)
                                  if true_peak_dbtp is not None else None),
        }
        out.append(row)
    return out


def _classify_mono_fold(delta_lu: float) -> str:
    """Threshold ladder per docs/research/2B."""
    if delta_lu <= 3.0:
        return "mono_compatible"
    if delta_lu <= 6.0:
        return "mono_partial_cancellation"
    if delta_lu <= 12.0:
        return "mono_phase_warning"
    return "mono_phase_severe"


def measure_mono_fold_delta(path: Path) -> dict:
    """Stereo vs mono-fold integrated-LUFS delta.

    delta_lu = stereo_lufs_i - mono_fold_lufs_i. A perfectly mono-correlated
    stereo source (e.g. a single mono stem center-panned) drops by 3 LU under
    mono fold (the K-weighted energy floor). Anything beyond 3 LU is real
    decorrelation; beyond 6 LU is partial cancellation; beyond 12 LU is a
    likely polarity inversion somewhere.
    """
    stereo = _measure.measure_loudness_file(path)
    cmd = ["ffmpeg", "-nostdin", "-hide_banner", "-i", str(path),
           "-af", "pan=mono|c0=0.5*c0+0.5*c1,ebur128=peak=true",
           "-f", "null", "-"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    mono = _measure.parse_ebur128_summary(r.stderr)
    if stereo["integrated_lufs"] is None or mono["integrated_lufs"] is None:
        return {"verdict": "measurement_failed",
                "stereo_lufs_i": stereo["integrated_lufs"],
                "mono_fold_lufs_i": mono["integrated_lufs"]}
    delta = stereo["integrated_lufs"] - mono["integrated_lufs"]
    return {
        "stereo_lufs_i": stereo["integrated_lufs"],
        "mono_fold_lufs_i": mono["integrated_lufs"],
        "delta_lu": round(delta, 2),
        "verdict": _classify_mono_fold(delta),
    }


def _verdict_from_residual(residual: float | None) -> str:
    if residual is None:
        return "measurement_failed"
    if residual <= -90.0:
        return "pass"
    if residual <= -60.0:
        return "smell"  # subtle difference, worth a look
    return "fail"


def null_test(skill_output: Path, reference: Path) -> dict:
    """
    Sum skill_output + (-1 * reference), measure residual true peak.
    Returns {residual_dbtp, verdict}.
    """
    cmd = [
        "ffmpeg", "-nostdin", "-hide_banner",
        "-i", str(skill_output),
        "-i", str(reference),
        "-filter_complex",
        "[1:a]volume=-1.0[ref];[0:a][ref]amix=inputs=2:duration=longest:normalize=0:weights=1 1[null];"
        "[null]ebur128=peak=true[out]",
        "-map", "[out]",
        "-f", "null", "-",
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    residual = _measure.parse_ebur128_summary(r.stderr)["true_peak_dbtp"]
    return {"residual_dbtp": residual, "verdict": _verdict_from_residual(residual)}


def reference_battery(plan: dict, master_path: Path) -> dict:
    """The Cmd 19 reference battery against a user-supplied master.

    Three nulls + per-deliverable LUFS-I/dBTP deltas:
    1. recombine: (instrumental + acapella) - master  → should null
    2. inverse_acapella: (master - acapella) - instrumental  → should null
    3. inverse_instrumental: (master - instrumental) - acapella  → should null

    All three should land at roughly the same residual dBTP. If recombine passes
    but inverse_* don't, the bundle members aren't from the same session as the
    master. If all three fail by the same amount, the master is from a
    different mix or a different version.
    """
    out: dict[str, Any] = {"master_path": str(master_path)}
    if not master_path.is_file():
        out["error"] = f"master file not found: {master_path}"
        return out

    # Find the canonical instrumental + acapella outputs from the plan.
    ipath: Path | None = None
    apath: Path | None = None
    for g in plan.get("groups", []):
        if g.get("name") == "instrumental":
            ipath = Path(g["output_path"])
        elif g.get("name") == "acapella":
            apath = Path(g["output_path"])
    if ipath is None or apath is None:
        out["error"] = ("plan must have both 'instrumental' and 'acapella' groups "
                        "for the reference battery")
        return out
    if not ipath.is_file() or not apath.is_file():
        out["error"] = f"missing canonical mixdowns: instrumental={ipath.is_file()}, acapella={apath.is_file()}"
        return out

    # 1. Recombine null: (instrumental + acapella) - master
    cmd = [
        "ffmpeg", "-nostdin", "-hide_banner",
        "-i", str(ipath), "-i", str(apath), "-i", str(master_path),
        "-filter_complex",
        "[0:a][1:a]amix=inputs=2:duration=longest:normalize=0:weights=1 1[sum];"
        "[2:a]volume=-1.0[masterneg];"
        "[sum][masterneg]amix=inputs=2:duration=longest:normalize=0:weights=1 1[null];"
        "[null]ebur128=peak=true[ebr]",
        "-map", "[ebr]", "-f", "null", "-",
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    recombine_residual = _measure.parse_ebur128_summary(r.stderr)["true_peak_dbtp"]
    out["recombine"] = {
        "residual_dbtp": recombine_residual,
        "verdict": _verdict_from_residual(recombine_residual),
        "operation": "(instrumental + acapella) - master",
    }

    # 2. Inverse-acapella null: (master - acapella) - instrumental
    cmd = [
        "ffmpeg", "-nostdin", "-hide_banner",
        "-i", str(master_path), "-i", str(apath), "-i", str(ipath),
        "-filter_complex",
        "[1:a]volume=-1.0[acaneg];"
        "[0:a][acaneg]amix=inputs=2:duration=longest:normalize=0:weights=1 1[mminusa];"
        "[2:a]volume=-1.0[ineg];"
        "[mminusa][ineg]amix=inputs=2:duration=longest:normalize=0:weights=1 1[null];"
        "[null]ebur128=peak=true[ebr]",
        "-map", "[ebr]", "-f", "null", "-",
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    inv_aca_residual = _measure.parse_ebur128_summary(r.stderr)["true_peak_dbtp"]
    out["inverse_acapella"] = {
        "residual_dbtp": inv_aca_residual,
        "verdict": _verdict_from_residual(inv_aca_residual),
        "operation": "(master - acapella) - instrumental",
    }

    # 3. Inverse-instrumental null: (master - instrumental) - acapella
    cmd = [
        "ffmpeg", "-nostdin", "-hide_banner",
        "-i", str(master_path), "-i", str(ipath), "-i", str(apath),
        "-filter_complex",
        "[1:a]volume=-1.0[ineg];"
        "[0:a][ineg]amix=inputs=2:duration=longest:normalize=0:weights=1 1[mminusi];"
        "[2:a]volume=-1.0[acaneg];"
        "[mminusi][acaneg]amix=inputs=2:duration=longest:normalize=0:weights=1 1[null];"
        "[null]ebur128=peak=true[ebr]",
        "-map", "[ebr]", "-f", "null", "-",
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    inv_inst_residual = _measure.parse_ebur128_summary(r.stderr)["true_peak_dbtp"]
    out["inverse_instrumental"] = {
        "residual_dbtp": inv_inst_residual,
        "verdict": _verdict_from_residual(inv_inst_residual),
        "operation": "(master - instrumental) - acapella",
    }

    # Per-deliverable LUFS-I + dBTP deltas vs master. Informational, not normalized.
    master_summary = _measure.measure_loudness_file(master_path)
    inst_summary = _measure.measure_loudness_file(ipath)
    aca_summary = _measure.measure_loudness_file(apath)
    out["master_loudness"] = {
        "integrated_lufs": master_summary.get("integrated_lufs"),
        "true_peak_dbtp": master_summary.get("true_peak_dbtp"),
        "loudness_range": master_summary.get("loudness_range"),
    }

    def _delta(deliverable_summary: dict, label: str) -> dict:
        m_lufs = master_summary.get("integrated_lufs")
        d_lufs = deliverable_summary.get("integrated_lufs")
        m_tp = master_summary.get("true_peak_dbtp")
        d_tp = deliverable_summary.get("true_peak_dbtp")
        return {
            "label": label,
            "integrated_lufs": d_lufs,
            "true_peak_dbtp": d_tp,
            "lufs_delta_vs_master": (round(d_lufs - m_lufs, 2)
                                      if d_lufs is not None and m_lufs is not None else None),
            "true_peak_delta_vs_master": (round(d_tp - m_tp, 2)
                                           if d_tp is not None and m_tp is not None else None),
        }

    out["deliverable_deltas"] = [
        _delta(inst_summary, "instrumental"),
        _delta(aca_summary, "acapella"),
    ]

    # Overall verdict: use the recombine null as the headline. The two inverse
    # nulls are diagnostic — they help interpret why recombine fails when it
    # does. A passing recombine is the interesting positive result.
    out["headline_verdict"] = out["recombine"]["verdict"]
    return out


def verify_group(group: dict, reference: Path | None,
                 check_mono_fold: bool = False,
                 platforms: tuple[str, ...] = DEFAULT_LOUDNESS_PLATFORMS) -> dict:
    output_path = Path(group["output_path"])
    issues: list[str] = []

    if not output_path.exists():
        return {"group": group["name"], "status": "missing", "issues": ["output file does not exist"]}

    fmt = group["format"]
    try:
        probe = ffprobe_json(output_path)
        stream = next((s for s in probe.get("streams", []) if s.get("codec_type") == "audio"), {})
    except Exception as e:
        return {"group": group["name"], "status": "probe_error", "issues": [str(e)]}

    actual_rate = int(stream.get("sample_rate", 0))
    actual_channels = int(stream.get("channels", 0))
    actual_codec = stream.get("codec_name", "")
    bprs_raw = stream.get("bits_per_raw_sample")
    bps_raw = stream.get("bits_per_sample")

    def _to_int_or_none(v):
        try:
            n = int(v)
            return n if n > 0 else None
        except (TypeError, ValueError):
            return None

    actual_depth = _to_int_or_none(bprs_raw) or _to_int_or_none(bps_raw)

    if actual_rate != fmt["rate"]:
        issues.append(f"rate mismatch: planned {fmt['rate']}, got {actual_rate}")
    if actual_channels != fmt["channels"]:
        issues.append(f"channel mismatch: planned {fmt['channels']}, got {actual_channels}")
    # Codec check is loose — mp3 might report differently, flac is canonical
    if fmt["format"] == "flac" and actual_codec != "flac":
        issues.append(f"codec mismatch: planned flac, got {actual_codec}")
    # Honest depth check. Lossy formats (target_depth == 0) are exempt; PCM and
    # FLAC must report their stored bit depth, not just the container size.
    if fmt["format"] in ("flac", "wav", "aiff") and fmt.get("depth"):
        planned_depth = int(fmt["depth"])
        if actual_depth is None:
            issues.append(
                f"depth unknown: planned {planned_depth}-bit, ffprobe reports "
                f"bits_per_raw_sample={bprs_raw!r}, bits_per_sample={bps_raw!r}"
            )
        elif actual_depth != planned_depth:
            issues.append(
                f"depth mismatch: planned {planned_depth}-bit, container reports "
                f"{actual_depth}-bit (Cmd 1 — the source is the ceiling)"
            )

    # True peak
    tp = measure_true_peak(output_path)
    if tp is not None and tp > 0.0:
        issues.append(f"output is clipping: true peak {tp:.2f} dBTP")

    result = {
        "group": group["name"],
        "output": str(output_path),
        "format_check": "ok" if not issues else "fail",
        "actual_rate": actual_rate,
        "actual_channels": actual_channels,
        "actual_codec": actual_codec,
        "actual_depth": actual_depth,
        "true_peak_dbtp": tp,
        "issues": issues,
    }

    # Mono-fold compatibility (info-only by default; --check-mono-fold
    # promotes mono_phase_warning / mono_phase_severe to issues so the
    # verify run fails. See docs/research/2B-mono-fold-policy.md.).
    mf = measure_mono_fold_delta(output_path)
    result["mono_fold"] = mf
    if check_mono_fold and mf.get("verdict") in ("mono_phase_warning", "mono_phase_severe"):
        issues.append(
            f"mono-fold {mf['verdict']}: stereo→mono drops "
            f"{mf['delta_lu']} LU (threshold > 6 LU). Likely polarity / "
            f"phase issue in the source stems."
        )

    # Per-platform loudness deltas (information-only; no normalization).
    # Cmd 9 stands. The measured stereo LUFS-I from mono-fold piggybacks here
    # so we don't run ebur128 twice. See docs/research/2C-reference-loudness.md.
    result["loudness_deltas"] = loudness_deltas(
        mf.get("stereo_lufs_i"), tp, platforms
    )
    result["loudness_targets_last_verified"] = LOUDNESS_TARGETS_LAST_VERIFIED

    # Optional null test
    if reference is not None:
        result["null_test"] = null_test(output_path, reference)

    result["issues"] = issues
    result["format_check"] = "ok" if not issues else "fail"
    result["status"] = "ok" if not issues and (
        reference is None or result.get("null_test", {}).get("verdict") in ("pass", "smell")
    ) else "fail"
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="stems-to-mixdown / Pass 5 (verify)")
    parser.add_argument("--plan", required=True, type=Path, help="Path to plan.json from Pass 3")
    parser.add_argument("--reference", type=Path, default=None,
                        help="Optional reference bounce for null test")
    parser.add_argument("--reference-group", type=str, default=None,
                        help="Group name to compare reference against (default: first group)")
    parser.add_argument("--check-mono-fold", action="store_true",
                        help=("Promote mono_phase_warning / mono_phase_severe verdicts to "
                              "issues. By default the mono-fold delta is reported "
                              "informationally (Cmd 6 honored without scope-creeping)."))
    parser.add_argument("--report-all-platforms", action="store_true",
                        help=("Surface every loudness target in LOUDNESS_TARGETS instead "
                              "of just the default three (Spotify, Apple Music, EBU R128)."))
    parser.add_argument("--master", type=Path, default=None,
                        help=("Path to the master reference (Cmd 19). Overrides the "
                              "master inferred from plan.reference_bundle. When set, "
                              "the reference battery runs: recombine null + two "
                              "inverse-stems nulls + per-deliverable LUFS-I/dBTP "
                              "deltas vs the master."))
    args = parser.parse_args()

    platforms = tuple(LOUDNESS_TARGETS.keys()) if args.report_all_platforms \
        else DEFAULT_LOUDNESS_PLATFORMS

    if not args.plan.is_file():
        sys.stderr.write(f"[fatal] plan file not found: {args.plan}\n")
        return 2
    with args.plan.open("r") as f:
        plan = json.load(f)

    sys.stderr.write(f"\n=== stems-to-mixdown v{__version__} / verify ===\n")

    results = []
    any_fail = False
    target_group = args.reference_group or (plan["groups"][0]["name"] if plan["groups"] else None)
    for group in plan["groups"]:
        ref = args.reference if (args.reference and group["name"] == target_group) else None
        result = verify_group(group, ref, check_mono_fold=args.check_mono_fold,
                              platforms=platforms)
        results.append(result)
        sys.stderr.write(f"[{result['status']}] {result['group']}: {result['output']}\n")
        for issue in result.get("issues", []):
            sys.stderr.write(f"    - {issue}\n")
        mf = result.get("mono_fold") or {}
        if mf.get("verdict") and mf.get("delta_lu") is not None:
            sys.stderr.write(f"    mono fold: {mf['verdict']} "
                             f"(stereo→mono Δ {mf['delta_lu']:+.2f} LU)\n")
        deltas = result.get("loudness_deltas") or []
        if deltas:
            sys.stderr.write(f"    loudness vs platform targets "
                             f"(verified {result.get('loudness_targets_last_verified')}; "
                             f"informational, no normalization):\n")
            for row in deltas:
                lufs_str = (f"Δ {row['lufs_delta']:+.2f} LU"
                            if row['lufs_delta'] is not None else "Δ ?")
                hr_str = (f"{row['headroom_delta_db']:+.2f} dB headroom"
                          if row['headroom_delta_db'] is not None else "headroom ?")
                sys.stderr.write(
                    f"      {row['platform']:<14} target {row['target_lufs_i']:.1f} LUFS / "
                    f"{row['target_true_peak_dbtp']:.1f} dBTP — {lufs_str}, {hr_str}\n"
                )
        if "null_test" in result:
            nt = result["null_test"]
            sys.stderr.write(f"    null test: {nt['verdict']} "
                             f"(residual {nt['residual_dbtp']:.2f} dBTP)\n"
                             if nt.get("residual_dbtp") is not None
                             else f"    null test: {nt['verdict']}\n")
        if result["status"] != "ok":
            any_fail = True

    # Reference battery (Cmd 19). Runs when either --master was passed or the
    # plan recorded a reference bundle. The headline verdict is the recombine
    # null residual; the two inverse-stems nulls are diagnostic.
    master_path: Path | None = args.master
    if master_path is None:
        rb = plan.get("reference_bundle")
        if rb is not None:
            mref = rb.get("master_reference") or {}
            mp = mref.get("path")
            if mp:
                master_path = Path(mp)
    battery = None
    if master_path is not None:
        sys.stderr.write(f"\n--- Reference battery (Cmd 19) ---\n")
        sys.stderr.write(f"Master: {master_path}\n")
        battery = reference_battery(plan, master_path)
        if "error" in battery:
            sys.stderr.write(f"  [error] {battery['error']}\n")
            any_fail = True
        else:
            for key in ("recombine", "inverse_acapella", "inverse_instrumental"):
                node = battery[key]
                r = node.get("residual_dbtp")
                rstr = f"{r:+.2f} dBTP" if r is not None else "n/a"
                sys.stderr.write(
                    f"  {key:<22} {node['verdict']:<6} residual {rstr}  "
                    f"({node['operation']})\n"
                )
            ml = battery["master_loudness"]
            sys.stderr.write(
                f"  master loudness: I={ml.get('integrated_lufs')} LUFS, "
                f"TP={ml.get('true_peak_dbtp')} dBTP, LRA={ml.get('loudness_range')} LU\n"
            )
            for d in battery["deliverable_deltas"]:
                lufs_d = d.get("lufs_delta_vs_master")
                tp_d = d.get("true_peak_delta_vs_master")
                lufs_str = f"Δ {lufs_d:+.2f} LU" if lufs_d is not None else "Δ ?"
                tp_str = f"Δ {tp_d:+.2f} dBTP" if tp_d is not None else "Δ ?"
                sys.stderr.write(
                    f"  {d['label']:<14} I={d.get('integrated_lufs')} LUFS, "
                    f"TP={d.get('true_peak_dbtp')} dBTP — {lufs_str}, {tp_str}\n"
                )
            sys.stderr.write(f"  headline: {battery['headline_verdict']}\n")
            if battery["headline_verdict"] == "fail":
                any_fail = True

    out_payload = {"results": results}
    if battery is not None:
        out_payload["reference_battery"] = battery
    sys.stdout.write(json.dumps(out_payload, indent=2, default=str))
    sys.stdout.write("\n")
    return 1 if any_fail else 0


if __name__ == "__main__":
    sys.exit(main())

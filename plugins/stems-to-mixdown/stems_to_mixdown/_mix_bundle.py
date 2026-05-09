"""Reference-bundle and master-listening deliverables (Cmd 19, Cmd 9 revised).

execute_reference_bundle writes the three-synced-versions bundle
(master + instrumental + acapella) at unity sum so null-test
verification works. The master file is sacrosanct — only the bundle
copy is re-encoded, and only when the format genuinely differs.

execute_master_listening produces a normalized A/B copy of the master
sitting alongside the canonical mixdowns. Distinct from the bundle
because the bundle promises identical loudness across its three members
and a normalized listening copy violates that contract by design.
"""
from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from stems_to_mixdown._mix_helpers import (
    build_codec_args,
    build_dither_chain,
    measure_output,
    shell_escape,
)
from stems_to_mixdown._mix_normalize import (
    build_normalized_command,
    measure_loudnorm_first_pass,
)
from stems_to_mixdown._version import __version__


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
        encode_chain = build_dither_chain(target_format, target_depth)
        if encode_chain:
            filter_graph = (group_def["filter_graph"]
                            + ";[mix]" + ",".join(encode_chain) + "[final]")
            map_label = "[final]"
        else:
            filter_graph = group_def["filter_graph"]
            map_label = "[mix]"
        cmd += ["-filter_complex", filter_graph, "-map", map_label]
        cmd += build_codec_args(rb["format"])
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
            f"[master_listening] running: {' '.join(shell_escape(c) for c in cmd2)}\n"
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

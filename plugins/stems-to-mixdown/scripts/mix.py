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

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _measure  # noqa: E402
from _version import __version__  # noqa: E402

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
    """Stable SHA-256 over the live input contents and the filter graph.

    Returns (key, live_shas). Inputs are re-hashed from disk every run so a
    file replaced under the same name with different content invalidates the
    cache; the plan's `stem_shas` block records the analyze-time hashes for
    drift-detection comparison.
    """
    live_shas: dict[str, str] = {}
    parts: list[str] = []
    for fn in group["stem_files"]:
        sha = hash_file(directory / fn)
        live_shas[fn] = sha
        parts.append(f"{fn}:{sha}")
    parts.append("--filter--")
    parts.append(group["filter_graph"])
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

        # role in {instrumental, acapella}: copy the canonical mixdown.
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
        f"Run: `python3 scripts/verify.py --plan <plan.json>`",
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
                       live_shas: dict[str, str] | None = None) -> str:
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

    sys.stdout.write(json.dumps({"results": results}, indent=2, default=str))
    sys.stdout.write("\n")
    return 1 if any_error else 0


if __name__ == "__main__":
    sys.exit(main())

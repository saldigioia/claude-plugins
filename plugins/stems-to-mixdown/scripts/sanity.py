"""Pass 2 — Sanity check.

Inspects the StemInfo list produced by Pass 1 and emits RedFlag entries for
every condition that should make the operator pause. Owns the RedFlag shape.
analyze.py imports `RedFlag` and `sanity_check` from here.

Severity:
- "error" — analyze.py exits 1 unless --force is passed.
- "warn"  — printed and recorded; analyze.py still exits 0.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _manifest  # noqa: E402
from discover import StemInfo, MasterReferenceInfo  # noqa: E402

WAV_EXTS = {".wav", ".wave", ".rf64"}


def _master_reference_checks(stems: list[StemInfo],
                              master_info: MasterReferenceInfo | None,
                              master_missing_path: str | None,
                              manifest: dict[str, Any]) -> list[RedFlag]:
    """Pass 2 enforcement of Cmd 19 (the master is the witness, not the source).

    The master must match what Pass 3 will choose as the target. We can predict
    that target with confidence: target_rate = max(stem rates) (or 44100 when
    any lossy is in the chain), target_depth = min(stem depths) (or 16 when
    lossy), target_channels = 2. Mismatch is an error — Cmd 19 forbids the
    skill from resampling, requantizing, or trimming the master to fit.
    """
    flags: list[RedFlag] = []
    if master_missing_path is not None:
        flags.append(RedFlag(
            "error", "master_missing",
            f"source.master_reference.path resolves to {master_missing_path} which "
            f"is missing or unreadable. Either fix the path, omit the field, or pass "
            f"--master <path> to override. Cmd 19. "
            f"→ The reference-bundle deliverable depends on the master being present.",
            affected=[master_missing_path],
        ))
        return flags
    if master_info is None:
        return flags

    # Predict target as plan.py will (cheap; we duplicate the matrix here so
    # the operator gets the refusal at Pass 2 instead of Pass 3 surprise).
    any_lossy = any(s.is_lossy for s in stems)
    rates = sorted({s.sample_rate for s in stems if s.sample_rate})
    depths = sorted({s.bit_depth for s in stems if s.bit_depth and not s.is_lossy})
    if any_lossy:
        target_rate = 44100
        target_depth = 16
    else:
        target_rate = max(rates) if rates else 44100
        target_depth = min(depths) if depths else 16
    # FLAC clamps 32-bit-source target to 24 (the stable encoder ceiling) —
    # the format-decisions doc covers this; the master must match the clamped value.
    if target_depth > 24:
        target_depth = 24
    target_channels = 2

    if master_info.sample_rate != target_rate:
        flags.append(RedFlag(
            "error", "master_rate_mismatch",
            f"Master is {master_info.sample_rate} Hz; target is {target_rate} Hz. "
            f"Cmd 19 forbids resampling the master. Re-render the master at "
            f"{target_rate} Hz, or omit source.master_reference. "
            f"→ Refusal stands until the master matches.",
            affected=[master_info.path],
        ))
    if not master_info.is_lossy and master_info.bit_depth != target_depth:
        flags.append(RedFlag(
            "error", "master_depth_mismatch",
            f"Master is {master_info.bit_depth}-bit; target is {target_depth}-bit. "
            f"Cmd 19 forbids requantizing the master. Re-render the master at "
            f"{target_depth}-bit, or omit source.master_reference. "
            f"→ Refusal stands until the master matches.",
            affected=[master_info.path],
        ))
    if master_info.channels != target_channels:
        flags.append(RedFlag(
            "error", "master_channels_mismatch",
            f"Master is {master_info.channels}-channel; target is {target_channels}-channel "
            f"(stereo). Cmd 19 forbids upmixing or downmixing the master. "
            f"→ Re-render the master as stereo, or omit source.master_reference.",
            affected=[master_info.path],
        ))
    if master_info.channels > 2:
        # Already covered by the mismatch above, but make the structural refusal explicit.
        flags.append(RedFlag(
            "error", "master_multichannel",
            f"Master has {master_info.channels} channels — multichannel is out of scope "
            f"for the bundle. Provide a stereo master.",
            affected=[master_info.path],
        ))

    # Duration parity. Compare against the longest stem at the target rate; the
    # plan duration matches the longest stem because amix=duration=longest.
    if stems:
        longest_samples = max(s.duration_samples for s in stems if s.duration_samples)
        # Convert to target-rate sample count if rates differ (the master is
        # supposed to be at target rate, so this only matters when stems aren't).
        if rates and target_rate != max(rates) and rates:
            # mostly defensive; lossy-cap path can take target away from max(rates)
            longest_samples = int(round(longest_samples * target_rate / max(rates)))
        delta = abs(master_info.duration_samples - longest_samples)
        tol = master_info.duration_tolerance_samples
        if delta > tol:
            delta_ms = delta / max(target_rate, 1) * 1000.0
            flags.append(RedFlag(
                "error", "master_duration_mismatch",
                f"Master duration {master_info.duration_samples} samples differs from "
                f"longest stem {longest_samples} samples by {delta} samples "
                f"({delta_ms:.1f} ms at {target_rate} Hz); tolerance is {tol} sample(s). "
                f"Cmd 19 forbids trimming or padding the master to fit. Either re-export "
                f"the master at the same length as the stems, raise "
                f"source.master_reference.duration_tolerance_samples deliberately, or "
                f"omit the master. → Synchronization is the whole point of the bundle.",
                affected=[master_info.path],
            ))

    # Lossy master with lossless stems: warn (the bundle still proceeds because
    # the recombine null residual will simply be limited by the lossy floor).
    if master_info.is_lossy and not any_lossy:
        flags.append(RedFlag(
            "warn", "master_lossy_with_lossless_stems",
            f"Master is lossy ({master_info.codec}) but stems are lossless. Bundle "
            f"will proceed; recombine null residual will be limited by the lossy "
            f"compression's noise floor (typically -60 to -80 dBTP rather than "
            f"-90 dBTP). → A null verdict of 'smell' is expected, not 'pass'.",
            affected=[master_info.path],
        ))
    return flags


@dataclass
class RedFlag:
    severity: str  # "warn" | "error"
    code: str
    message: str
    affected: list[str] = field(default_factory=list)


def sanity_check(stems: list[StemInfo],
                 manifest: dict[str, Any] | None = None,
                 master_info: MasterReferenceInfo | None = None,
                 master_missing_path: str | None = None) -> list[RedFlag]:
    flags: list[RedFlag] = []
    if not stems:
        flags.append(RedFlag("error", "no_stems", "No audio files found in directory."))
        return flags

    # Manifest schema warnings (typos, out-of-range pan_law, etc.) get
    # surfaced as a single Pass-2 warn so the operator sees them next to
    # the other red flags rather than buried in stderr.
    for msg in _manifest.validate_manifest(manifest or {}):
        flags.append(RedFlag("warn", "manifest_schema", msg, affected=[]))

    # Pan-law assumption disclosure: mono stems exist and the manifest hasn't
    # declared output.pan_law. The skill defaults to -3.0 dB; surface it so the
    # operator knows what coefficient is about to be applied. Pro Tools defaults
    # to -2.5 dB; Logic / Cubase to -3.0 dB. Pick deliberately.
    has_mono = any(s.channels == 1 for s in stems)
    manifest_output = (manifest or {}).get("output") or {}
    if has_mono and manifest_output.get("pan_law") is None:
        flags.append(RedFlag(
            "warn", "pan_law_default_assumed",
            "Mono stems present and manifest output.pan_law is unset. "
            "Defaulting to -3.0 dB pan law (Logic / Cubase convention; "
            "Pro Tools default is -2.5 dB; legacy 0 dB is +3 dB hotter than "
            "any DAW-equivalent center sum). Set output.pan_law in the "
            "manifest to declare it explicitly. See references/format-decisions.md.",
            affected=[s.filename for s in stems if s.channels == 1],
        ))

    rates = {s.sample_rate for s in stems if s.sample_rate}
    if len(rates) > 1:
        flags.append(RedFlag(
            "error", "rate_mismatch",
            f"Stems disagree on sample rate: {sorted(rates)}. "
            "This is almost always a production bug. The skill will resample to "
            "the highest common rate via soxr precision 28 if --force is passed. "
            "→ One or more stems will be resampled; resampling is a lossy operation (Cmd 4).",
            affected=[s.filename for s in stems],
        ))

    depths = {s.bit_depth for s in stems if s.bit_depth and not s.is_lossy}
    if len(depths) > 1:
        flags.append(RedFlag(
            "warn", "depth_mismatch",
            f"Stems disagree on bit depth: {sorted(depths)}. "
            "Output will use smallest common depth.",
            affected=[s.filename for s in stems if not s.is_lossy],
        ))

    # Channel mismatch is fine (handled by upmix), but multichannel is out of scope
    multichannel = [s.filename for s in stems if s.channels > 2]
    if multichannel:
        flags.append(RedFlag(
            "error", "multichannel_input",
            "Multichannel inputs (>2 channels) — out of scope (this skill sums stereo). "
            "Downmix first with a tool that's honest about the coefficients. "
            "→ No override; this refusal is structural.",
            affected=multichannel,
        ))

    # Stems-unanchored: bext.time_reference variance > 1 sample across stems
    # is a strong signal that the stems came from per-clip exports with
    # different timeline anchors instead of a session consolidation. amix at
    # zero offset will sum at the wrong positions and the song will be wrong.
    # Only fires when wavinfo populated production_metadata.bwf.time_reference
    # on at least two stems; without wavinfo there's no signal to act on.
    # See docs/research/2E-alignment-heuristics.md.
    time_refs: dict[str, int] = {}
    for s in stems:
        bwf = (s.production_metadata or {}).get("bwf") or {}
        tr = bwf.get("time_reference")
        if tr is None:
            continue
        try:
            time_refs[s.filename] = int(tr)
        except (TypeError, ValueError):
            continue
    if len(set(time_refs.values())) > 1:
        delta_samples = max(time_refs.values()) - min(time_refs.values())
        if delta_samples > 1:
            # Convert to ms using the most common rate (or first non-zero rate
            # if there's no clear majority). Operator-grade.
            rate = next((s.sample_rate for s in stems
                         if s.sample_rate and s.filename in time_refs), 48000)
            delta_ms = delta_samples / rate * 1000.0
            flags.append(RedFlag(
                "warn", "stems_unanchored",
                f"Stems disagree on bext.time_reference by up to {delta_samples} "
                f"samples ({delta_ms:.1f} ms at {rate} Hz). This usually means "
                f"the stems were exported from different positions on a session "
                f"timeline rather than as anchor-aligned bounces. amix at zero "
                f"offset will sum the song wrong. Consolidate stems in the source "
                f"DAW (Pro Tools: Edit → Consolidate; Logic: File → Bounce → "
                f"Stems; Cubase: Audio → Render in Place) so each stem starts at "
                f"sample 0, then re-run analyze. See Cmd 10 (\"stems must align\"). "
                f"→ Stems probably need to be consolidated before this skill can "
                f"mix them.",
                affected=sorted(time_refs.keys()),
            ))

    # Length drift
    if stems:
        max_dur = max(s.duration_samples for s in stems if s.duration_samples)
        for s in stems:
            if s.duration_samples and abs(s.duration_samples - max_dur) > 1:
                drift_ms = (max_dur - s.duration_samples) / max(s.sample_rate, 1) * 1000.0
                flags.append(RedFlag(
                    "warn", "length_drift",
                    f"{s.filename} is {drift_ms:.1f} ms shorter than the longest stem. "
                    "Will mix with duration=longest; tail will be silence.",
                    affected=[s.filename],
                ))

    # Bit-depth uncertainty: WAV file in s32 container with no wavinfo to disambiguate.
    # The value in stem.bit_depth is the container size (32) but the honest depth
    # could be 24. Surfaced as a warning so the operator knows to install wavinfo
    # if they care about the format-decision matrix being right.
    for s in stems:
        if (
            s.bit_depth_source == "ffprobe_sample_fmt"
            and s.sample_fmt in ("s32", "s32p")
            and Path(s.path).suffix.lower() in WAV_EXTS
            and not s.is_lossy
        ):
            flags.append(RedFlag(
                "warn", "bit_depth_uncertain",
                f"{s.filename} is in a 32-bit container; without wavinfo the skill "
                f"cannot tell whether the captured depth is 24 or 32. "
                f"Install wavinfo (`pip install wavinfo`) to read wValidBitsPerSample. "
                f"See references/pro-audio-metadata.md. "
                f"→ Output may claim 32-bit when 24-bit is the truth; install wavinfo "
                f"for an honest answer.",
                affected=[s.filename],
            ))

    # Probe disagreement: ffprobe says X, MediaInfo says Y, on a field that
    # changes the format-decision matrix output. Only fires for rate, depth,
    # channels — duration and container-string differences are info-only.
    for s in stems:
        mi = (s.production_metadata or {}).get("mediainfo")
        if not mi:
            continue
        disagreements: list[str] = []
        if mi.get("sample_rate") and mi["sample_rate"] != s.sample_rate:
            disagreements.append(
                f"sample_rate: ffprobe={s.sample_rate}, mediainfo={mi['sample_rate']}"
            )
        # For bit depth, prefer to compare against MediaInfo's BitDepth_Detected
        # (the valid bits) when present — that's what we want to agree with.
        mi_depth = mi.get("bit_depth_detected") or mi.get("bit_depth")
        if mi_depth and not s.is_lossy and mi_depth != s.bit_depth:
            disagreements.append(
                f"bit_depth: chosen={s.bit_depth} (via {s.bit_depth_source}), "
                f"mediainfo={mi_depth}"
            )
        if mi.get("channels") and mi["channels"] != s.channels:
            disagreements.append(
                f"channels: ffprobe={s.channels}, mediainfo={mi['channels']}"
            )
        if disagreements:
            flags.append(RedFlag(
                "warn", "probe_disagreement",
                f"{s.filename} — probes disagree on matrix-affecting fields: "
                + "; ".join(disagreements)
                + ". The chosen authority drives the format decision; MediaInfo's "
                "view is recorded under production_metadata.mediainfo for review.",
                affected=[s.filename],
            ))

    # Per-file pathologies
    for s in stems:
        if s.true_peak_dbtp is not None and s.true_peak_dbtp > 0.0:
            flags.append(RedFlag(
                "warn", "input_clipping",
                f"{s.filename} true peak is {s.true_peak_dbtp:.2f} dBTP — already clipped at source.",
                affected=[s.filename],
            ))
        if s.dc_offset_max is not None and s.dc_offset_max > 0.001:
            flags.append(RedFlag(
                "warn", "dc_offset",
                f"{s.filename} has DC offset of {s.dc_offset_max:.4f} — analog stage problem upstream. "
                f"→ Silent budget eaten and asymmetric clipping likely; investigate the recording chain.",
                affected=[s.filename],
            ))
        if s.fully_silent:
            flags.append(RedFlag(
                "warn", "silent_file",
                f"{s.filename} is entirely silent.",
                affected=[s.filename],
            ))
        elif s.channels == 2 and len(s.silent_channels) == 1:
            ch = "L" if s.silent_channels[0] == 0 else "R"
            flags.append(RedFlag(
                "warn", "dead_channel",
                f"{s.filename} is stereo but {ch} channel is silent — likely a routing mistake. "
                f"→ A stereo file is functionally mono; this is almost always a routing mistake "
                f"upstream of the bounce.",
                affected=[s.filename],
            ))

    # Lossy presence is informational, not a flag — Pass 3 handles format decision
    lossy = [s.filename for s in stems if s.is_lossy]
    if lossy:
        flags.append(RedFlag(
            "warn", "lossy_input",
            f"Lossy inputs present ({len(lossy)} file(s)). "
            "Default output will be 16-bit / 44.1 kHz FLAC. "
            "→ Output is capped at 16/44.1 because the source can't honestly carry more (Cmd 1 + 8).",
            affected=lossy,
        ))

    # Master-reference parity (Cmd 19). Runs only when the operator opted in
    # via source.master_reference.path or --master.
    flags.extend(_master_reference_checks(stems, master_info, master_missing_path,
                                          manifest or {}))

    return flags

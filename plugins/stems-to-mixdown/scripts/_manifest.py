"""Manifest loading and schema constants for the stems-to-mixdown skill.

The manifest is `stems.manifest.yaml` in the input directory and overrides
automatic behavior. See `references/manifest-schema.md` for the documented
schema; this module is the loader the pipeline calls and the source of truth
for which keys are recognized.

Public API:
- MANIFEST_FILENAME — the filename the loader looks for ("stems.manifest.yaml").
- load_manifest(directory) -> dict — soft-fails to {} when PyYAML is absent
  or the file is missing / not a mapping; emits a one-line stderr warning in
  the cases that warrant it. Never raises.
- validate_manifest(manifest) -> list[str] — returns a list of human-readable
  warnings about manifest content; does not raise. Empty list = clean.
- ALLOWED_OUTPUT_KEYS, ALLOWED_PAN_LAWS — schema constants the validator and
  consumer code reference.

The loader is deliberately minimal — manifest content is consumed by
plan.py's group derivation and decide_output_format, which already perform
their own checks (file-existence, type coercion). This module's job is to
get a dict to those consumers, with a soft pre-flight pass for obvious typos.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

try:
    import yaml  # PyYAML
except ImportError:
    yaml = None  # type: ignore[assignment]  # manifest support degrades gracefully

MANIFEST_FILENAME = "stems.manifest.yaml"

ALLOWED_OUTPUT_KEYS = {
    "format", "rate", "depth", "channels", "compression_level", "pan_law",
    # v1.3: Phase 2 stereo-policy fields. `auto_pan` opts into the
    # auto-distribution rule for groups of N classified-the-same mono stems.
    "auto_pan",
    # v1.3: Phase 3 normalization fields.
    "target_lufs", "target_true_peak", "archival",
}
ALLOWED_PAN_LAWS = (0.0, -2.5, -3.0, -4.5, -6.0)
ALLOWED_FORMATS = {"flac", "wav", "aiff", "mp3"}
# v1.3: only -14, -16, -23 land on a documented streaming/broadcast spec.
# Anything outside this set is almost certainly a mistake; the validator
# warns and the planner clamps. See docs/research/2C-reference-loudness.md.
ALLOWED_LUFS_TARGETS = (-14.0, -16.0, -23.0)
# v1.3: -1.0 is the modern-streaming standard, -1.5 a slightly more
# conservative ceiling for AAC/Ogg transcoding, -2.0 for ATSC A/85.
ALLOWED_TRUE_PEAK_TARGETS = (-1.0, -1.5, -2.0)

# Recognized keys inside the manifest's `source:` block. `master_reference` is
# the master-witness opt-in (Cmd 19); the rest are provenance from sibling
# skills (e.g. stems-from-mix's hand-off manifest) and are informational only.
ALLOWED_SOURCE_KEYS = {
    "master_reference", "tool", "model", "source_mix",
}
# Recognized keys inside source.master_reference itself.
ALLOWED_MASTER_REFERENCE_KEYS = {
    "path", "duration_tolerance_samples",
}
# Default tolerance when source.master_reference.duration_tolerance_samples
# is unset. One sample is the same tolerance Pass 2 uses for stem length-drift.
DEFAULT_MASTER_DURATION_TOLERANCE_SAMPLES = 1

ALLOWED_TOP_LEVEL_KEYS = {
    "project", "classifications", "gains", "groups", "output", "metadata",
    # Provenance from upstream sibling skills + the master-witness block.
    # The hand-off contract from stems-from-mix populates source.tool /
    # source.model / source.source_mix; the master_reference block (Cmd 19)
    # opts the run into the reference-bundle deliverable.
    "source",
    # v1.3: per-stem pan placement (Cmd 20). Maps filename → -100..+100
    # pan position. Mono stems only; stereo entries warn and pass through.
    "pan",
    # schema_version is informational; some scaffolds emit it.
    "schema_version",
}


def load_manifest(directory: Path) -> dict[str, Any]:
    """Load <directory>/stems.manifest.yaml. Returns {} on any soft failure.

    Soft failures (warned to stderr, returns {}):
    - File does not exist.
    - PyYAML not installed.
    - File is empty or YAML root is not a mapping.

    Hard failures (PyYAML parse errors, IO errors) propagate as exceptions —
    those represent a corrupted manifest the user needs to see, not silently
    swallow.
    """
    manifest_path = directory / MANIFEST_FILENAME
    if not manifest_path.exists():
        return {}
    if yaml is None:
        sys.stderr.write(f"[warn] PyYAML not installed; ignoring {MANIFEST_FILENAME}\n")
        return {}
    with manifest_path.open("r") as f:
        data = yaml.safe_load(f) or {}
    if not isinstance(data, dict):
        sys.stderr.write(f"[warn] {MANIFEST_FILENAME} is not a mapping; ignoring\n")
        return {}
    return data


def validate_manifest(manifest: dict[str, Any]) -> list[str]:
    """Return a list of human-readable warnings; empty list = clean.

    Catches typos and out-of-range values that the consumers wouldn't
    otherwise flag prominently. Does not raise; the caller decides whether to
    surface the warnings as red flags or fail the run.
    """
    warnings: list[str] = []
    if not manifest:
        return warnings

    unknown_top = set(manifest) - ALLOWED_TOP_LEVEL_KEYS
    if unknown_top:
        warnings.append(
            f"manifest top-level key(s) {sorted(unknown_top)} not recognized; "
            f"allowed: {sorted(ALLOWED_TOP_LEVEL_KEYS)}"
        )

    output = manifest.get("output") or {}
    if isinstance(output, dict):
        unknown_out = set(output) - ALLOWED_OUTPUT_KEYS
        if unknown_out:
            warnings.append(
                f"manifest output key(s) {sorted(unknown_out)} not recognized; "
                f"allowed: {sorted(ALLOWED_OUTPUT_KEYS)}"
            )
        if "pan_law" in output and output["pan_law"] is not None:
            try:
                pl = float(output["pan_law"])
                if pl not in ALLOWED_PAN_LAWS:
                    warnings.append(
                        f"manifest output.pan_law={pl} not in {list(ALLOWED_PAN_LAWS)}"
                    )
            except (TypeError, ValueError):
                warnings.append(
                    f"manifest output.pan_law={output['pan_law']!r} is not a number"
                )
        if "format" in output and output["format"] is not None:
            fmt = str(output["format"]).lower()
            if fmt not in ALLOWED_FORMATS:
                warnings.append(
                    f"manifest output.format={fmt!r} not in {sorted(ALLOWED_FORMATS)}"
                )
        if "compression_level" in output and output["compression_level"] is not None:
            try:
                cl = int(output["compression_level"])
                if not 0 <= cl <= 12:
                    warnings.append(
                        f"manifest output.compression_level={cl} out of FLAC range 0..12; "
                        f"will be clamped"
                    )
            except (TypeError, ValueError):
                warnings.append(
                    f"manifest output.compression_level={output['compression_level']!r} "
                    f"is not an integer"
                )
        if "auto_pan" in output and output["auto_pan"] is not None:
            if not isinstance(output["auto_pan"], bool):
                warnings.append(
                    f"manifest output.auto_pan={output['auto_pan']!r} is not a boolean; "
                    f"treating as false"
                )
        if "target_lufs" in output and output["target_lufs"] is not None:
            try:
                tl = float(output["target_lufs"])
                if tl not in ALLOWED_LUFS_TARGETS:
                    warnings.append(
                        f"manifest output.target_lufs={tl} not in {list(ALLOWED_LUFS_TARGETS)}; "
                        f"will be clamped to nearest"
                    )
            except (TypeError, ValueError):
                warnings.append(
                    f"manifest output.target_lufs={output['target_lufs']!r} is not a number"
                )
        if "target_true_peak" in output and output["target_true_peak"] is not None:
            try:
                ttp = float(output["target_true_peak"])
                if ttp not in ALLOWED_TRUE_PEAK_TARGETS:
                    warnings.append(
                        f"manifest output.target_true_peak={ttp} not in "
                        f"{list(ALLOWED_TRUE_PEAK_TARGETS)}; will be clamped"
                    )
                if ttp > 0:
                    warnings.append(
                        f"manifest output.target_true_peak={ttp} dBTP is above 0; "
                        f"this is a clipping invitation"
                    )
            except (TypeError, ValueError):
                warnings.append(
                    f"manifest output.target_true_peak={output['target_true_peak']!r} "
                    f"is not a number"
                )
        if "archival" in output and output["archival"] is not None:
            if not isinstance(output["archival"], bool):
                warnings.append(
                    f"manifest output.archival={output['archival']!r} is not a boolean; "
                    f"treating as false"
                )

    pan = manifest.get("pan")
    if pan is not None:
        if not isinstance(pan, dict):
            warnings.append(
                f"manifest pan must be a mapping (filename -> -100..+100); "
                f"got {type(pan).__name__}"
            )
        else:
            for fn, val in pan.items():
                try:
                    pv = float(val)
                    if not -100.0 <= pv <= 100.0:
                        warnings.append(
                            f"manifest pan[{fn!r}]={pv} out of -100..+100"
                        )
                except (TypeError, ValueError):
                    warnings.append(
                        f"manifest pan[{fn!r}]={val!r} is not a number"
                    )

    source = manifest.get("source") or {}
    if isinstance(source, dict):
        unknown_src = set(source) - ALLOWED_SOURCE_KEYS
        if unknown_src:
            warnings.append(
                f"manifest source key(s) {sorted(unknown_src)} not recognized; "
                f"allowed: {sorted(ALLOWED_SOURCE_KEYS)}"
            )
        master_ref = source.get("master_reference")
        if master_ref is not None:
            if not isinstance(master_ref, dict):
                warnings.append(
                    f"manifest source.master_reference must be a mapping with at least "
                    f"a `path:` key; got {type(master_ref).__name__}"
                )
            else:
                unknown_mr = set(master_ref) - ALLOWED_MASTER_REFERENCE_KEYS
                if unknown_mr:
                    warnings.append(
                        f"manifest source.master_reference key(s) {sorted(unknown_mr)} "
                        f"not recognized; allowed: {sorted(ALLOWED_MASTER_REFERENCE_KEYS)}"
                    )
                if "path" not in master_ref or not master_ref["path"]:
                    warnings.append(
                        "manifest source.master_reference is set but `path:` is missing "
                        "or empty; the block will be ignored"
                    )
                if "duration_tolerance_samples" in master_ref:
                    try:
                        tol = int(master_ref["duration_tolerance_samples"])
                        if tol < 0:
                            warnings.append(
                                f"manifest source.master_reference.duration_tolerance_samples"
                                f"={tol} is negative; will use default "
                                f"{DEFAULT_MASTER_DURATION_TOLERANCE_SAMPLES}"
                            )
                    except (TypeError, ValueError):
                        warnings.append(
                            f"manifest source.master_reference.duration_tolerance_samples="
                            f"{master_ref['duration_tolerance_samples']!r} is not an integer"
                        )

    return warnings


def resolve_master_reference_path(manifest: dict[str, Any], manifest_dir: Path,
                                   cli_override: Path | None = None) -> Path | None:
    """Returns the resolved absolute path to the master reference, or None.

    Precedence: CLI override > manifest source.master_reference.path > None.
    Relative paths resolve against `manifest_dir` (the directory containing the
    manifest, which is also where stems live). Returns None if neither source
    set the field. Does NOT check that the file exists; that's the caller's job
    so the missing-file error can be a real Pass 2 red flag.
    """
    if cli_override is not None:
        return cli_override.expanduser().resolve()
    source = manifest.get("source") or {}
    master_ref = (source.get("master_reference") or {}) if isinstance(source, dict) else {}
    raw = master_ref.get("path") if isinstance(master_ref, dict) else None
    if not raw:
        return None
    p = Path(raw).expanduser()
    if not p.is_absolute():
        p = (manifest_dir / p).resolve()
    return p


def resolve_master_duration_tolerance(manifest: dict[str, Any]) -> int:
    """Returns the per-run sample-tolerance for master vs longest-stem duration."""
    source = manifest.get("source") or {}
    master_ref = (source.get("master_reference") or {}) if isinstance(source, dict) else {}
    if isinstance(master_ref, dict) and "duration_tolerance_samples" in master_ref:
        try:
            tol = int(master_ref["duration_tolerance_samples"])
            if tol >= 0:
                return tol
        except (TypeError, ValueError):
            pass
    return DEFAULT_MASTER_DURATION_TOLERANCE_SAMPLES

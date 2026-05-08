"""Pan-coefficient and pan-distribution helpers (Cmd 16, Cmd 20).

Constant-power curve renormalized to the declared pan law for mono→stereo
upmix; auto-distribution rule (vocals + bass center, others spread to
max width 0.7); manifest pan-map resolution with manifest > auto > default
priority.
"""
from __future__ import annotations

import math


ALLOWED_PAN_LAWS = (0.0, -2.5, -3.0, -4.5, -6.0)
DEFAULT_PAN_LAW_DB = -3.0


def pan_coefficients(pan_position: float, pan_law_db: float) -> tuple[float, float]:
    """Return (L_coef, R_coef) for placing a mono signal at pan_position
    in [-1.0, +1.0] under the declared pan law.

    Constant-power curve (cos/sin) renormalized so the center coefficient
    matches `10 ** (pan_law_db / 20)`. Centered placement returns
    (center_coef, center_coef); fully-left returns (~1.0, 0); fully-right
    returns (0, ~1.0). Values outside [-1, +1] clamp.

    Note: 0 dB pan law produces super-unity coefficients at full-side
    placement (math is inherent to the choice). The schema validator and
    the planner already restrict pan_law_db to ALLOWED_PAN_LAWS; -3.0
    (the default) gives ~unity at full-side without clipping.
    """
    p = max(-1.0, min(1.0, pan_position))
    theta = (p + 1.0) * math.pi / 4.0
    raw_L = math.cos(theta)
    raw_R = math.sin(theta)
    center_coef = 10 ** (pan_law_db / 20.0)
    scale = center_coef * math.sqrt(2.0)
    return raw_L * scale, raw_R * scale


def auto_pan_positions(n: int) -> list[float]:
    """Distribute n mono stems across the stereo field in [-1, +1].

    Vocals and bass conventions live in `auto_pan_for_group()` — this is
    the raw geometry. Symmetric, max-width capped at 0.7 to stay off the
    hard sides (where mono compatibility starts to suffer); n=2 stays
    conservative at ±0.5 (a "halfway" pair, the SOS / Mastering The Mix
    convention for paired-stem placement).
    """
    if n <= 0:
        return []
    if n == 1:
        return [0.0]
    if n == 2:
        return [-0.5, 0.5]
    max_width = 0.7
    return [(2 * i / (n - 1) - 1) * max_width for i in range(n)]


def auto_pan_for_group(group_stems: list[dict]) -> dict[str, float]:
    """Apply the auto-pan distribution rule (Cmd 20) to a group.

    Conventions taken straight from the SOS / Mastering The Mix research
    surfaced in docs/IMPROVEMENT-PLAN-v1.3.md (Phase 2):
      - Vocals and bass stay center.
      - Other mono stems spread evenly across the field with max width 0.7.
      - Stereo stems are not re-panned (the plugin doesn't decorate stereo).

    Returns {filename: pan_position in [-1, +1]}.
    """
    spreadable = [s for s in group_stems
                  if s["channels"] == 1
                  and s["classification"] not in ("vocal", "bass")]
    positions = auto_pan_positions(len(spreadable))
    out: dict[str, float] = {}
    for s, pos in zip(spreadable, positions):
        out[s["filename"]] = pos
    for s in group_stems:
        if s["channels"] == 1 and s["classification"] in ("vocal", "bass"):
            out[s["filename"]] = 0.0
    return out


def resolve_pan_map(manifest: dict, group_stems: list[dict],
                    use_auto_pan: bool) -> tuple[dict[str, float], str]:
    """Pan-resolution priority: manifest pan: > auto-pan (if enabled) > defaults.

    Returns ({filename: pan_position in [-1, +1]}, source_label).
    Default for any mono stem not covered by either source: 0.0 (center).
    Stereo stems are absent from the returned map — they're never panned.
    """
    raw_manifest_pan = manifest.get("pan") or {}
    out: dict[str, float] = {}

    # Apply manifest pan first (highest priority); convert -100..+100 to -1..+1.
    for fn, val in raw_manifest_pan.items():
        try:
            v = float(val) / 100.0
        except (TypeError, ValueError):
            continue
        out[fn] = max(-1.0, min(1.0, v))

    # Auto-pan fills in stems the manifest didn't cover, when enabled.
    if use_auto_pan:
        auto = auto_pan_for_group(group_stems)
        for fn, pos in auto.items():
            if fn not in out:
                out[fn] = pos

    # Default centered for any mono stem still uncovered.
    for s in group_stems:
        if s["channels"] == 1 and s["filename"] not in out:
            out[s["filename"]] = 0.0

    if raw_manifest_pan and use_auto_pan:
        source = "manifest+auto"
    elif raw_manifest_pan:
        source = "manifest"
    elif use_auto_pan:
        source = "auto"
    else:
        source = "default"
    return out, source


def resolve_pan_law(manifest_output: dict | None) -> tuple[float, bool]:
    """Returns (pan_law_db, was_default).

    `manifest_output.pan_law` may be a number or None. Anything outside the
    allowed set is rejected — pan law is a deliberate choice, not a slider.
    """
    manifest_output = manifest_output or {}
    raw = manifest_output.get("pan_law")
    if raw is None:
        return DEFAULT_PAN_LAW_DB, True
    pan_law = float(raw)
    if pan_law not in ALLOWED_PAN_LAWS:
        raise SystemExit(
            f"[fatal] manifest output.pan_law={pan_law} not in {list(ALLOWED_PAN_LAWS)}. "
            f"Pick one of the conventional values; the rest are religious. (Cmd 16)"
        )
    return pan_law, False

"""Format-decision matrix for the plan pass.

Single function: decide_output_format. Reads a group's stems and any
manifest output overrides, returns the resolved {format, codec,
container, rate, depth, channels, dither_required, lie, rationale,
compression_level} dict that mix.py executes against. Cmd 1, Cmd 4,
Cmd 8 are the doctrinal anchors here.
"""
from __future__ import annotations


def decide_output_format(group_stems: list[dict], manifest_output: dict | None) -> dict:
    """
    Apply the format-decision matrix to a group of stems.
    Returns {format, codec, container, rate, depth, channels, dither_required, lie}.
    """
    manifest_output = manifest_output or {}

    any_lossy = any(s["is_lossy"] for s in group_stems)
    rates = sorted({s["sample_rate"] for s in group_stems if s["sample_rate"]})
    depths = sorted({s["bit_depth"] for s in group_stems
                     if s["bit_depth"] and not s["is_lossy"]}) or [16]
    channels_set = sorted({s["channels"] for s in group_stems if s["channels"]})

    # Channel target: stereo (we upmix mono, refuse multichannel — already filtered)
    target_channels = 2

    # Default decisions
    if any_lossy:
        target_rate = 44100
        target_depth = 16
        format_name = "flac"
        rationale = "Lossy in chain → output capped at 16/44.1 FLAC. (Cmd 1, Cmd 8)"
    else:
        target_rate = max(rates) if rates else 44100
        target_depth = min(depths) if depths else 16
        format_name = "flac"
        if len(rates) > 1:
            rationale = (f"Mixed rates {sorted(rates)} → {target_rate} Hz "
                         f"(highest common; upsampling is non-destructive, downsampling discards). "
                         f"Depth: {target_depth}-bit (smallest common). (Cmd 1, Cmd 4)")
        elif len(depths) > 1:
            rationale = (f"Mixed depths {sorted(depths)} → {target_depth}-bit "
                         f"(smallest common). Rate: {target_rate} Hz (native). (Cmd 1)")
        else:
            rationale = f"Uniform lossless: {target_rate} Hz / {target_depth}-bit FLAC. (Cmd 1)"

    # FLAC's stable encoder caps at 24-bit. ffmpeg refuses to write deeper
    # without `-strict experimental`, and 32-bit FLAC is non-portable across
    # decoders. When the source-derived target_depth is 32-bit (which happens
    # on 32-bit-float intermediates and 32-bit PCM inputs), clamp to 24 for
    # FLAC output — the additional bits are below any real-signal noise floor.
    # Source-is-the-ceiling (Cmd 1) is preserved: 24-bit FLAC of 32-bit input
    # is mathematically lossless for any signal worth preserving.
    if format_name == "flac" and target_depth > 24:
        rationale += (
            f" FLAC clamps to 24-bit (stable encoder ceiling); "
            f"the dropped precision is below any real-signal noise floor. "
            f"For genuine {target_depth}-bit out, set output.format to wav or aiff. (Cmd 1)"
        )
        target_depth = 24

    # Manifest overrides
    lie = False
    if manifest_output.get("rate"):
        forced_rate = int(manifest_output["rate"])
        if forced_rate > target_rate:
            lie = True
            rationale += (f" [DEGENERATE] Manifest forced rate {forced_rate} Hz "
                          f"exceeds source ceiling. (Cmd 1; --lie / `.degenerate` suffix)")
        target_rate = forced_rate
    if manifest_output.get("depth"):
        forced_depth = int(manifest_output["depth"])
        if any_lossy or (depths and forced_depth > min(depths)):
            lie = True
            rationale += (f" [DEGENERATE] Manifest forced depth {forced_depth}-bit "
                          f"exceeds source honesty. (Cmd 1; --lie / `.degenerate` suffix)")
        target_depth = forced_depth
    if manifest_output.get("format"):
        format_name = manifest_output["format"].lower()

    # FLAC compression level — manifest override or sane default (8 = max-compression
    # without enabling exhaustive search).
    compression_level = manifest_output.get("compression_level")
    if compression_level is None:
        compression_level = 8
    else:
        try:
            compression_level = int(compression_level)
        except (TypeError, ValueError):
            compression_level = 8
        compression_level = max(0, min(12, compression_level))

    # Codec / container mapping
    codec_map = {
        "flac": ("flac", "flac"),
        "wav": ("pcm_s24le" if target_depth == 24 else "pcm_s16le", "wav"),
        "aiff": ("pcm_s24be" if target_depth == 24 else "pcm_s16be", "aiff"),
        "mp3": ("libmp3lame", "mp3"),
    }
    if format_name not in codec_map:
        raise SystemExit(
            f"[fatal] unknown output format: {format_name!r}. "
            f"Allowed: flac, wav, aiff, mp3."
        )
    codec, container = codec_map[format_name]

    # Dither required if going to 16-bit from a higher-precision intermediate (we always intermediate at flt)
    dither_required = (format_name in ("flac", "wav", "aiff", "mp3") and target_depth <= 16)

    return {
        "format": format_name,
        "codec": codec,
        "container": container,
        "rate": target_rate,
        "depth": target_depth if format_name != "mp3" else 0,
        "channels": target_channels,
        "dither_required": dither_required,
        "lie": lie,
        "rationale": rationale,
        "compression_level": compression_level,
    }

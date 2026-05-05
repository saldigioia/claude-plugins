#!/usr/bin/env python3
"""
scaffold_manifest.py — emit a starter stems.manifest.yaml from analysis.json.

Pre-fills `classifications:` from each stem's regex / manifest classification
so the user doesn't have to type filenames a second time. The remaining
sections (`groups`, `gains`, `output`, `metadata`) are written as
**commented-out scaffolds with examples**, so the user just uncomments and
edits to enable them. A commented-out block is a no-op as far as
`analyze.py` is concerned, so the scaffolded manifest is immediately
consumable end-to-end.

Refuses to overwrite an existing manifest unless `--overwrite` is passed —
manifests are operator decisions and the script shouldn't clobber them.

Usage:
    python3 scripts/scaffold_manifest.py \\
        --analysis analysis.json \\
        --out tests/fixtures/some-stems/stems.manifest.yaml

    # Or write next to the source dir's stems
    python3 scripts/scaffold_manifest.py \\
        --analysis analysis.json \\
        --out tests/fixtures/some-stems/

Exit codes:
    0  = scaffold written (or stdout)
    1  = analysis missing / refusing to overwrite without --overwrite
    2  = structural error
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


HEADER = """\
# stems.manifest.yaml — scaffolded by scripts/scaffold_manifest.py.
#
# Uncomment + edit the sections you want to override. Anything left
# commented out is a no-op; analyze.py will read this file cleanly even
# if every section but `classifications` is commented.
#
# Schema reference: references/manifest-schema.md
"""

CLASSIFICATIONS_HEADER = """\

# Per-file classification override. Each filename below maps to one of:
# vocal, drums, bass, guitar, keys, fx, other. The values pre-filled here
# came from the regex / manifest classifier on the analysis run that
# produced this scaffold. Override if any file is mis-classified.
classifications:
"""

GROUPS_BLOCK = """\

# Custom group definitions. Maps group name → list of EXACT filenames
# (relative to this manifest's directory). Custom groups are produced
# IN ADDITION TO the automatic acapella / instrumental, unless a custom
# group name overrides one of those defaults.
# groups:
#   drums_only:
#     - kick.wav
#     - snare.wav
#     - hat.wav
#   rhythm_section:
#     - kick.wav
#     - bass.wav
"""

GAINS_BLOCK = """\

# Per-file gain trim, in dB, applied before the sum. Use sparingly —
# most balance decisions belong upstream of this skill. Useful only when
# one stem was bounced hot by mistake and you don't want to re-bounce.
# gains:
#   vox_lead.wav: -1.5
#   kick_room.wav: -3.0
"""

OUTPUT_BLOCK = """\

# Output format overrides. Default behavior comes from
# references/format-decisions.md (source-is-the-ceiling). Anything you
# uncomment here forces a specific choice and may produce a `.degenerate`
# output if it exceeds source honesty.
# output:
#   format: flac           # flac | wav | aiff | mp3
#   rate: null             # null = auto; integer = force (e.g. 48000)
#   depth: null            # null = auto; integer = force (e.g. 24)
#   compression_level: 8   # FLAC level 0..12; default 8
#   pan_law: -3.0          # 0.0 | -2.5 | -3.0 | -4.5 | -6.0; default -3.0
"""

METADATA_BLOCK = """\

# Embedded tags. Anything specified here overrides values inherited from
# input metadata. The skill never invents IDs, dates, or barcodes — only
# honest engineering metadata.
# metadata:
#   artist: Artist Name
#   album: Album Name
#   date: 2026
#   genre: Hip-Hop
#   comment: Mixed from session-XYZ stems on 2026-MM-DD
"""


def render_scaffold(analysis: dict[str, Any]) -> str:
    """Build the manifest text from analysis.json."""
    lines = [HEADER.rstrip(), CLASSIFICATIONS_HEADER.rstrip()]
    stems = analysis.get("stems") or []
    if not stems:
        lines.append("  # (no stems found in analysis.json)")
    for s in stems:
        fn = s.get("filename") or "?"
        cls = s.get("classification") or "other"
        # Quote keys with spaces or special chars; YAML accepts simple ones unquoted.
        key = fn if all(c.isalnum() or c in "._-" for c in fn) else f"\"{fn}\""
        lines.append(f"  {key}: {cls}")
    lines.append(GROUPS_BLOCK.rstrip())
    lines.append(GAINS_BLOCK.rstrip())
    lines.append(OUTPUT_BLOCK.rstrip())
    lines.append(METADATA_BLOCK.rstrip())
    lines.append("")  # trailing newline
    return "\n".join(lines)


def resolve_out_path(out_arg: Path) -> Path:
    """If --out is a directory, append stems.manifest.yaml; else use as-is."""
    if out_arg.is_dir():
        return out_arg / "stems.manifest.yaml"
    return out_arg


def main() -> int:
    parser = argparse.ArgumentParser(description="Emit a starter stems.manifest.yaml")
    parser.add_argument("--analysis", required=True, type=Path,
                        help="Path to analysis.json from Pass 1+2")
    parser.add_argument("--out", required=True, type=Path,
                        help=("Output path. Pass a directory to write "
                              "<dir>/stems.manifest.yaml; pass a file path to "
                              "write that exact filename. Use - to write to stdout."))
    parser.add_argument("--overwrite", action="store_true",
                        help="Replace an existing manifest. Default: refuse.")
    args = parser.parse_args()

    if not args.analysis.is_file():
        sys.stderr.write(f"[fatal] analysis file not found: {args.analysis}\n")
        return 2
    with args.analysis.open("r") as f:
        analysis = json.load(f)

    text = render_scaffold(analysis)

    if str(args.out) == "-":
        sys.stdout.write(text)
        return 0

    out_path = resolve_out_path(args.out)
    if out_path.exists() and not args.overwrite:
        sys.stderr.write(
            f"[refuse] {out_path} already exists. Pass --overwrite to replace it. "
            f"Manifests are operator decisions; this script will not clobber them.\n"
        )
        return 1

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(text)
    sys.stderr.write(f"[ok] wrote {out_path}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""
handoff.py — write a stems.manifest.yaml for stems-to-mixdown to consume.

Called by separate.py after demucs finishes; can also be invoked directly if
the operator already has separated stems and just wants the manifest.

The manifest schema is the contract with stems-to-mixdown
(see ../stems-to-mixdown/references/manifest-schema.md). This script writes
the subset relevant to a separation hand-off:

    source:
      type: separation
      tool: demucs
      model: htdemucs_ft
      device: cpu | mps | cuda
      demucs_version: <captured at runtime if importable>
      source_mix:
        path: <absolute path to original mix>
        sha256: <hash of the mix>
    classifications:
      vocal.wav: vocal
      drum.wav: drums
      bass.wav: bass
      other.wav: other

Everything else in the schema (groups, gains, output, metadata) is left
out — the downstream skill's defaults are correct for separation outputs,
and the operator can edit the manifest by hand to add overrides.

Exit codes:
    0 = manifest written
    1 = stems-dir missing the expected files
    2 = structural error
"""

from __future__ import annotations

import argparse
import hashlib
import sys
from datetime import datetime, timezone
from pathlib import Path

EXPECTED_STEM_FILES = ("vocal.wav", "drum.wav", "bass.wav", "other.wav")
CLASSIFICATIONS = {
    "vocal.wav": "vocal",
    "drum.wav": "drums",
    "bass.wav": "bass",
    "other.wav": "other",
}


def hash_file(path: Path, chunk: int = 1 << 20) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(chunk), b""):
            h.update(block)
    return h.hexdigest()


def render_manifest(stems_dir: Path, source_mix: Path, device: str,
                    demucs_version: str | None) -> str:
    source_sha = hash_file(source_mix) if source_mix.is_file() else ""
    lines: list[str] = []
    lines.append("# stems.manifest.yaml — written by stems-from-mix/scripts/handoff.py.")
    lines.append("#")
    lines.append("# These stems came out of demucs htdemucs_ft. The classifications")
    lines.append("# below are explicit (manifest > regex > default in stems-to-mixdown),")
    lines.append("# so the downstream regex never has to fire. Bleed is real (Cmd S1);")
    lines.append("# the original mix is truth (Cmd S2); these are not deliverables (Cmd S3).")
    lines.append("")
    lines.append("source:")
    lines.append("  type: separation")
    lines.append("  tool: demucs")
    lines.append("  model: htdemucs_ft")
    lines.append(f"  device: {device}")
    if demucs_version:
        lines.append(f"  demucs_version: \"{demucs_version}\"")
    lines.append(f"  generated_at: \"{datetime.now(timezone.utc).isoformat()}\"")
    lines.append("  source_mix:")
    lines.append(f"    path: \"{source_mix}\"")
    lines.append(f"    sha256: \"{source_sha}\"")
    lines.append("")
    lines.append("classifications:")
    for filename, label in CLASSIFICATIONS.items():
        if (stems_dir / filename).exists():
            lines.append(f"  {filename}: {label}")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Write stems.manifest.yaml for stems-to-mixdown after a separation run."
    )
    parser.add_argument("--stems-dir", required=True, type=Path,
                        help="Directory containing the separated stems (vocal.wav etc.)")
    parser.add_argument("--source-mix", required=True, type=Path,
                        help="Path to the original mix file the stems came from.")
    parser.add_argument("--device", default="cpu",
                        choices=("cpu", "mps", "cuda"),
                        help="Compute device demucs ran on (recorded in manifest).")
    parser.add_argument("--demucs-version", default=None,
                        help="demucs version string for provenance. Optional.")
    parser.add_argument("--overwrite", action="store_true",
                        help="Replace an existing stems.manifest.yaml.")
    args = parser.parse_args()

    if not args.stems_dir.is_dir():
        sys.stderr.write(f"[fatal] stems-dir not a directory: {args.stems_dir}\n")
        return 2

    present = [fn for fn in EXPECTED_STEM_FILES if (args.stems_dir / fn).exists()]
    if not present:
        sys.stderr.write(
            f"[fatal] none of {list(EXPECTED_STEM_FILES)} found in {args.stems_dir}. "
            f"Did separate.py finish? (Cmd S2)\n"
        )
        return 1

    manifest_path = args.stems_dir / "stems.manifest.yaml"
    if manifest_path.exists() and not args.overwrite:
        sys.stderr.write(
            f"[refuse] {manifest_path} exists. Pass --overwrite to replace it.\n"
        )
        return 1

    text = render_manifest(args.stems_dir, args.source_mix, args.device,
                           args.demucs_version)
    manifest_path.write_text(text)
    sys.stderr.write(f"[ok] wrote {manifest_path}\n")
    sys.stderr.write(f"     classifications: {', '.join(sorted(present))}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

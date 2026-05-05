#!/usr/bin/env python3
"""
separate.py — wrap `demucs -n htdemucs_ft <input>` and rename outputs.

Demucs by default writes:
    separated/htdemucs_ft/<track>/vocals.wav
    separated/htdemucs_ft/<track>/drums.wav
    separated/htdemucs_ft/<track>/bass.wav
    separated/htdemucs_ft/<track>/other.wav

This wrapper:
1. Picks a sensible compute device (CUDA > MPS > CPU; --device overrides).
2. Runs demucs into a tmp output_root.
3. Moves the four outputs into <input-basename>-stems/ next to the input
   file, RENAMING vocals.wav → vocal.wav and drums.wav → drum.wav so the
   downstream stems-to-mixdown regex `\\b(vocal|drum|...)\\b` matches them.
   (See docs/research/2D in stems-to-mixdown/ for why the regex is strict
   about plurals.)
4. Cleans up the tmp output_root.
5. Calls handoff.py to emit stems.manifest.yaml.

Defaults to MPS on Apple Silicon, CUDA elsewhere if available, CPU
otherwise — the goal is "do the right thing without flags" on the
operator's hardware.

Exit codes:
    0 = stems written + manifest emitted
    1 = demucs failed
    2 = structural error
"""

from __future__ import annotations

import argparse
import os
import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# These are the four outputs demucs's default 4-stem htdemucs_ft model
# produces, in the order it writes them. Mapping is the rename contract.
DEMUCS_TO_S2M = {
    "vocals.wav": "vocal.wav",
    "drums.wav": "drum.wav",
    "bass.wav": "bass.wav",
    "other.wav": "other.wav",
}

DEFAULT_MODEL = "htdemucs_ft"


def detect_device(override: str | None) -> str:
    """Pick a compute device. CUDA > MPS (Apple Silicon) > CPU.

    The override is taken at face value when set; honest about what the
    operator asked for, even if the device isn't actually available
    (demucs will surface that error).
    """
    if override is not None:
        return override
    try:
        import torch  # type: ignore
        if torch.cuda.is_available():
            return "cuda"
        if (platform.system() == "Darwin"
                and getattr(torch.backends, "mps", None) is not None
                and torch.backends.mps.is_available()):
            return "mps"
    except ImportError:
        pass
    return "cpu"


def get_demucs_version() -> str | None:
    try:
        import demucs  # type: ignore
        return getattr(demucs, "__version__", None)
    except ImportError:
        return None


def run_demucs(input_path: Path, output_root: Path, model: str, device: str,
               two_stems: str | None) -> int:
    """Invoke `demucs` as a subprocess. Returns its exit code.

    We shell out instead of importing because demucs's Python API has been
    rearranged across major versions; the CLI is the stable contract.
    """
    cmd = [
        "demucs",
        "-n", model,
        "-d", device,
        "--out", str(output_root),
        str(input_path),
    ]
    if two_stems is not None:
        cmd[1:1] = ["--two-stems", two_stems]
    sys.stderr.write(f"[separate] running: {' '.join(cmd)}\n")
    try:
        return subprocess.call(cmd)
    except FileNotFoundError:
        sys.stderr.write(
            "[fatal] `demucs` not on PATH. Install it: pip install demucs.\n"
            "        Model weights download on first run (~1 GB for htdemucs_ft).\n"
        )
        return 127


def collect_outputs(output_root: Path, model: str, track_stem: str,
                    target_dir: Path) -> list[str]:
    """Move demucs's outputs into target_dir with renamed filenames.

    Returns the list of filenames actually written. Demucs writes to
    <output_root>/<model>/<track_stem>/{vocals,drums,bass,other}.wav.
    """
    src_dir = output_root / model / track_stem
    if not src_dir.is_dir():
        return []
    target_dir.mkdir(parents=True, exist_ok=True)
    written: list[str] = []
    for src_name, dst_name in DEMUCS_TO_S2M.items():
        src = src_dir / src_name
        if src.is_file():
            dst = target_dir / dst_name
            shutil.move(str(src), str(dst))
            written.append(dst_name)
    return written


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Separate a finished stereo mix into stems via demucs htdemucs_ft."
    )
    parser.add_argument("--input", required=True, type=Path,
                        help="Path to the finished stereo mix.")
    parser.add_argument("--output-dir", type=Path, default=None,
                        help=("Destination for separated stems + manifest. "
                              "Default: <input-parent>/<input-stem>-stems/. "
                              "Source folder is never written into (Cmd 18 from stems-to-mixdown)."))
    parser.add_argument("--device", default=None,
                        choices=("cpu", "mps", "cuda"),
                        help="Compute device. Default: auto-detect (CUDA > MPS > CPU).")
    parser.add_argument("--model", default=DEFAULT_MODEL,
                        help=f"demucs model name. Default: {DEFAULT_MODEL}.")
    parser.add_argument("--two-stems", default=None,
                        help=("Pass through to demucs --two-stems (e.g., 'vocals'). "
                              "Produces only 2 stems: the named source and 'no_<source>'."))
    parser.add_argument("--overwrite-manifest", action="store_true",
                        help="Replace an existing stems.manifest.yaml in the output dir.")
    args = parser.parse_args()

    if not args.input.is_file():
        sys.stderr.write(f"[fatal] input not a file: {args.input}\n")
        return 2

    device = detect_device(args.device)
    sys.stderr.write(f"[separate] device: {device}\n")

    target_dir = args.output_dir or (args.input.parent / f"{args.input.stem}-stems")
    sys.stderr.write(f"[separate] output dir: {target_dir}\n")

    track_stem = args.input.stem  # demucs uses the basename without extension

    with tempfile.TemporaryDirectory(prefix="s2m-demucs-") as tmp:
        output_root = Path(tmp)
        rc = run_demucs(args.input, output_root, args.model, device, args.two_stems)
        if rc != 0:
            sys.stderr.write(f"[fatal] demucs exited with code {rc}.\n")
            return 1

        written = collect_outputs(output_root, args.model, track_stem, target_dir)
        if not written:
            sys.stderr.write(
                f"[fatal] demucs did not produce expected outputs in "
                f"{output_root / args.model / track_stem}.\n"
            )
            return 1

    sys.stderr.write(f"[separate] wrote {len(written)} stems: {', '.join(written)}\n")

    # Hand off — call handoff.py as a subprocess so it stays standalone.
    handoff_script = Path(__file__).resolve().parent / "handoff.py"
    handoff_cmd = [
        sys.executable, str(handoff_script),
        "--stems-dir", str(target_dir),
        "--source-mix", str(args.input.resolve()),
        "--device", device,
    ]
    version = get_demucs_version()
    if version:
        handoff_cmd += ["--demucs-version", version]
    if args.overwrite_manifest:
        handoff_cmd.append("--overwrite")
    rc = subprocess.call(handoff_cmd)
    if rc != 0:
        return rc

    sys.stderr.write(
        "\nNext step: hand off to stems-to-mixdown.\n"
        f"  python3 ../stems-to-mixdown/scripts/identify.py --dir {target_dir}\n"
        f"  python3 ../stems-to-mixdown/scripts/analyze.py  --dir {target_dir} > a.json\n"
        f"  python3 ../stems-to-mixdown/scripts/plan.py     --analysis a.json > p.json\n"
        f"  python3 ../stems-to-mixdown/scripts/mix.py      --plan p.json --yes\n"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

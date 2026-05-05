#!/usr/bin/env python3
"""
identify.py — Pass 0a (Triage / Identification).

Fast orientation pass. Scans the input directory in well under a second and
emits a structured triage report so the LLM operator can decide what to do
next *before* committing to any heavy probing or to reading any Pro Tools
metadata.

The point of this script is the negative result. When the input is a clean
folder of well-named stems with no Pro Tools artifacts, identify.py says so
explicitly — and the LLM then skips Pass 0 (Pro Tools intake) entirely
instead of getting bogged down in irrelevant session-info parsing.

Decision contract (the `recommendation` field in identify.json):

    skip_to_pass1            — Filenames are informative or a manifest is
                               already present. The LLM should proceed
                               directly to scripts/analyze.py and not bother
                               loading any Pro Tools metadata.

    run_pass0_pt_intake      — Filenames are mostly generic AND a Pro Tools
                               Session Info text export is present. The LLM
                               should run scripts/import_pt_track_names.py
                               first, then proceed to analyze.py.

    needs_user_clarification — Filenames are generic and no Session Info
                               export is available. The LLM should stop and
                               ask the user for either a Session Info export
                               or a hand-written manifest, rather than
                               running analyze.py blind (which would
                               classify everything as 'other').

What identify.py does NOT do:
    - Run ffprobe, ffmpeg, or any external probe.
    - Measure peaks, LUFS, or any audio content.
    - Compute SHA-256 or any hash.
    - Modify any file.
    - Read more than the first 256 KB of any audio file (and only on a small
      sample — see --sample-size).

Output: identify.json on stdout, a markdown-ish report on stderr.

Exit codes:
    0 = identified successfully (regardless of recommendation)
    2 = structural error (directory missing, etc.)

Usage:
    python3 scripts/identify.py --dir /path/to/stems
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _classification import INFORMATIVE_PATTERNS, normalize_filename  # noqa: E402


AUDIO_EXTS = {
    ".wav", ".wave", ".rf64", ".flac", ".aiff", ".aif",
    ".mp3", ".m4a", ".aac", ".ogg", ".opus",
}
WAV_EXTS = {".wav", ".wave", ".rf64"}


# Patterns that suggest the filename was *auto-generated* by a DAW and
# carries no useful classification signal. These usually appear in
# Pro Tools / Logic / Cubase exports when the engineer never named the
# tracks.
GENERIC_NAME_PATTERNS = [
    re.compile(r"^audio\s*track\s*\d+", re.I),
    re.compile(r"^audio\s*\d+", re.I),
    re.compile(r"^track\s*\d+", re.I),
    re.compile(r"^region\s*\d+", re.I),
    re.compile(r"^bounce\s*\d+", re.I),
    re.compile(r"^untitled\s*\d*", re.I),
    re.compile(r"^new\s+audio\s+file\s*\d*", re.I),
    re.compile(r"^new_audio_file\s*\d*", re.I),
    re.compile(r"^mix\s*\d+", re.I),
    re.compile(r"^stem\s*\d+", re.I),
    re.compile(r"^clip\s*\d+", re.I),
]

# INFORMATIVE_PATTERNS is re-exported from _classification (derived from the
# canonical CLASSIFICATION_RULES so the two never drift).


def score_filename(filename: str) -> str:
    """Returns 'generic' | 'informative' | 'ambiguous'."""
    norm = normalize_filename(Path(filename).stem).strip()
    for pat in GENERIC_NAME_PATTERNS:
        if pat.match(norm):
            return "generic"
    for pat in INFORMATIVE_PATTERNS:
        if pat.search(norm):
            return "informative"
    return "ambiguous"


def find_pt_artifacts(directory: Path) -> dict[str, list[str]]:
    """Detect Pro Tools session artifacts at the top level."""
    found: dict[str, list[str]] = {
        "session_info_txt": [],
        "ptx": [],
        "audio_files_folder": [],
    }
    for path in directory.iterdir():
        if path.is_file():
            name_lower = path.name.lower()
            ext = path.suffix.lower()
            # Session Info text exports — heuristic: filename contains
            # "session" or "info", ends in .txt, and is large enough to
            # plausibly be a real export (>256 bytes).
            if (ext == ".txt"
                    and ("session" in name_lower or "info" in name_lower)
                    and path.stat().st_size > 256):
                found["session_info_txt"].append(str(path))
            elif ext == ".ptx":
                found["ptx"].append(str(path))
        elif path.is_dir():
            # Common Pro Tools session-folder layout
            if path.name.lower() in {"audio files", "bounced files"}:
                found["audio_files_folder"].append(str(path))
    return found


def quick_chunk_scan(path: Path, byte_budget: int = 262144) -> dict[str, bool]:
    """
    Read the first byte_budget bytes of a WAV/RF64 file and look for known
    production-metadata 4CC chunk markers. Cheap signal — we're not parsing,
    just spotting.
    """
    try:
        with path.open("rb") as f:
            head = f.read(byte_budget)
    except OSError as e:
        sys.stderr.write(f"[info] could not read {path.name} for chunk scan: {e}\n")
        return {}
    return {
        "has_bext": b"bext" in head,
        "has_ixml": b"iXML" in head,
        "has_axml": b"axml" in head,  # ADM metadata
    }


def derive_recommendation(
    audio_count: int,
    naming_quality: str,
    pt_artifacts: dict[str, list[str]],
    manifest_present: bool,
    directory: Path,
) -> tuple[str, str, str | None]:
    """
    Returns (recommendation, rationale, next_command).
    """
    has_pt_export = bool(pt_artifacts["session_info_txt"])
    has_ptx = bool(pt_artifacts["ptx"])

    if audio_count == 0:
        return (
            "needs_user_clarification",
            "No audio files found in directory. Confirm the path with the user.",
            None,
        )

    if manifest_present:
        return (
            "skip_to_pass1",
            ("stems.manifest.yaml is already present; Pass 1 will use it. "
             "Do not run Pro Tools intake — it would clobber existing manifest decisions."),
            f"python3 scripts/analyze.py --dir {directory}",
        )

    if naming_quality == "informative":
        return (
            "skip_to_pass1",
            ("Stem filenames are informative; Pass 1's regex classifier will work. "
             "Pro Tools intake is not relevant here, even if a Session Info export exists. "
             "Do not load PT metadata into context."),
            f"python3 scripts/analyze.py --dir {directory}",
        )

    if naming_quality == "generic" and has_pt_export:
        export = pt_artifacts["session_info_txt"][0]
        return (
            "run_pass0_pt_intake",
            ("Stem filenames are mostly generic (DAW auto-numbered) AND a Pro Tools "
             "Session Info text export is present. Run Pass 0 to derive classifications "
             "from track names, then proceed to Pass 1."),
            (f"python3 scripts/import_pt_track_names.py "
             f"--session-info '{export}' --audio-dir {directory} --out {directory}"),
        )

    if naming_quality == "generic" and not has_pt_export:
        ptx_note = (
            " A .ptx file is present, but the plugin does not parse .ptx directly — "
            "ask the user to export 'Session Info as Text' from Pro Tools "
            "(File -> Export -> Session Info as Text)."
        ) if has_ptx else ""
        return (
            "needs_user_clarification",
            ("Stem filenames are mostly generic (DAW auto-numbered) and no Pro Tools "
             "Session Info text export is available." + ptx_note +
             " Either obtain a Session Info export, ask the user to write a "
             "stems.manifest.yaml by hand, or proceed knowing that Pass 1 will "
             "classify everything as 'other'."),
            None,
        )

    # Mixed naming quality — most common real-world case.
    return (
        "skip_to_pass1",
        ("Filenames are mixed informative/generic. Pass 1's regex classifier will "
         "label what it can; the rest land in 'other' and can be moved into groups "
         "via the manifest if needed. Pro Tools intake is not required."),
        f"python3 scripts/analyze.py --dir {directory}",
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description=("stems-to-mixdown / Pass 0a (identify). "
                     "Fast triage scan; emits identify.json with a recommendation "
                     "for the next step. No probes, no measurements, no metadata "
                     "parsing — just orientation."),
    )
    parser.add_argument("--dir", required=True, type=Path,
                        help="Directory of stems to triage.")
    parser.add_argument("--sample-size", type=int, default=8,
                        help=("How many WAV/RF64 files to peek at for production-metadata "
                              "chunk markers. Default 8 — keep small; this is a triage pass."))
    args = parser.parse_args()

    if not args.dir.is_dir():
        sys.stderr.write(f"[fatal] not a directory: {args.dir}\n")
        return 2

    # Catalogue audio files at the top level only — recursion is Pass 1's job.
    audio_files = sorted(
        p for p in args.dir.iterdir()
        if p.is_file() and p.suffix.lower() in AUDIO_EXTS
    )

    # Filename quality scoring
    scores = {"informative": 0, "ambiguous": 0, "generic": 0}
    per_file_score: dict[str, str] = {}
    for p in audio_files:
        s = score_filename(p.name)
        scores[s] += 1
        per_file_score[p.name] = s

    if not audio_files:
        naming_quality = "no_audio"
    elif scores["generic"] / len(audio_files) >= 0.5:
        naming_quality = "generic"
    elif scores["informative"] / len(audio_files) >= 0.5:
        naming_quality = "informative"
    else:
        naming_quality = "mixed"

    # Pro Tools artifact detection
    pt_artifacts = find_pt_artifacts(args.dir)

    # Production-metadata chunk signals — sample a few WAVs only.
    wav_files = [p for p in audio_files if p.suffix.lower() in WAV_EXTS]
    sample = wav_files[:max(0, args.sample_size)]
    metadata_signals = {
        "samples_inspected": len(sample),
        "with_bext": 0,
        "with_ixml": 0,
        "with_axml": 0,
    }
    for p in sample:
        chunks = quick_chunk_scan(p)
        if chunks.get("has_bext"):
            metadata_signals["with_bext"] += 1
        if chunks.get("has_ixml"):
            metadata_signals["with_ixml"] += 1
        if chunks.get("has_axml"):
            metadata_signals["with_axml"] += 1

    manifest_present = (args.dir / "stems.manifest.yaml").is_file()
    session_sidecar_present = (args.dir / "stems.session.yaml").is_file()

    recommendation, rationale, next_command = derive_recommendation(
        audio_count=len(audio_files),
        naming_quality=naming_quality,
        pt_artifacts=pt_artifacts,
        manifest_present=manifest_present,
        directory=args.dir.resolve(),
    )

    out = {
        "schema_version": "1",
        "directory": str(args.dir.resolve()),
        "audio_file_count": len(audio_files),
        "filename_scores": scores,
        "naming_quality": naming_quality,
        "per_file_score": per_file_score,
        "pt_artifacts": pt_artifacts,
        "metadata_signals": metadata_signals,
        "manifest_present": manifest_present,
        "session_sidecar_present": session_sidecar_present,
        "recommendation": recommendation,
        "rationale": rationale,
        "next_command": next_command,
    }

    # Human report on stderr
    e = sys.stderr.write
    e("\n=== stems-to-mixdown / identify ===\n")
    e(f"Directory:           {args.dir}\n")
    e(f"Audio files:         {len(audio_files)}\n")
    if audio_files:
        e(f"Filename quality:    {naming_quality} "
          f"(informative={scores['informative']}, "
          f"ambiguous={scores['ambiguous']}, "
          f"generic={scores['generic']})\n")
    e(f"PT session export:   "
      f"{'yes (' + str(len(pt_artifacts['session_info_txt'])) + ')' if pt_artifacts['session_info_txt'] else 'no'}\n")
    e(f"PT .ptx file:        {'yes' if pt_artifacts['ptx'] else 'no'}\n")
    e(f"Audio Files folder:  {'yes' if pt_artifacts['audio_files_folder'] else 'no'}\n")
    e(f"Manifest present:    {'yes' if manifest_present else 'no'}\n")
    e(f"Session sidecar:     {'yes' if session_sidecar_present else 'no'}\n")
    if metadata_signals["samples_inspected"]:
        e(f"BWF/iXML signals:    "
          f"bext={metadata_signals['with_bext']}/{metadata_signals['samples_inspected']}, "
          f"iXML={metadata_signals['with_ixml']}/{metadata_signals['samples_inspected']}\n")
    e(f"\n>>> Recommendation: {recommendation}\n")
    e(f">>> Rationale:      {rationale}\n")
    if next_command:
        e(f">>> Next command:   {next_command}\n")
    e("\n")

    sys.stdout.write(json.dumps(out, indent=2, default=str))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

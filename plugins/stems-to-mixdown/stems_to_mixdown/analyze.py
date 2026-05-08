#!/usr/bin/env python3
"""
analyze.py — Pass 1 (Discovery) + Pass 2 (Sanity Check).

Thin orchestrator. The real work lives in:
- discover.py   — Pass 1 walk + probe + classify (StemInfo).
- sanity.py     — Pass 2 red-flag detection (RedFlag).
- _enrichment.py — optional wavinfo / mediainfo / bwfmetaedit probes.
- _classification.py — shared filename regexes.
- _manifest.py — manifest loader + schema validator.
- _measure.py  — shared ebur128 + astats parsers.

Walks a directory of audio stems, probes each file, classifies by filename
heuristic (overridable via stems.manifest.yaml), runs sanity checks, and
emits analysis.json on stdout. Human report goes to stderr.

Exit codes:
    0  = clean run, no red flags
    1  = red flags present; --force required to proceed downstream
    2  = structural error (missing tools, unreadable directory, etc.)
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from dataclasses import asdict
from pathlib import Path

# Allow `python3 stems_to_mixdown/analyze.py` invocation alongside `python3 -m stems_to_mixdown.analyze`
if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from stems_to_mixdown import _manifest  # noqa: E402
from stems_to_mixdown._version import __version__  # noqa: E402
from stems_to_mixdown.discover import (  # noqa: E402,F401
    AUDIO_EXTS, StemInfo, MasterReferenceInfo, discover_stems,
    probe_master_reference, require_tools,
)
from stems_to_mixdown.sanity import RedFlag, sanity_check  # noqa: E402,F401
from stems_to_mixdown._enrichment import WavInfoReader  # noqa: E402  -- soft-imported; None if missing
# Re-export for back-compat with anything that imports these symbols here:
from stems_to_mixdown._classification import (  # noqa: E402,F401
    CLASSIFICATION_RULES, classify_by_filename, looks_like_master,
)

load_manifest = _manifest.load_manifest


def print_report(stems: list[StemInfo], flags: list[RedFlag]) -> None:
    e = sys.stderr.write
    e(f"\n=== stems-to-mixdown v{__version__} / analyze ===\n")
    e(f"Stems found: {len(stems)}\n\n")
    for s in stems:
        depth_str = f"{s.bit_depth}-bit" if s.bit_depth else "lossy"
        peak_str = f"{s.true_peak_dbtp:+.2f} dBTP" if s.true_peak_dbtp is not None else "n/a"
        e(f"  [{s.classification:7s}] {s.filename}\n")
        e(f"            {s.codec} / {depth_str} / {s.sample_rate} Hz / "
          f"{s.channels}ch / {s.duration_sec:.3f}s / peak {peak_str}\n")
    e("\n")
    if flags:
        errors = [f for f in flags if f.severity == "error"]
        warns = [f for f in flags if f.severity == "warn"]
        if errors:
            e(f"--- {len(errors)} ERROR(s) ---\n")
            for fl in errors:
                e(f"  [{fl.code}] {fl.message}\n")
        if warns:
            e(f"--- {len(warns)} WARNING(s) ---\n")
            for fl in warns:
                e(f"  [{fl.code}] {fl.message}\n")
    else:
        e("No red flags. Inputs look clean.\n")
    e("\n")


def main() -> int:
    parser = argparse.ArgumentParser(description="stems-to-mixdown / Pass 1+2 (analyze)")
    parser.add_argument("--dir", required=True, type=Path, help="Directory of stems")
    parser.add_argument("--recursive", action="store_true", help="Recurse into subdirectories")
    parser.add_argument("--force", action="store_true", help="Exit zero even if errors are present")
    parser.add_argument(
        "--bwf-report", action="store_true",
        help=("Run BWF MetaEdit on each WAV and write read-only XML/CORE/TECH "
              "reports to <dir>/.s2m/metadata/. Advisory artifacts; not subject "
              "to the determinism contract. Requires bwfmetaedit on PATH."),
    )
    parser.add_argument(
        "--master", type=Path, default=None,
        help=("Path to a user-supplied master reference file (Cmd 19). Overrides "
              "manifest source.master_reference.path. The master must match the "
              "chosen target rate / depth / channels and be within the duration "
              "tolerance of the longest stem; mismatch fires Pass 2 errors and "
              "the run refuses until the master matches or is omitted."),
    )
    parser.add_argument(
        "--no-auto-master", action="store_true",
        help=("Disable auto-detection of a master file alongside the stems. "
              "By default, when neither --master nor manifest.source."
              "master_reference.path is set, analyze looks for a single file "
              "whose name matches a master pattern (master / final / released "
              "/ reference / bounce_final) and uses it as the reference. Use "
              "this flag if you want the file summed as a regular stem."),
    )
    args = parser.parse_args()

    require_tools()

    if not args.dir.is_dir():
        sys.stderr.write(f"[fatal] not a directory: {args.dir}\n")
        return 2

    bwf_report_dir: Path | None = None
    if args.bwf_report:
        if shutil.which("bwfmetaedit") is None:
            sys.stderr.write("[warn] --bwf-report set; bwfmetaedit not on PATH — skipping. "
                             "(install: brew install bwfmetaedit / apt install bwfmetaedit)\n")
        else:
            bwf_report_dir = args.dir / ".s2m" / "metadata"

    if WavInfoReader is None:
        sys.stderr.write("[info] wavinfo not installed — production-metadata enrichment off; "
                         "24-in-32 WAVs read as 32. (install: pip install wavinfo)\n")
    if shutil.which("mediainfo") is None:
        sys.stderr.write("[info] mediainfo not on PATH — probe cross-check off. "
                         "(install: brew install mediainfo / apt install mediainfo)\n")

    manifest = load_manifest(args.dir)

    # Resolve master reference path BEFORE walking stems, so we can exclude it
    # from the stem walk if it lives in the same directory (a common layout).
    # Cmd 19: the master is a witness, not a stem.
    master_path = _manifest.resolve_master_reference_path(
        manifest, args.dir, cli_override=args.master,
    )
    master_source_label = (
        "cli" if args.master is not None
        else "manifest" if master_path is not None
        else None
    )

    # Auto-detection: when neither CLI nor manifest set the master, scan the
    # directory for a single obvious candidate. One match → use it. Multiple
    # → refuse and let the operator pick (silently summing one as a stem and
    # using another as the witness would be the worst of both worlds).
    if master_path is None and not args.no_auto_master:
        candidates = sorted(
            p for p in args.dir.iterdir()
            if p.is_file() and p.suffix.lower() in AUDIO_EXTS
            and looks_like_master(p.name)
        )
        if len(candidates) == 1:
            master_path = candidates[0].resolve()
            master_source_label = "auto"
            sys.stderr.write(
                f"[info] auto-detected master reference: {candidates[0].name} "
                f"(--no-auto-master to disable; --master to override)\n"
            )
        elif len(candidates) > 1:
            names = ", ".join(p.name for p in candidates)
            sys.stderr.write(
                f"[fatal] {len(candidates)} files look like the released master "
                f"({names}). Auto-detection refuses to guess. Pass --master <path> "
                f"to pick one, declare source.master_reference.path in the "
                f"manifest, or rename the unwanted files. (Cmd 19)\n"
            )
            return 2

    exclude = set()
    if master_path is not None:
        try:
            exclude.add(master_path.resolve())
        except OSError:
            pass
    stems = discover_stems(args.dir, args.recursive, manifest,
                           bwf_report_dir=bwf_report_dir,
                           exclude_paths=exclude)

    # Probe the master itself (separate from stems).
    master_info: MasterReferenceInfo | None = None
    master_missing_path: str | None = None
    if master_path is not None:
        master_tol = _manifest.resolve_master_duration_tolerance(manifest)
        master_info = probe_master_reference(
            master_path, master_source_label or "manifest", master_tol,
        )
        if master_info is None:
            # File missing or unprobeable. Surface as Pass 2 error.
            master_missing_path = str(master_path)

    flags = sanity_check(stems, manifest, master_info=master_info,
                         master_missing_path=master_missing_path)
    print_report(stems, flags)

    has_errors = any(f.severity == "error" for f in flags)

    out = {
        "schema_version": "3",
        "directory": str(args.dir.resolve()),
        "manifest_present": bool(manifest),
        "manifest": manifest,
        "stems": [asdict(s) for s in stems],
        "master_reference": asdict(master_info) if master_info is not None else None,
        "red_flags": [asdict(f) for f in flags],
        "has_errors": has_errors,
    }
    sys.stdout.write(json.dumps(out, indent=2, default=str))
    sys.stdout.write("\n")

    if has_errors and not args.force:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""
import_pt_track_names.py — Pass 0b helper / Pro Tools track-name borrower.

Reads a Pro Tools "Session Info as Text" export (File -> Export -> Session Info
as Text in Pro Tools) and **borrows the track names** so analyze.py's
classifier can label files that the engineer didn't bother to rename.

This script does NOT reconstruct session timing. The "Session Info as Text"
export contains track names and file references but not the per-clip
timeline offsets needed to reproduce a session. If you need timeline
reconstruction, **consolidate stems in Pro Tools first** (Edit → Consolidate)
so each stem is anchor-aligned at sample 0; the rest of the pipeline assumes
that. See `docs/research/2E-alignment-heuristics.md` for the detection of
non-anchored stems.

Outputs:

    1. <out>/stems.session.yaml  — full structural context for an LLM operator:
                                   session metadata, track listing, file listing,
                                   markers. Not consumed by analyze.py; lives
                                   alongside the manifest as reference material.

    2. <out>/stems.manifest.yaml — partial manifest in the existing schema
                                   (see references/manifest-schema.md). Only
                                   `classifications` is populated, derived from
                                   track-name regex via _classification.py.
                                   Empty `groups:`. The user completes the rest.

Every file written into the manifest is preflighted against --audio-dir. Files
that don't exist on disk are dropped from the manifest and logged as warnings,
so analyze.py won't hard-error on the first run.

The output of this script is read-only context. It does NOT modify the
.ptx file, the source WAVs, or the Pro Tools session in any way.

Exit codes:
    0 = manifest and session sidecar written successfully
    1 = session-info file unreadable or empty
    2 = structural error (audio dir missing, etc.)

Usage:
    python3 stems_to_mixdown/import_pt_track_names.py \\
        --session-info "Session Info.txt" \\
        --audio-dir "Audio Files" \\
        --out ./

References:
    references/manifest-schema.md   — manifest schema this script writes to.
    references/pro-audio-metadata.md — why the session sidecar exists.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Any

# Allow `python3 stems_to_mixdown/import_pt_track_names.py` invocation alongside `python3 -m stems_to_mixdown.import_pt_track_names`
if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from stems_to_mixdown._classification import classify_by_filename  # noqa: E402

try:
    import yaml  # PyYAML
except ImportError:
    yaml = None


# ---------------------------------------------------------------------------
# Pro Tools text-export parsing
# ---------------------------------------------------------------------------

# Pro Tools "Session Info as Text" header lines look like:
#   SESSION NAME:  My Session
#   SAMPLE RATE:  48000.000000
#   BIT DEPTH:  24-bit
#   SESSION START TIMECODE:  00:59:58:00
#   TIMECODE FORMAT:  29.97 Drop Frame
#   # OF AUDIO TRACKS:  24
#   # OF AUDIO CLIPS:  142
#   # OF AUDIO FILES:  18
HEADER_FIELDS = {
    "SESSION NAME": "name",
    "SAMPLE RATE": "sample_rate",
    "BIT DEPTH": "bit_depth",
    "SESSION START TIMECODE": "session_start_timecode",
    "TIMECODE FORMAT": "timecode_format",
    "# OF AUDIO TRACKS": "audio_track_count",
    "# OF AUDIO CLIPS": "audio_clip_count",
    "# OF AUDIO FILES": "audio_file_count",
}

# Section header detection. Pro Tools uses spaced-out caps like "F I L E S  I N
# S E S S I O N" — we collapse spaces in the candidate then match.
SECTION_PATTERNS = {
    "files": re.compile(r"^F\s*I\s*L\s*E\s*S\s+I\s*N\s+S\s*E\s*S\s*S\s*I\s*O\s*N", re.I),
    "online_files": re.compile(r"^O\s*N\s*L\s*I\s*N\s*E\s+F\s*I\s*L\s*E\s*S", re.I),
    "offline_files": re.compile(r"^O\s*F\s*F\s*L\s*I\s*N\s*E\s+F\s*I\s*L\s*E\s*S", re.I),
    "tracks": re.compile(r"^T\s*R\s*A\s*C\s*K\s+L\s*I\s*S\s*T\s*I\s*N\s*G", re.I),
    "markers": re.compile(r"^M\s*A\s*R\s*K\s*E\s*R\s*S\s+L\s*I\s*S\s*T\s*I\s*N\s*G", re.I),
    "plugins": re.compile(r"^P\s*L\s*U\s*G[\s-]*I\s*N\s*S?\s+L\s*I\s*S\s*T\s*I\s*N\s*G", re.I),
}

# Track block delimiter — each track in the listing starts with "TRACK NAME:"
TRACK_NAME_RE = re.compile(r"^TRACK NAME:\s*(.+)$")
TRACK_COMMENT_RE = re.compile(r"^TRACK COMMENTS:\s*(.*)$")
TRACK_USER_DELAY_RE = re.compile(r"^USER DELAY:\s*(.+)$")
TRACK_STATE_RE = re.compile(r"^STATE:\s*(.+)$")  # Active / Inactive / Hidden

# File-listing entry — typically one filename + path per line. Exact format
# varies by PT version; we fall back to "any line that ends in a known audio
# extension."
FILE_LINE_RE = re.compile(r"(.+\.(?:wav|wave|aif|aiff|rf64|mp3|m4a|aac))\s*$", re.I)


def parse_header(lines: list[str]) -> tuple[dict[str, Any], int]:
    """
    Parse the leading header block. Returns (header_dict, end_index).
    Stops at the first detected section header.
    """
    header: dict[str, Any] = {}
    for i, raw in enumerate(lines):
        line = raw.rstrip()
        # Section header? stop.
        for pat in SECTION_PATTERNS.values():
            if pat.match(line.strip()):
                return header, i
        # Field?
        if ":" in line:
            key, _, value = line.partition(":")
            key = key.strip().upper()
            if key in HEADER_FIELDS:
                header[HEADER_FIELDS[key]] = value.strip()
    return header, len(lines)


def detect_sections(lines: list[str], start: int) -> dict[str, tuple[int, int]]:
    """
    Scan from `start` and return {section_name: (begin, end)} for every detected
    section, where begin is the line of the section header and end is the line
    just before the next section (or len(lines)).
    """
    boundaries: list[tuple[int, str]] = []
    for i, raw in enumerate(lines[start:], start=start):
        line = raw.strip()
        for name, pat in SECTION_PATTERNS.items():
            if pat.match(line):
                boundaries.append((i, name))
                break
    out: dict[str, tuple[int, int]] = {}
    for idx, (line_no, name) in enumerate(boundaries):
        end = boundaries[idx + 1][0] if idx + 1 < len(boundaries) else len(lines)
        out[name] = (line_no, end)
    return out


def parse_files_section(block: list[str]) -> list[dict[str, Any]]:
    """
    Parse a FILES IN SESSION / ONLINE FILES / OFFLINE FILES block.
    Returns a list of {filename, path}.
    """
    files: list[dict[str, Any]] = []
    for raw in block:
        line = raw.rstrip()
        if not line.strip():
            continue
        # Try the "filename + path" pattern Pro Tools commonly emits.
        m = FILE_LINE_RE.search(line)
        if not m:
            continue
        full = m.group(1).strip()
        # Pro Tools sometimes emits "Macintosh HD:Users:..." paths; the
        # filename is the last component regardless of separator.
        last_sep = max(full.rfind("/"), full.rfind("\\"), full.rfind(":"))
        filename = full[last_sep + 1:] if last_sep >= 0 else full
        files.append({"filename": filename, "path": full})
    return files


def parse_tracks_section(block: list[str]) -> list[dict[str, Any]]:
    """
    Parse the TRACK LISTING block. Returns list of {name, comments, state, clips}.

    Pro Tools formats clips/regions per track in a tabular block following the
    track header. Format varies; we capture clip names as a best-effort list of
    file references that appear after TRACK NAME: until the next TRACK NAME: or
    end-of-block.
    """
    tracks: list[dict[str, Any]] = []
    current: dict[str, Any] | None = None
    for raw in block:
        line = raw.rstrip()
        m = TRACK_NAME_RE.match(line)
        if m:
            if current is not None:
                tracks.append(current)
            current = {
                "name": m.group(1).strip(),
                "comments": None,
                "state": None,
                "clips": [],
            }
            continue
        if current is None:
            continue
        m = TRACK_COMMENT_RE.match(line)
        if m:
            current["comments"] = m.group(1).strip() or None
            continue
        m = TRACK_STATE_RE.match(line)
        if m:
            current["state"] = m.group(1).strip()
            continue
        # Best-effort clip detection: any line containing an audio-file
        # reference is captured as a clip.
        m = FILE_LINE_RE.search(line)
        if m:
            full = m.group(1).strip()
            last_sep = max(full.rfind("/"), full.rfind("\\"), full.rfind(":"))
            current["clips"].append(full[last_sep + 1:] if last_sep >= 0 else full)
    if current is not None:
        tracks.append(current)
    # Dedupe clip lists in-place
    for t in tracks:
        seen: set[str] = set()
        deduped: list[str] = []
        for c in t["clips"]:
            if c not in seen:
                seen.add(c)
                deduped.append(c)
        t["clips"] = deduped
    return tracks


def parse_session_info(text: str) -> dict[str, Any]:
    lines = text.splitlines()
    header, hdr_end = parse_header(lines)
    sections = detect_sections(lines, hdr_end)

    files: list[dict[str, Any]] = []
    online_files: list[dict[str, Any]] = []
    offline_files: list[dict[str, Any]] = []
    if "files" in sections:
        b, e = sections["files"]
        files = parse_files_section(lines[b + 1:e])
    if "online_files" in sections:
        b, e = sections["online_files"]
        online_files = parse_files_section(lines[b + 1:e])
    if "offline_files" in sections:
        b, e = sections["offline_files"]
        offline_files = parse_files_section(lines[b + 1:e])

    tracks: list[dict[str, Any]] = []
    if "tracks" in sections:
        b, e = sections["tracks"]
        tracks = parse_tracks_section(lines[b + 1:e])

    raw_blocks: dict[str, str] = {}
    for name in ("markers", "plugins"):
        if name in sections:
            b, e = sections[name]
            raw_blocks[name] = "\n".join(lines[b:e]).strip()

    return {
        "session": header,
        "files": files,
        "online_files": online_files,
        "offline_files": offline_files,
        "tracks": tracks,
        "raw_blocks": raw_blocks,
    }


# Classification — re-exported from _classification.py.

# ---------------------------------------------------------------------------
# Manifest derivation
# ---------------------------------------------------------------------------

def derive_classifications(
    parsed: dict[str, Any],
    audio_dir: Path,
) -> tuple[dict[str, str], list[str]]:
    """
    Derive per-file classifications by matching track names to filenames.
    Files referenced by the session but not present in audio_dir are dropped
    (and listed in `dropped`).

    Returns (classifications_map, dropped_filenames).
    """
    files_on_disk = {p.name: p for p in audio_dir.iterdir() if p.is_file()}

    # Build a filename -> [track_name, ...] map so a clip used on multiple
    # tracks gets all the candidate names, and we pick the most-classifying.
    file_to_tracks: dict[str, list[str]] = {}
    for track in parsed.get("tracks", []):
        # Skip non-audio tracks where we can detect them. Pro Tools listings
        # don't always include track-type fields; default to including
        # everything that has clips.
        for clip_path in track.get("clips", []):
            last_sep = max(clip_path.rfind("/"), clip_path.rfind("\\"), clip_path.rfind(":"))
            filename = clip_path[last_sep + 1:] if last_sep >= 0 else clip_path
            file_to_tracks.setdefault(filename, []).append(track["name"])

    classifications: dict[str, str] = {}
    dropped: list[str] = []
    for filename, track_names in file_to_tracks.items():
        if filename not in files_on_disk:
            dropped.append(filename)
            continue
        # Try track name first (more informative than filename), fall back to
        # filename. Pick the most-specific (i.e., not "other") result.
        candidates = []
        for tn in track_names:
            candidates.append(classify_by_filename(tn))
        candidates.append(classify_by_filename(Path(filename).stem))
        non_other = [c for c in candidates if c != "other"]
        classifications[filename] = non_other[0] if non_other else "other"
    return classifications, dropped


# ---------------------------------------------------------------------------
# Output writers
# ---------------------------------------------------------------------------

def write_session_sidecar(parsed: dict[str, Any], out_path: Path) -> None:
    """Write the full structural context as YAML for LLM operator reference."""
    payload = {
        "schema_version": "1",
        "source": "pro_tools_session_info_text_export",
        "session": parsed.get("session") or {},
        "tracks": parsed.get("tracks") or [],
        "files": parsed.get("files") or [],
        "online_files": parsed.get("online_files") or [],
        "offline_files": parsed.get("offline_files") or [],
        "raw_blocks": parsed.get("raw_blocks") or {},
    }
    with out_path.open("w") as f:
        if yaml is not None:
            yaml.safe_dump(payload, f, sort_keys=False, default_flow_style=False)
        else:
            # Degrade to JSON if PyYAML is missing — still readable, still YAML-valid.
            import json
            json.dump(payload, f, indent=2, default=str)


def write_partial_manifest(
    classifications: dict[str, str],
    dropped: list[str],
    project_name: str | None,
    out_path: Path,
) -> None:
    """
    Write a partial stems.manifest.yaml in the existing schema. Only fills in
    `classifications`. `groups`, `gains`, `output`, `metadata` left for the
    user to complete by hand.
    """
    if not classifications:
        sys.stderr.write(
            "[warn] no classifications derived — refusing to overwrite an existing "
            f"manifest with empty content. {out_path} not written.\n"
        )
        return
    payload: dict[str, Any] = {}
    if project_name:
        payload["project"] = project_name
    payload["classifications"] = dict(sorted(classifications.items()))
    header = (
        "# stems.manifest.yaml — partial, generated by import_session_info.py.\n"
        "# Only `classifications` was derived from the Pro Tools session.\n"
        "# Fill in `groups`, `gains`, `output`, `metadata` by hand if needed.\n"
        "# Schema reference: references/manifest-schema.md.\n"
    )
    if dropped:
        header += (
            "#\n"
            "# Files referenced by the session but not present in --audio-dir "
            f"were dropped ({len(dropped)} total):\n"
        )
        for d in sorted(dropped):
            header += f"#   - {d}\n"
    with out_path.open("w") as f:
        f.write(header)
        if yaml is not None:
            yaml.safe_dump(payload, f, sort_keys=False, default_flow_style=False)
        else:
            import json
            json.dump(payload, f, indent=2, default=str)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(
        description=("stems-to-mixdown / Pass 0 (Pro Tools intake bridge). "
                     "Reads a Pro Tools 'Session Info as Text' export and "
                     "writes stems.session.yaml + a partial stems.manifest.yaml."),
    )
    parser.add_argument("--session-info", required=True, type=Path,
                        help="Path to Pro Tools 'Session Info.txt' export.")
    parser.add_argument("--audio-dir", required=True, type=Path,
                        help="Directory containing the actual stem files.")
    parser.add_argument("--out", required=True, type=Path,
                        help=("Output directory for stems.session.yaml and "
                              "stems.manifest.yaml. Typically same as --audio-dir."))
    parser.add_argument("--project", type=str, default=None,
                        help="Override project name (defaults to session name).")
    parser.add_argument("--overwrite", action="store_true",
                        help=("Overwrite an existing stems.manifest.yaml. By default "
                              "the script refuses if one is present, to avoid clobbering "
                              "hand edits."))
    args = parser.parse_args()

    if not args.session_info.is_file():
        sys.stderr.write(f"[fatal] session-info file not found: {args.session_info}\n")
        return 1
    if not args.audio_dir.is_dir():
        sys.stderr.write(f"[fatal] audio-dir not a directory: {args.audio_dir}\n")
        return 2
    args.out.mkdir(parents=True, exist_ok=True)

    text = args.session_info.read_text(encoding="utf-8", errors="replace")
    if not text.strip():
        sys.stderr.write("[fatal] session-info file is empty\n")
        return 1

    parsed = parse_session_info(text)
    session = parsed.get("session") or {}

    sys.stderr.write("\n=== stems-to-mixdown / import_session_info ===\n")
    sys.stderr.write(f"Session name:    {session.get('name', '?')}\n")
    sys.stderr.write(f"Sample rate:     {session.get('sample_rate', '?')}\n")
    sys.stderr.write(f"Bit depth:       {session.get('bit_depth', '?')}\n")
    sys.stderr.write(f"Audio tracks:    {session.get('audio_track_count', '?')}\n")
    sys.stderr.write(f"Audio clips:     {session.get('audio_clip_count', '?')}\n")
    sys.stderr.write(f"Audio files:     {session.get('audio_file_count', '?')}\n")
    sys.stderr.write(f"Tracks parsed:   {len(parsed.get('tracks', []))}\n")
    sys.stderr.write(f"Files in dir:    {sum(1 for p in args.audio_dir.iterdir() if p.is_file())}\n")

    classifications, dropped = derive_classifications(parsed, args.audio_dir)
    if dropped:
        sys.stderr.write(
            f"\n[warn] {len(dropped)} session-referenced files not present in "
            f"--audio-dir; dropped from manifest:\n"
        )
        for d in sorted(dropped):
            sys.stderr.write(f"  - {d}\n")

    # Write the session sidecar — always.
    session_sidecar = args.out / "stems.session.yaml"
    write_session_sidecar(parsed, session_sidecar)
    sys.stderr.write(f"\n[ok] wrote {session_sidecar}\n")

    # Write the manifest — refuse to overwrite without --overwrite.
    manifest_path = args.out / "stems.manifest.yaml"
    if manifest_path.exists() and not args.overwrite:
        sys.stderr.write(
            f"[skip] {manifest_path} already exists; pass --overwrite to replace it.\n"
        )
    else:
        project_name = args.project or session.get("name") or None
        write_partial_manifest(classifications, dropped, project_name, manifest_path)
        if classifications:
            sys.stderr.write(f"[ok] wrote {manifest_path} "
                             f"({len(classifications)} classifications)\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())

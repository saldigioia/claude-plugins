#!/usr/bin/env python3
"""
verify.py — optional QC pass over separated stems.

Catches the obvious failures: stems with full silence, stems clipping at the
output, stems much quieter than expected (a sign the model failed to find
that source). Subtle bleed and frequency-balance issues are NOT detectable
here — those require listening (Cmd S1; see references/separation-limits.md).

Reuses stems-to-mixdown/scripts/_measure.py for ebur128 + astats parsing
when the sibling skill is installed alongside this one. Falls back to a
self-contained ffmpeg shell-out if it isn't.

Exit codes:
    0 = no issues
    1 = at least one stem failed a QC check
    2 = structural error
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

EXPECTED = ("vocal.wav", "drum.wav", "bass.wav", "other.wav")

# Try to import stems-to-mixdown's _measure for the canonical parser.
# Two layouts to support: deployed (sibling skills under ~/.claude/skills/)
# and in-repo dev (stems-from-mix/ nested inside stems-to-mixdown/).
_HERE = Path(__file__).resolve().parent
_S2M_CANDIDATES = (
    _HERE.parent.parent / "stems-to-mixdown" / "scripts",  # deployed (sibling)
    _HERE.parent.parent / "scripts",                        # in-repo (parent's scripts/)
)
_measure = None
for _cand in _S2M_CANDIDATES:
    if (_cand / "_measure.py").is_file():
        sys.path.insert(0, str(_cand))
        try:
            import _measure  # type: ignore
            break
        except ImportError:
            continue


def _parse_peak(stderr: str) -> float | None:
    """Fallback parser if stems-to-mixdown's _measure isn't importable."""
    section: str | None = None
    for raw in stderr.splitlines():
        line = raw.strip()
        if line == "True peak:":
            section = "True peak"
            continue
        if section == "True peak" and line.startswith("Peak:"):
            m = re.search(r"(-?\d+\.\d+|inf|-inf)\s*dBFS", line)
            if m:
                v = m.group(1)
                if v == "inf":
                    return float("inf")
                if v == "-inf":
                    return float("-inf")
                return float(v)
    return None


def measure_loudness(path: Path) -> dict:
    """Returns {true_peak_dbtp, integrated_lufs}. Defers to _measure if present."""
    if _measure is not None:
        s = _measure.measure_loudness_file(path)
        return {"true_peak_dbtp": s["true_peak_dbtp"],
                "integrated_lufs": s["integrated_lufs"]}
    r = subprocess.run(
        ["ffmpeg", "-nostdin", "-hide_banner", "-i", str(path),
         "-af", "ebur128=peak=true", "-f", "null", "-"],
        capture_output=True, text=True,
    )
    return {"true_peak_dbtp": _parse_peak(r.stderr), "integrated_lufs": None}


def verify_stem(path: Path) -> dict:
    issues: list[str] = []
    measurements = measure_loudness(path)
    tp = measurements.get("true_peak_dbtp")

    if tp is None:
        issues.append("could not measure true peak")
    elif tp == float("-inf") or tp < -90.0:
        # demucs sometimes produces a near-silent "no_X" stream for material
        # where the named source isn't present (e.g., a fully instrumental
        # track separated with vocals model). Surface, don't fail by default.
        issues.append(f"effectively silent (true peak {tp} dBFS) — model likely "
                      "found no signal of this type in the source mix")
    elif tp > 0.0:
        issues.append(f"clipping: true peak {tp:.2f} dBTP > 0 dBFS — separation "
                      "introduced or amplified clipping that wasn't in the source")
    elif tp > -1.0:
        issues.append(f"near-clipping: true peak {tp:.2f} dBTP — close to 0 dBFS, "
                      "watch for inter-sample clipping after lossy encode")

    return {
        "filename": path.name,
        "true_peak_dbtp": tp,
        "issues": issues,
        "verdict": "fail" if any("clipping:" in i for i in issues) else
                   ("smell" if issues else "ok"),
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="QC the separated stems produced by separate.py."
    )
    parser.add_argument("--stems-dir", required=True, type=Path,
                        help="Directory containing the separated stems.")
    parser.add_argument("--strict", action="store_true",
                        help="Treat 'smell' verdicts (silence / near-clip) as failures.")
    args = parser.parse_args()

    if not args.stems_dir.is_dir():
        sys.stderr.write(f"[fatal] stems-dir not a directory: {args.stems_dir}\n")
        return 2

    sys.stderr.write(f"\n=== stems-from-mix / verify ===\n")
    sys.stderr.write(f"stems-dir: {args.stems_dir}\n\n")

    results: list[dict] = []
    any_fail = False
    for fn in EXPECTED:
        path = args.stems_dir / fn
        if not path.exists():
            sys.stderr.write(f"  [skip] {fn} not present\n")
            continue
        result = verify_stem(path)
        results.append(result)
        sys.stderr.write(f"  [{result['verdict']:5s}] {fn}: "
                         f"true peak {result['true_peak_dbtp']!r} dBTP\n")
        for issue in result["issues"]:
            sys.stderr.write(f"           - {issue}\n")
        if result["verdict"] == "fail":
            any_fail = True
        elif args.strict and result["verdict"] == "smell":
            any_fail = True

    sys.stderr.write("\n")
    sys.stderr.write("Subtle bleed and frequency-balance issues are not detectable "
                     "here — that's a listening problem. See "
                     "references/separation-limits.md (Cmd S1).\n")

    sys.stdout.write(json.dumps({"results": results}, indent=2, default=str))
    sys.stdout.write("\n")
    return 1 if any_fail else 0


if __name__ == "__main__":
    sys.exit(main())

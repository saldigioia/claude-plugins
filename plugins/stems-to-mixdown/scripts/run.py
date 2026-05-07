#!/usr/bin/env python3
"""
run.py — one-shot orchestrator (the obvious case).

Surveys the directory once, then chains identify → (optional PT intake) →
analyze → plan → mix → verify in a single command. Sensible defaults
throughout: auto-master, plan approval prompt, skill's standard sibling
output dir.

When the directory is unambiguous (well-named stems, no Pro Tools artifacts,
optional master alongside) this is the only script anyone needs to invoke.
The per-pass scripts (identify.py, analyze.py, plan.py, mix.py, verify.py)
remain for power users who want intermediate JSON, manual --force, or to
re-run a single pass against an existing artifact.

Decision flow:

    identify.py                          (always)
        │
        ├─ recommendation: needs_user_clarification → stop, print rationale
        ├─ recommendation: run_pass0_pt_intake     → run import_pt_track_names
        └─ recommendation: skip_to_pass1           → continue
        ▼
    analyze.py --master <auto>           (auto-detect; --no-auto-master to disable)
        │
        ├─ errors and not --force → stop, print red flags
        └─ clean (or --force)     → continue
        ▼
    plan.py
        │
        ├─ --yes or interactive 'yes' → continue
        └─ otherwise                  → stop after writing plan.json
        ▼
    mix.py [--preview] [--solo]
        ▼
    verify.py [--check-mono-fold] [--report-all-platforms]

Exit codes:
    0  = pipeline completed end-to-end
    1  = pipeline halted at a step (red flags, plan declined, mix/verify failure)
    2  = structural error (missing tools, bad directory, etc.)

Usage:
    python3 scripts/run.py --dir /path/to/stems
    python3 scripts/run.py --dir /path/to/stems --yes
    python3 scripts/run.py --dir /path/to/stems --master /path/to/song.flac
    python3 scripts/run.py --dir /path/to/stems --preview --solo
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))
from _version import __version__  # noqa: E402


def _run(cmd: list[str], *, capture_stdout: bool = False) -> subprocess.CompletedProcess:
    """Run a script, streaming stderr to the console; capture stdout if asked."""
    return subprocess.run(
        cmd,
        check=False,
        stdout=subprocess.PIPE if capture_stdout else None,
        stderr=None,  # always passes through to console
        text=True,
    )


def _pretty(label: str) -> None:
    sys.stderr.write(f"\n========== {label} ==========\n")


def main() -> int:
    parser = argparse.ArgumentParser(
        description=("stems-to-mixdown / one-shot orchestrator. "
                     "Runs identify → analyze → plan → mix → verify with "
                     "auto-decisions for the common case."),
    )
    parser.add_argument("--dir", required=True, type=Path,
                        help="Directory of stems (and optionally a master file).")
    parser.add_argument("--master", type=Path, default=None,
                        help=("Path to the released master (Cmd 19). When unset, "
                              "auto-detection picks a single candidate from --dir "
                              "if exactly one is present."))
    parser.add_argument("--no-auto-master", action="store_true",
                        help="Disable master auto-detection (passes through to analyze.py).")
    parser.add_argument("--output-dir", type=Path, default=None,
                        help=("Override the output directory. Default: a sibling "
                              "<source-name>-mixdowns/ next to --dir."))
    parser.add_argument("--yes", action="store_true",
                        help="Skip the plan approval prompt.")
    parser.add_argument("--force", action="store_true",
                        help=("Continue past Pass 2 red flags (rate mismatch, etc.) "
                              "and re-mix even when an idempotency key matches."))
    parser.add_argument("--archival", action="store_true",
                        help=("Produce unity-sum unprocessed output (the v1.2 default). "
                              "Inverse of the v1.3 normalized listening master. (Cmd 9 revised)"))
    parser.add_argument("--target-lufs", type=float, default=None,
                        help=("Integrated-loudness target in LUFS-I. Default -14 "
                              "(streaming consensus); -16 for Apple-first; -23 for EBU R128."))
    parser.add_argument("--target-true-peak", type=float, default=None,
                        help=("True-peak ceiling in dBTP. Default -1.0; -1.5 for "
                              "conservative AAC headroom; -2.0 for ATSC A/85."))
    parser.add_argument("--auto-pan", action="store_true",
                        help=("Spread N classified-the-same mono stems across the field; "
                              "vocals + bass stay center. (Cmd 20)"))
    parser.add_argument("--solo", action="store_true",
                        help="Pass --solo to mix.py (per-stem QC bounces).")
    parser.add_argument("--check-mono-fold", action="store_true",
                        help="Pass --check-mono-fold to verify.py.")
    parser.add_argument("--report-all-platforms", action="store_true",
                        help="Pass --report-all-platforms to verify.py.")
    parser.add_argument("--bwf-report", action="store_true",
                        help="Pass --bwf-report to analyze.py (BWF MetaEdit XML/CSV).")
    parser.add_argument("--artifacts-dir", type=Path, default=None,
                        help=("Where to write identify.json / analysis.json / plan.json / "
                              "mix.json / verify.json. Default: <output-dir>/.s2m/run/"))
    args = parser.parse_args()

    if not args.dir.is_dir():
        sys.stderr.write(f"[fatal] not a directory: {args.dir}\n")
        return 2

    # Resolve output dir the same way plan.py does, so artifacts and outputs
    # land in predictable locations.
    output_dir = args.output_dir or (args.dir.parent / f"{args.dir.name}-mixdowns")
    artifacts = args.artifacts_dir or (output_dir / ".s2m" / "run")
    artifacts.mkdir(parents=True, exist_ok=True)
    identify_json = artifacts / "identify.json"
    analysis_json = artifacts / "analysis.json"
    plan_json = artifacts / "plan.json"
    mix_json = artifacts / "mix.json"
    verify_json = artifacts / "verify.json"

    sys.stderr.write(f"\n=== stems-to-mixdown v{__version__} / run ===\n")
    sys.stderr.write(f"Source:    {args.dir}\n")
    sys.stderr.write(f"Output:    {output_dir}\n")
    sys.stderr.write(f"Artifacts: {artifacts}\n")

    # ---- Pass 0a — identify ----
    _pretty("identify (Pass 0a)")
    r = _run(
        ["python3", str(SCRIPTS / "identify.py"), "--dir", str(args.dir)],
        capture_stdout=True,
    )
    if r.returncode != 0:
        sys.stderr.write("[fatal] identify failed; halting.\n")
        return 2
    identify_json.write_text(r.stdout)
    try:
        identify = json.loads(r.stdout)
    except json.JSONDecodeError as e:
        sys.stderr.write(f"[fatal] identify produced invalid JSON: {e}\n")
        return 2

    rec = identify.get("recommendation")
    if rec == "needs_user_clarification":
        sys.stderr.write(
            f"\n[stop] identify recommends user clarification. "
            f"Rationale: {identify.get('rationale')}\n"
        )
        return 1

    # Phase 1 (v1.3): identify may have hopped one level deeper to find the
    # actual audio directory. Use resolved_directory for everything downstream;
    # the operator still sees what they typed in artifacts.
    resolved = identify.get("resolved_directory")
    if resolved and resolved != str(args.dir.resolve()):
        sys.stderr.write(
            f"[info] descending into {resolved} (the only nested audio dir).\n"
        )
        analyze_target = Path(resolved)
    else:
        analyze_target = args.dir

    # ---- Pass 0b — Pro Tools track-name borrow (only if recommended) ----
    if rec == "run_pass0_pt_intake":
        _pretty("Pro Tools track-name intake (Pass 0b)")
        next_cmd = identify.get("next_command")
        if not next_cmd:
            sys.stderr.write("[fatal] PT intake recommended but identify gave no next_command.\n")
            return 2
        # next_command is a shell-quoted string; split it carefully.
        import shlex
        pt = subprocess.run(shlex.split(next_cmd), check=False)
        if pt.returncode != 0:
            sys.stderr.write("[fatal] PT intake failed; halting.\n")
            return 2

    # ---- Pass 1+2 — analyze ----
    _pretty("analyze (Pass 1+2)")
    cmd = ["python3", str(SCRIPTS / "analyze.py"), "--dir", str(analyze_target)]
    if args.master is not None:
        cmd += ["--master", str(args.master)]
    if args.no_auto_master:
        cmd.append("--no-auto-master")
    if args.bwf_report:
        cmd.append("--bwf-report")
    if args.force:
        cmd.append("--force")
    r = _run(cmd, capture_stdout=True)
    if r.stdout:
        analysis_json.write_text(r.stdout)
    if r.returncode != 0:
        sys.stderr.write(
            "\n[stop] analyze reported red flags. Re-run with --force to "
            "proceed past Pass 2 errors, or fix the inputs and try again.\n"
        )
        return 1

    # ---- Pass 3 — plan ----
    _pretty("plan (Pass 3)")
    # Always pass --output-dir so artifacts and mixdowns land in the same
    # tree the orchestrator computed up front. Without this, plan.py would
    # default to <analyze_target>/../<analyze_target.name>-mixdowns/ and
    # the artifacts (in <args.dir>/../<args.dir.name>-mixdowns/.s2m/run/)
    # would diverge from the canonical mixdowns when run.py descended.
    cmd = [
        "python3", str(SCRIPTS / "plan.py"),
        "--analysis", str(analysis_json),
        "--output-dir", str(output_dir),
    ]
    if args.archival:
        cmd.append("--archival")
    if args.target_lufs is not None:
        cmd += ["--target-lufs", str(args.target_lufs)]
    if args.target_true_peak is not None:
        cmd += ["--target-true-peak", str(args.target_true_peak)]
    if args.auto_pan:
        cmd.append("--auto-pan")
    r = _run(cmd, capture_stdout=True)
    if r.stdout:
        plan_json.write_text(r.stdout)
    if r.returncode != 0:
        sys.stderr.write("[fatal] plan generation failed; halting.\n")
        return 1

    # Approval gate (skipped with --yes).
    if not args.yes:
        sys.stderr.write(
            "\n--- approve? ---\n"
            "Type 'yes' to mix, anything else to stop here. The plan and the\n"
            "analysis JSON have already been written under "
            f"{artifacts}\n"
            "for inspection.\n> "
        )
        sys.stderr.flush()
        ans = sys.stdin.readline().strip().lower()
        if ans != "yes":
            sys.stderr.write("[stop] plan declined; halting before mix.\n")
            return 1

    # ---- Pass 4 — mix ----
    _pretty("mix (Pass 4)")
    cmd = ["python3", str(SCRIPTS / "mix.py"), "--plan", str(plan_json), "--yes"]
    if args.solo:
        cmd.append("--solo")
    if args.force:
        cmd.append("--force-overwrite")
    r = _run(cmd, capture_stdout=True)
    if r.stdout:
        mix_json.write_text(r.stdout)
    if r.returncode != 0:
        sys.stderr.write("[stop] mix failed; verify will not run.\n")
        return 1

    # ---- Pass 5 — verify ----
    _pretty("verify (Pass 5)")
    cmd = ["python3", str(SCRIPTS / "verify.py"), "--plan", str(plan_json)]
    if args.check_mono_fold:
        cmd.append("--check-mono-fold")
    if args.report_all_platforms:
        cmd.append("--report-all-platforms")
    r = _run(cmd, capture_stdout=True)
    if r.stdout:
        verify_json.write_text(r.stdout)
    if r.returncode != 0:
        sys.stderr.write(
            "[stop] verify reported issues; outputs are present but the run "
            "should not be considered clean.\n"
        )
        return 1

    sys.stderr.write(
        f"\n[ok] pipeline complete. Outputs in {output_dir}/. "
        f"Full JSON in {artifacts}/.\n"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

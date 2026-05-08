"""stems-to-mixdown — sum multitrack stems into stereo mixdowns.

Public modules:
    run                       — one-shot orchestrator (identify → analyze → plan → mix → verify)
    identify                  — Pass 0a (triage / folder-shape detection)
    import_pt_track_names     — Pass 0b (Pro Tools track-name borrower)
    analyze                   — Pass 1 + 2 (discover, probe, sanity-check)
    plan                      — Pass 3 (format decision + dry-run plan emission)
    mix                       — Pass 4 (execute the plan via ffmpeg)
    verify                    — Pass 5 (re-probe outputs, optional null tests)
    scaffold_manifest         — manifest scaffolder

Private modules (underscore-prefix, no API stability guarantee):
    _classification, _measure, _manifest, _enrichment, _version

Each pass module is invocable both as `python3 -m stems_to_mixdown.<pass>`
and as `python3 stems_to_mixdown/<pass>.py`. The package import shim at the
top of each module bootstraps sys.path when invoked as a file.
"""
from ._version import __version__

__all__ = ["__version__"]

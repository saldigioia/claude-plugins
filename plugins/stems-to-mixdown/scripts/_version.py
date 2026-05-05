"""Version constant for stems-to-mixdown.

Imported by sidecar log emitters and any caller that wants to record which
version of the skill produced an artifact. Bump on tagged releases:

- 1.0.0  — first stable release (2026-05-05). Eighteen commandments, six
           passes (identify → import_pt_track_names → analyze → plan → mix →
           verify), shared scripts/_*.py infrastructure, fixtures-backed
           smoke + format-decision tests, sibling stems-from-mix skill.
- 1.1.0  — master-reference pipeline (Cmd 19). Optional source.master_reference
           manifest field (or --master CLI override) opts the run into a
           three-synced-versions reference-bundle deliverable: master +
           instrumental + acapella, all at identical rate / depth / duration.
           Pass 5 runs the reference battery (recombine null + two
           inverse-stems nulls + per-deliverable LUFS-I/dBTP deltas) when a
           master is present. Strict refusal on rate / depth / channels /
           duration mismatch — Cmd 19 forbids resampling, requantizing, or
           trimming the master to fit. analyze.json schema bumped to "3";
           plan.json schema bumped to "3".
"""

__version__ = "1.1.0"

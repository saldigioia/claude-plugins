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
- 1.2.0  — three operator-noticeable fixes. (1) Skill renamed from
           "stems-to-mixdown" to "mixdown" so the slash command is
           /stems-to-mixdown:mixdown instead of the visually-doubled
           /stems-to-mixdown:stems-to-mixdown. (2) Codec-driven lossy
           detection in discover.py — ALAC wrapped in m4a is now correctly
           classified as lossless instead of being silently capped to 16/44.1
           by a container-only check. (3) Master auto-detection: when a file
           in the stems folder matches a master pattern (master / final /
           released / reference / bounce_final) and doesn't classify as a
           stem, analyze.py uses it as the reference and excludes it from
           the stem walk. Plus a new scripts/run.py orchestrator that runs
           the whole pipeline end-to-end for the obvious case.
           identify.json schema bumped to "2" (adds stem_file_count and
           master_candidates fields).
"""

__version__ = "1.2.0"

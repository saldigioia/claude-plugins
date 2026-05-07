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
- 1.3.0  — three big behavior changes plus a doctrine revision.
           (1) Folder shape detection in identify.py — when --dir points at
           a project folder containing one audio subdirectory, run.py
           descends into it without prompting; identify.json schema bumped
           to "3". (2) Cmd 20 added: stereo is the deliverable, mono-stem
           panning is constant-power-curve normalized to the declared pan
           law, manifest `pan:` map and `--auto-pan` enable per-stem
           placement, and pseudo-stereo treatments are refused. (3) Cmd 9
           REVISED: the canonical deliverable now ships normalized to -14
           LUFS-I / -1 dBTP via two-pass loudnorm + alimiter; --archival
           preserves the v1.2 unity-sum behavior bit-for-bit. plan.json
           schema bumped to "4" with new `normalization`, `archival`, and
           `master_listening` fields. The reference bundle keeps using
           unity-sum internally (Cmd 19); a new <project>_master_listening
           file sits alongside the canonicals as a normalized A/B copy of
           the master.
"""

__version__ = "1.3.0"

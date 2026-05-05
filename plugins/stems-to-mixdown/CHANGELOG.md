# Changelog

All notable changes between the April 2026 prototype and the v1.1 release.
Dates are UTC. Each entry below maps to one or more commits on `main`; see
`docs/decisions/index.md` for the decision record per phase.

## [1.1.0] — 2026-05-05

Master-reference pipeline (Cmd 19). The released version of the song — the
master, as it appears on streaming or the physical release — can now be
declared as a reference, and the skill produces three perfectly synchronized
versions for A/B listening and null-test verification.

### Added

- **Commandment 19 — The master is the witness, not the source.** A new
  doctrine entry codifying the role of the user-supplied master: reference
  for verification, never for normalization, EQ, time-alignment, or
  loudness-targeting. The skill refuses to resample, requantize, or trim the
  master to fit; the operator fixes the master (or omits it) and re-runs.
- **`source.master_reference` manifest block** (`{path, duration_tolerance_samples}`).
  Relative paths resolve against the manifest dir. The master may live next
  to the stems — `discover.py` excludes the resolved master path from the
  stem walk so it is never mistaken for a stem.
- **`--master <path>` CLI flag** on `analyze.py` and `verify.py` — overrides
  the manifest field, useful for ad-hoc per-run references.
- **Reference-bundle deliverable.** When a master is present and Pass 2 is
  clean, Pass 3 plans a `reference-bundle/` containing
  `<project>_master.<ext>`, `<project>_instrumental.<ext>`, and
  `<project>_acapella.<ext>` — three perfectly synchronized files at the
  same rate / depth / channels. Master is copied byte-for-byte when the
  format already matches; otherwise the bundle copy (only) is re-encoded.
  Bundle dir gets a `bundle.log.md` sidecar with per-member SHAs and
  rationale.
- **Pass 5 reference battery.** When a master is present, `verify.py` runs
  three null tests:
  - `recombine`: `(instrumental + acapella) - master` → headline residual.
  - `inverse_acapella`: `(master - acapella) - instrumental` → diagnostic.
  - `inverse_instrumental`: `(master - instrumental) - acapella` → diagnostic.

  Plus per-deliverable LUFS-I and dBTP deltas vs the master (informational
  only; Cmd 9 still forbids normalization). Verdict thresholds match the
  existing null-test logic: pass ≤ -90 dBTP, smell -60 to -90, fail > -60.
- **`tests/fixtures/with-master/`** — three short stems plus a hand-crafted
  master (unity sum of the stems). The recombine null residual on this
  fixture is `-inf dBTP` (perfect mathematical null).
- **`tests/test_master_reference.sh`** — end-to-end assertions for all five
  master-reference behaviors: manifest probe, bundle planning, bundle
  execution, recombine-null pass, and Cmd-19 refusal on mismatched master.

### Changed

- **analysis.json schema bumped to `"3"`.** New top-level `master_reference`
  field (null when no master is declared).
- **plan.json schema bumped to `"3"`.** New top-level `reference_bundle`
  field (null when no master is declared); each group's `output_path` is
  unchanged.
- **Five new Pass 2 red flags.** `master_missing` (error),
  `master_rate_mismatch` (error), `master_depth_mismatch` (error),
  `master_channels_mismatch` (error), `master_multichannel` (error),
  `master_duration_mismatch` (error), `master_lossy_with_lossless_stems`
  (warn — bundle still proceeds with a lower expected null residual).
- `references/manifest-schema.md` documents the `source.master_reference`
  block and the parity rules.
- `references/commandments.md` adds §19.
- `scripts/_version.py` → `1.1.0`.
- `tests/run-all-passes.sh` filters `*-mixdowns/` and dot-dirs out of the
  fixture iteration so ad-hoc debug runs that leak output dirs into
  `tests/fixtures/` don't poison subsequent smokes.

### Migration

- Existing manifests without `source.master_reference` continue to work
  exactly as before (no bundle, no battery — the master path is opt-in).
- Baselines for the four pre-existing fixtures were regenerated against the
  schema-3 shape; the diffs are limited to the additive `master_reference`
  field on `analysis.json`. No mixdown audio bytes change for non-master
  runs.

## [1.0.0] — 2026-05-05

First stable release. Eighteen commandments, six passes, sibling skill, full
test infrastructure.

### Breaking changes

- **Default output directory.** `plan.py` now writes to
  `<source-dir>/../<source-name>-mixdowns/` instead of
  `<source-dir>/mixdowns/`. The legacy in-source layout is reachable via
  `plan.py --output-dir <source-dir>/mixdowns`. (P0-4 / Cmd 18)
- **Pro Tools intake renamed.** `scripts/import_session_info.py` →
  `scripts/import_pt_track_names.py`. Honest framing: this script borrows
  track names for classification; it does not reconstruct session timing.
  (P1-1)
- **Plan schema bumped to "2".** Each `plan.groups[].stem_shas` now records
  the analyze-time SHA-256 per input, used for SHA-anchored idempotency.
  (P0-3)
- **Manifest top-level keys validated.** Pre-flight in
  `_manifest.validate_manifest` warns on unknown top-level keys and
  out-of-range pan_law / compression_level / format. Recognized keys:
  `project, classifications, gains, groups, output, metadata, source,
  schema_version`.
- **FLAC output clamped to 24-bit.** When source-derived target_depth would
  be 32-bit, FLAC output clamps to 24 (the stable encoder ceiling); for
  genuine 32-bit deliverables, request `output.format: wav` or `aiff` in
  the manifest. (Surfaced by 24-in-32 fixture.)

### Audio correctness (Phase 1)

- **P0-1 Pan law explicit.** `output.pan_law` declared in manifest; default
  -3.0 dB (Logic / Cubase convention). Coefficient `K = 10 ** (pan_law/20)`
  applied per-channel on every mono→stereo upmix. `pan_law_default_assumed`
  Pass 2 warn fires when mono stems are present and the field is unset.
  Cmd 16 added.
- **P0-2 24-bit FLAC honesty.** `-bits_per_raw_sample 24` declared at
  encode time; `verify.py` probes the actual depth and fails when planned
  ≠ stored.
- **P0-3 SHA-anchored idempotency.** Live disk-content hashes plus
  filter-graph string → idempotency key recorded in sidecar. Replacing a
  file under the same name with different content correctly invalidates.
- **P0-4 Read-only source folder.** Default output dir moved out of the
  source. The one opt-in exception is `<source>/.s2m/metadata/` when
  `--bwf-report` is passed. Cmd 18 added.
- **P0-5 Section-anchored peak parsing.** `scripts/_measure.py` now
  tracks `True peak:` / `Sample peak:` section headers; never confuses
  the two even under `peak=true|sample`. Used by analyze, mix, plan,
  verify.

### Capability expansion (Phase 4)

- **`--preview`** (mix.py) — produces `<output>.preview.flac` via single-pass
  loudnorm I=-14 / LRA=11 / TP=-1.5. Not for delivery (Cmd 17 added);
  the canonical unity-sum is unchanged.
- **`--solo`** (mix.py) — bounces each stem individually through the
  canonical's pan-law / pre-atten / dither path. Outputs land in
  `<output>/qc/`. Useful for ear-checking without DAW access.
- **`scaffold_manifest.py`** — emits a starter `stems.manifest.yaml` from
  `analysis.json`. Pre-fills `classifications`; commented-out scaffolds for
  the rest. Refuses to overwrite without `--overwrite`.
- **Mono-fold compatibility check** (verify.py) — Cmd 6 honored. Reports
  `delta_lu = stereo_lufs_i - mono_fold_lufs_i` with a
  ≤3 / 3-6 / 6-12 / >12 LU verdict ladder. Info-only by default;
  `--check-mono-fold` escalates `mono_phase_warning` and `mono_phase_severe`
  to issues.
- **Per-platform loudness deltas** (verify.py) — informational deltas
  against Spotify / Apple Music / EBU R128 by default;
  `--report-all-platforms` adds Tidal / SoundCloud / Amazon Music /
  YouTube / ATSC A/85. Targets verified live 2026-05-05; constant table
  carries `LAST_VERIFIED`. **No normalization** (Cmd 9).
- **`stems_unanchored` warn** (Pass 2) — fires when `bext.time_reference`
  variance exceeds 1 sample across stems. Recommends DAW consolidation.
  Requires wavinfo.
- **Plain-English plan output** — every group leads with a "What this
  means" block of two-to-four prose bullets covering format consequence,
  pan-law consequence, pre-attenuation, manifest gain trims. Engineer
  detail follows.
- **Pass 2 consequence appendices** — five high-traffic warns
  (lossy_input, rate_mismatch, dc_offset, dead_channel,
  bit_depth_uncertain) now end with a `→ ...` plain-English consequence.
- **Manifest `output.compression_level` honored** — was documented since
  v0.1 but ignored by mix.py; now flows through plan to ffmpeg.

### Structural refactor (Phase 3)

- **Decomposed `analyze.py`** from 776 → 138 lines. Pass 1 now lives in
  `discover.py` (StemInfo, ffprobe, classify); Pass 2 in `sanity.py`
  (RedFlag, sanity_check); optional probes in `_enrichment.py`
  (wavinfo / mediainfo / bwfmetaedit).
- **Shared internal modules.** `_classification.py` (CLASSIFICATION_RULES,
  classify_by_filename), `_measure.py` (parse_ebur128_summary,
  parse_astats_dc_and_silence, tool_version), `_manifest.py` (load_manifest,
  validate_manifest, schema constants). Three drifting copies of
  CLASSIFICATION_RULES eliminated.
- **Bonus parser fix.** `parse_astats_dc_and_silence` was using `re.match`
  against `Channel:` / `DC offset:` / `RMS level dB:` lines, but ffmpeg
  prefixes every astats line with `[Parsed_astats_N @ 0x...]`, so the
  match never fired. Switched to `re.search` with `\b` anchors. The bug
  was inert on the original mono-stems fixture (no DC, no silence) but
  caught by the new dirty-inputs fixture.

### Validation infrastructure (Phase 3 + 7)

- **Four fixtures** under `tests/fixtures/`: mono-stems, mixed-rates,
  dirty-inputs, 24-in-32. Each with EXPECTED.md.
- **`tests/diff-baseline.sh`** — asserts byte-equivalence of analysis.json
  and plan.json against committed snapshots.
- **`tests/assert-audio-shas.sh`** — asserts decoded-audio MD5 of every
  FLAC output against `tests/baselines/expected-audio-md5s.txt`. Stable
  across days (file SHA isn't, because of the embedded date in COMMENT).
- **`tests/run-all-passes.sh`** — full pipeline smoke on every fixture.
- **`tests/test_format_decision.py`** — 17 table-driven cases covering
  the format-decision matrix. Runs under pytest or as a standalone script.

### Doctrine

- Eighteen commandments, ordered §1..§18, every one cited by at least one
  error message or rationale string. New in v1.0: §16 (pan law), §17
  (preview is not the deliverable), §18 (inputs are read-only).
- `docs/why.md` — one-page existence rationale: five things the skill
  insists on, five it refuses to do, what's adjacent, how to read the
  doctrine.
- Three-tier vocabulary surfaced in SKILL.md / README.md: technical rough
  mix / balanced demo mix / release-quality master (refused, Cmd 9).

### Provenance + research

- `docs/research/` — five Phase 2 notes: 2A pan-law math, 2B mono-fold
  policy, 2C reference-loudness landscape (live-verified 2026-05-05),
  2D demucs sibling spec (live-verified 2026-05-05), 2E alignment
  heuristics.
- `docs/decisions/index.md` — names the next-phase action triggered by
  each research item.
- `docs/decisions/2026-04-additions-review.md` — historical critique of
  the April 2026 additions; moved here from the repo root in 7.0.

### Sibling skill (Phase 6)

- `stems-from-mix/` — separate, optional skill that wraps `demucs
  htdemucs_ft` and emits a `stems.manifest.yaml` ready for
  `stems-to-mixdown` to consume. Renames demucs's `vocals.wav` /
  `drums.wav` to `vocal.wav` / `drum.wav` to match this skill's
  classification regex (which deliberately matches singular forms only).
  Three doctrine rules unique to separation (S1 bleed is real / S2 keep
  the original mix / S3 don't master separation outputs). Synthetic
  validation in `tests/test_handoff_and_verify.sh`. End-to-end run with
  real demucs + torch + MPS confirmed in commit `2dead4b`.

## [0.1] — pre-2026-05-05

Working prototype. Five passes, fifteen commandments, no tests, no
sibling skill, default output dir inside the source folder, idempotency
keyed on filename presence in sidecar. The full review of the v0.1
state is preserved at `REVIEW-2026-05.md`; the improvement plan that
guided every change since is at `IMPROVEMENT-PLAN.md`.

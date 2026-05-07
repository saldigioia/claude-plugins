# Changelog

All notable changes between the April 2026 prototype and the v1.3 release.
Dates are UTC. Each entry below maps to one or more commits on `main`; see
`docs/decisions/index.md` for the decision record per phase.

## [1.3.0] — 2026-05-07

Three behavior changes plus one doctrine revision. The default deliverable
is now a normalized listening master, the pipeline auto-descends into
project folders, and stereo output is codified as policy with a per-stem
manifest pan map.

### Doctrine

- **Cmd 9 revised — "Loudness normalization is not mastering — but the
  deliverable should be listenable."** The plugin now applies two-pass
  loudnorm to a streaming-compatible target (-14 LUFS-I default) plus a
  true-peak limiter (-1 dBTP default) on the canonical output. Mastering
  (creative EQ, compression, character) remains structurally out of scope.
  The unity-sum-only behavior is preserved bit-for-bit behind `--archival`
  (CLI) or `output.archival: true` (manifest). Decision recorded at
  `docs/decisions/2026-05-cmd-9-revision.md`.
- **Cmd 20 added — "Stereo is the deliverable. Mono is the source format.
  Don't decorate it."** Codifies that pseudo-stereo treatments (Haas-effect
  doubling, decorrelators, mid-side widening of mono inputs) are out of
  scope; mono stems are panned via constant-power curve + declared pan law
  (Cmd 16) and nothing else. Backed by the 2025–2026 consensus across
  Sound on Sound, Mastering The Mix, Mixing Monster, and the ISMIR
  mono-to-stereo literature; full citations in
  `docs/IMPROVEMENT-PLAN-v1.3.md` Phase 2.

### Added

- **`scripts/run.py` folder shape detection.** When `--dir` points at a
  project folder with no top-level audio but exactly one nested audio dir,
  identify descends silently. Multiple sibling audio dirs is the only
  surviving prompt path. New fields in `identify.json` (schema 3):
  `audio_locations`, `resolved_directory`, `resolution_reason`,
  `resolution_message`. New `--max-depth` flag on identify.py (default 3).
- **Default normalization pipeline.** `mix.py` now renders the unity sum
  to a 32-bit float intermediate, runs first-pass `loudnorm` to measure,
  then second-pass `loudnorm` (gain-only via `linear=true`) + `alimiter`
  (true-peak ceiling) + dither + encode. Sidecar `.log.md` records the
  unity-sum intermediate measurements, the loudnorm first-pass JSON, and
  the second-pass filter chain alongside the existing input/output blocks.
  Three new CLI flags on `plan.py` and `run.py`: `--archival` (opt out
  of normalization), `--target-lufs` (default -14, allowed -14/-16/-23),
  `--target-true-peak` (default -1.0, allowed -1.0/-1.5/-2.0). Manifest
  equivalents: `output.archival`, `output.target_lufs`,
  `output.target_true_peak`.
- **`<project>_master_listening.<ext>`.** When normalization is on AND a
  master is declared, the plugin produces a normalized version of the
  master alongside the canonical mixdowns. The `reference-bundle/`
  directory still contains the unity-sum master (Cmd 19) — null tests
  only work on un-normalized signals. `execute_master_listening` runs
  the same two-pass loudnorm pipeline against the original master file;
  the original master is never modified.
- **Manifest `pan:` map.** Per-stem placement: `pan: { vox.wav: 0,
  bgL.wav: -50, bgR.wav: 50 }`. Values are -100..+100; mono stems get
  the constant-power upmix at the requested position renormalized to the
  declared pan law. Stereo stems are not re-panned (Cmd 20); a
  `pan_on_stereo_ignored` warn fires when the manifest sets pan on
  stereo inputs.
- **`--auto-pan` flag (CLI + `output.auto_pan` manifest field).** Spreads
  N classified-the-same mono stems across the field; vocals and bass
  always center. Symmetric, max-width 0.7 to keep mono compatibility.
  Warn `mono_pile_at_center` (sanity.py) fires when ≥3 mono stems would
  otherwise sum to center and no `pan:` map is present.
- **Reference bundle re-renders unity-sum members from scratch.** When
  the canonical is normalized, `execute_reference_bundle` renders
  unity-sum versions of `instrumental` and `acapella` directly from each
  group's filter graph (instead of copying the canonical). When
  `--archival` is set the canonical IS unity-sum, so the bundle copies
  it as before. `verify.py`'s reference battery uses the bundle's
  unity-sum members for the recombine + inverse-stems nulls (with the
  canonical paths as fallback for `--archival` runs).
- **`tests/test_pan_distribution.py`** — pan-coefficient math + auto-pan
  distribution rule + manifest > auto > default precedence (5 case
  groups, ~25 individual assertions).
- **`docs/IMPROVEMENT-PLAN-v1.3.md`** — the planning document this
  release executes against.
- **`docs/decisions/2026-05-cmd-9-revision.md`** — the doctrine-revision
  record.

### Changed

- **`plan.json` schema bumped to "4".** Each group gains
  `normalization: { target_lufs, target_true_peak, lra_target, two_pass,
  method }` (or null for archival groups), `archival: bool`, `pan_map:
  { ... }`, `pan_source: "manifest" | "auto" | "manifest+auto" |
  "default"`. New top-level `master_listening` block (or null).
- **`identify.json` schema bumped to "3".** Adds `audio_locations`,
  `resolved_directory`, `resolution_reason`, `resolution_message`.
- **Skill description trimmed.** SKILL.md and `plugin.json` lead with
  the listening-master default.
- **Idempotency key incorporates normalization config + archival flag.**
  Flipping `--archival` or changing `--target-lufs` correctly invalidates
  the sidecar cache.
- **`tests/assert-audio-shas.sh`** runs the `--archival` path so the
  preserved v1.2 baselines still apply byte-for-byte.
- **Cmd 17 (`--preview`) is gone from `run.py`.** The canonical IS the
  listening copy now; `--preview` on `mix.py` directly is preserved for
  back-compat but the rationale is moot.

### Migration

- **Default audio bytes change.** Every fixture's canonical mixdown is
  now normalized; the v1.2 audio-MD5 baselines apply to `--archival`
  runs only. To restore the v1.2 default behavior on every run, set
  `output.archival: true` in `stems.manifest.yaml` or alias your
  invocation: `alias s2m='python3 .../run.py --archival'`.
- **Project folders just work.** `python3 scripts/run.py --dir
  ~/Music/some-song/` now descends into a single nested audio dir
  automatically; no need to point at the audio subdirectory directly.
- **The reference bundle is unchanged on disk** when `--archival` is
  set. When normalized, the bundle's `instrumental.flac` and
  `acapella.flac` are unity-sum re-renders from the original stems
  (byte-identical to what v1.2 would have produced) — only the canonical
  files outside the bundle are normalized.

## [1.2.0] — 2026-05-06

Three operator-noticeable bugs and one ergonomic gap closed in a single
release. Headline change: `scripts/run.py` collapses the six-pass workflow
into one command for the obvious case.

### Fixed

- **Slash-command listing duplication.** The skill was named
  `stems-to-mixdown` inside a plugin also named `stems-to-mixdown`, so
  Claude Code's command list rendered it as `/stems-to-mixdown:stems-to-mixdown`
  — the same word twice. Renamed the skill to `mixdown`; the slash command
  is now `/stems-to-mixdown:mixdown`. The skill folder moved from
  `skills/stems-to-mixdown/` to `skills/mixdown/`; the `${CLAUDE_SKILL_DIR}/../../scripts/`
  pattern is unchanged because the parent-of-parent still resolves to the
  plugin root.
- **m4a was always assumed lossy AAC.** `discover.py` used a container-only
  check (`container in {mp3, aac, ogg, m4a, opus}`) that flagged every
  `.m4a` as lossy. Apple Lossless (ALAC) wraps in m4a too, and would get
  silently capped to 16/44.1 by the format-decision matrix. Replaced with
  a codec-driven `infer_lossy(codec, container)` helper that explicitly
  recognizes lossless codecs (`alac`, `flac`, `pcm_*`, `wavpack`, `tta`,
  `mlp`, `truehd`, etc.) and treats container as a last-resort hint only.
  ALAC-in-m4a now correctly preserves its native rate / depth in the
  output. New tests in `tests/test_codec_detection.py`.
- **Master sitting next to the stems was either summed or ignored.** The
  CLI / manifest paths to declare a master existed but neither was
  auto-discoverable. Added `looks_like_master(filename)` in
  `_classification.py` (matches `master`, `final`, `released`,
  `reference`, `bounce_final`; refuses filenames that classify as a stem).
  `identify.py` surfaces detected candidates in `master_candidates` (schema
  bumped to "2"). `analyze.py` auto-uses a single candidate when neither
  `--master` nor `manifest.source.master_reference.path` is set; multiple
  candidates → refusal (Cmd 19 — never guess about the witness). New
  `--no-auto-master` flag opts out.

### Added

- **`scripts/run.py` — one-shot orchestrator.** Runs identify → (optional
  PT intake) → analyze → plan → mix → verify in a single command, with
  sensible defaults at every step. Stops on red flags (`--force` to
  proceed), prompts for plan approval (`--yes` to skip). All intermediate
  JSON lands in `<output-dir>/.s2m/run/` for inspection. Forwards
  `--master`, `--preview`, `--solo`, `--check-mono-fold`,
  `--report-all-platforms`, and `--bwf-report` to the right per-pass
  scripts.

### Changed

- **`identify.json` schema bumped to "2".** Adds top-level
  `stem_file_count` and `master_candidates` fields. Naming-quality scoring
  now runs against stems only (the master, if any, is excluded from the
  ratio so a single master file doesn't flip a folder of well-named stems
  to "ambiguous").
- **Plugin description trimmed.** The long-form trigger phrasing moved
  from `plugin.json` into the SKILL.md description; the plugin description
  is now a one-paragraph summary that reads cleanly in marketplace
  listings. Same content, less noise per surface.
- **`scripts/_version.py` → `1.2.0`.**
- **Cross-skill reference in `stems-from-mix/SKILL.md`** updated to invoke
  `/stems-to-mixdown:mixdown` (was `/stems-to-mixdown:stems-to-mixdown`).

### Migration

- Existing manifests, fixtures, and per-pass invocations work unchanged.
  The old SKILL.md path (`skills/stems-to-mixdown/SKILL.md`) is gone;
  Claude Code installs the plugin against the new layout automatically on
  next `/plugin update`.
- ALAC files that used to be capped to 16/44.1 will now produce
  higher-rate/-depth output. This is a fidelity fix, not a regression — re-run
  `analyze.py` against any folder containing m4a inputs to see the new
  format decision.
- Folders that contained an obvious-master file (`master.flac`, `final.wav`,
  etc.) and were previously summing it as a stem will now pick it up as the
  reference. The canonical mixdown bytes change because the file is no
  longer in the stem set; the new `reference-bundle/` directory appears
  alongside. Pass `--no-auto-master` to restore the old behavior on a
  per-run basis.

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

# `stems-to-mixdown` — improvement plan

> **SUPERSEDED 2026-05-08.** Phase 6 of this plan calls for a `stems-from-mix` sibling skill (demucs wrapper). That direction was rejected; source separation from a finished mix is out of scope for this plugin by design. See `docs/decisions/index.md` ADR 2D. Phase 6 and the ADR-style "2D — Demucs as a sibling skill" section are dead. The plan is preserved as a historical artifact for the other phases that did ship.

_End state: a highly-opinionated, capable Claude skill that an archivist would trust with irreplaceable multitracks and a non-expert mixer can drive without learning ffmpeg. Reference document: `REVIEW-2026-05.md`._

This plan is sequenced for safe application. Phase 1 fixes audio defects. Phase 2 is research that informs Phase 3+. Phases 3 and 4 reshape the codebase. Phase 5 sharpens the doctrine. Phase 6 is an optional sibling skill. Phase 7 ships v1.0.

Phases are not interchangeable — each unblocks the next. Parallel work inside a phase is fine; jumping phases is not.

---

## Phases at a glance

| Phase | Goal | Type | Blocks |
|---|---|---|---|
| 1. Defect remediation | Fix audio-correctness bugs (pan law, 24-bit FLAC, idempotency, output dir, peak parsing) | Implementation | All later phases |
| 2. Targeted research | Resolve five open questions before reshaping or expanding | Research | Phases 3, 4, 5 |
| 3. Reconfiguration | Decompose `analyze.py`, extract shared modules, add fixtures and CI smoke tests | Refactor | Phase 4 |
| 4. Capability expansion | Manifest scaffolding, preview deliverable, loudness reporting, solo / QC bounce, alignment tools | Feature | Phase 5 |
| 5. Opinionation deepening | New commandments, terser voice, plain-English plan output, refusal sharpening | Doctrine | Phase 7 |
| 6. Sibling skill (optional) | `stems-from-mix` (demucs wrapper) as a separate skill that hands off cleanly | Feature | — |
| 7. Validation and v1.0 | Test fixtures pass, README polished, CHANGELOG, version stamp, release | Ship | — |

The shape is: **fix → ask → restructure → extend → sharpen → split off → ship.**

---

## Cross-cutting policies (apply to every phase)

1. **No phase ships without passing the validation block defined in its own section.** "It compiles" is not a pass.
2. **Schema-version every JSON shape.** If `analysis.json`, `plan.json`, or `identify.json` change shape, bump `schema_version` and document the change in `docs/decisions/`.
3. **One commit, one P-item.** Don't bundle P0-1 and P1-2 into the same commit; bisect needs single-purpose commits.
4. **Soft-import discipline.** No phase introduces a hard dependency. Optional probes stay optional. The plugin must produce a valid mixdown with only `ffmpeg`, `ffprobe`, and Python 3.10+ installed.
5. **Doctrine is part of the deliverable.** Any new behavior gets an updated `commandments.md` entry and a one-line rationale in the relevant reference. Code without doctrine is undocumented opinion.
6. **The inputs are sacred.** No phase may write into the user's source folder by default. The default output path lives outside it.
7. **Voice consistency.** Stderr messages and plan rationales follow the existing terse-engineer tone. New copy goes through a tone pass before merge.

---

## Phase 1 — Defect Remediation

### Goal

Make the audio output trustworthy. After this phase, the skill's mixdown of a mono-stems-centered fixture nulls against a Pro Tools bounce within dither noise, 24-bit FLAC outputs report `bits_per_raw_sample=24`, re-runs are correctly idempotent, and the source folder is never written into by default.

### Inputs

- `REVIEW-2026-05.md` §7.1 (P0-1 through P0-5).
- All existing scripts and references.
- The implementation prompt at `REVIEW-2026-05.md` §8.

### Implementation

1. **P0-1: Pan law.** `output.pan_law` field, default `-3.0`, applied as a coefficient in `pan` filter, surfaced in plan and sidecar, with a `pan_law_default_assumed` warn when mono stems present and field unset.
2. **P0-2: 24-bit FLAC honesty.** `-bits_per_raw_sample 24` to encoder; verify pass added to Pass 5.
3. **P0-3: SHA-anchored idempotency.** Plan embeds input SHAs from analysis; mix.py's idempotency key is `sha256(joined_input_shas + filter_graph)`.
4. **P0-4: Default output dir outside input dir.** `directory.parent / f"{directory.name}-mixdowns"` as default; `--output-dir` keeps existing override.
5. **P0-5: Robust ebur128 parsing.** New `scripts/_measure.py` with `parse_ebur128_summary(stderr) -> dict`; a `True peak:` section guard; all four scripts switched to it.

### Validation

```bash
# Pan law: mono fixture nulls against PT bounce within dither noise
python3 scripts/identify.py --dir tests/fixtures/mono-stems > /tmp/i.json
python3 scripts/analyze.py  --dir tests/fixtures/mono-stems > /tmp/a.json
python3 scripts/plan.py     --analysis /tmp/a.json > /tmp/p.json
python3 scripts/mix.py      --plan /tmp/p.json --yes
python3 scripts/verify.py   --plan /tmp/p.json --reference tests/fixtures/mono-stems-pt-bounce.flac
# Expect: null_test verdict == "pass" (residual <= -90 dBFS)

# 24-bit FLAC honest at the file
ffprobe -v error -show_entries stream=bits_per_raw_sample $(jq -r '.groups[0].output_path' /tmp/p.json)
# Expect: 24, not 32

# Idempotency
python3 scripts/mix.py --plan /tmp/p.json --yes  # second run → "skipped"
touch tests/fixtures/mono-stems/kick.wav
python3 scripts/mix.py --plan /tmp/p.json --yes  # → "ok" (re-mixed)

# Output dir
test "$(jq -r .output_directory /tmp/p.json)" != "$(jq -r .directory /tmp/p.json)/mixdowns"

# Peak parsing
# Manually edit one ebur128 invocation to peak=true|sample, run, confirm True peak still extracted
```

### Risks

- Pan-law fixture requires a Pro Tools bounce reference. If you can't produce one quickly, generate a synthetic reference: a single mono sine at known amplitude, summed at center via Pro Tools (or any reference mixer with documented pan law), and check the dB delta against your skill's output.
- Idempotency change touches `plan.json` schema. Bump `schema_version` from `"1"` to `"2"` and add a top-level `previous_schema_compatible: true` field if the new fields are additive only.

### Definition of done

All five P0 fixes merged with passing validation. Old behavior is no longer reachable without explicit flags. `commandments.md` has new §16 entry on pan law.

---

## Phase 2 — Targeted Research

### Goal

Five small, well-scoped investigations whose answers shape Phase 3+. Each research item produces a one-page note in `docs/research/` and a decision recorded in `docs/decisions/`. No code changes in this phase.

### Sequencing

Research items 2A through 2E can run in parallel. Each is bounded to ~half a day. None touches the codebase. The output is decision documents.

### 2A — Pan-law coefficient verification across DAWs

**Question.** Is `coef = 10 ** (pan_law / 20)` the universally-correct mapping from "pan-law dB" to "per-channel gain coefficient when summing mono to center"? Or do specific DAWs use a different curve (sin/cos law vs square-root law)?

**Method.**
1. Bounce a single mono sine wave at -12 dBFS through Pro Tools at each pan-depth setting (-2.5, -3.0, -4.5, -6.0). Measure the resulting stereo file's L and R peak.
2. Repeat in Logic Pro X (defaults to -3 dB).
3. Repeat in REAPER (configurable; test 0, -3, -6).
4. Compute the actual per-channel coefficient implied by each measurement.
5. Compare against `10 ** (pan_law / 20)`.

**Deliverable.** `docs/research/2A-pan-law-coefficients.md` with a table of measured vs predicted coefficients per DAW, and a recommended formula. If different DAWs disagree, document the spread and pick the most-conservative default.

**Decision triggered.** Confirms (or refutes) the coefficient formula in the Phase 1 P0-1 fix. May require a follow-up patch.

### 2B — Mono-fold and phase-coherence policy

**Question.** Commandment 6 promises a mono-fold measurement in Pass 5 that doesn't exist. Either implement it or remove the promise. What's the right policy?

**Method.**
1. Read prior art: how does iZotope RX, Insight, or Sonarworks SoundID Reference report mono-compatibility?
2. Decide on a metric. Candidates:
   - Stereo-to-mono-fold dBTP delta (loudness-weighted via ebur128).
   - Per-band mono-correlation across [20–80, 80–250, 250–2k, 2k–8k, 8k–20k] Hz.
   - Goniometer-style left/right correlation coefficient.
3. Pick one (or two) metrics with cheap ffmpeg implementations.
4. Decide thresholds: warn vs error.

**Deliverable.** `docs/research/2B-mono-fold-policy.md` with the chosen metric(s), the ffmpeg invocation, and the threshold table.

**Decision triggered.** Phase 4 implements (or removes) the mono-fold check, depending on this output.

### 2C — Reference-loudness landscape

**Question.** The plugin refuses to normalize. But users still want to know "how does this output compare to Spotify's -14 LUFS-I target." What loudness deltas should the plan and verify output report?

**Method.**
1. Compile platform targets as of 2026: Spotify, Apple Music, YouTube, Tidal, SoundCloud, Amazon Music, broadcast (R128/-23, ATSC/-24).
2. Decide which to surface. Spotify and Apple Music are non-negotiable. Broadcast is a different audience.
3. Decide presentation. Per-platform delta lines? A single "approx -3.5 LUFS hot for streaming" callout?

**Deliverable.** `docs/research/2C-reference-loudness.md` with a table of platforms and their targets, plus a recommended report format. **No normalization.** The plugin remains a measurement-only stance (Commandment 9).

**Decision triggered.** Phase 4 adds informational loudness deltas to the plan and verify output.

### 2D — Demucs as a sibling skill

**Question.** Sal's stated frustration includes "I can't share remixes because mixing is hard." Half the time this means "I have a finished song and I want stems out of it." That's a separation problem, not a mixing problem. Should there be a sibling skill that wraps demucs and hands off to `stems-to-mixdown`?

**Method.**
1. Re-confirm demucs htdemucs_ft as the right model (Phase 1 review already established this).
2. Decide CPU-vs-GPU policy. CPU is ~10× slower but always available.
3. Decide output naming convention. The downstream `stems-to-mixdown` regex needs `vox`/`drums`/`bass`/etc. in the filename. Demucs emits `vocals.wav`, `drums.wav`, `bass.wav`, `other.wav` by default — close, but `vocals` doesn't match the `vox|vocal` regex without extending it. Either rename on output or extend the regex. Pick one.
4. Decide on hand-off contract. Does the sibling skill write `stems.manifest.yaml` for the downstream skill? Yes — the classifications are known, no guessing required.
5. Decide on packaging. Separate plugin in its own folder? Same `.claude/skills/` install? Document.

**Deliverable.** `docs/research/2D-demucs-sibling.md` with a model decision, a naming convention, a hand-off manifest schema, and an install path.

**Decision triggered.** Phase 6 (optional) builds the sibling skill against this spec.

### 2E — Stem alignment heuristics

**Question.** When stems come from a session (not a DAW bounce), they may have different `bext.time_reference` values, indicating different timeline offsets. The current pipeline assumes shared anchors. Can a Pass 2 warning detect the mismatch and suggest consolidation?

**Method.**
1. Read up on `bext.time_reference` semantics: it's a 64-bit sample count from session time-zero, present on BWF files exported from PT/Logic/Cubase.
2. Decide threshold: how much cross-stem variance is "different anchors" vs "rounding noise"? Likely > 1 sample.
3. Decide reporting: a Pass 2 `stems_unanchored` warn that recommends consolidation.

**Deliverable.** `docs/research/2E-alignment-heuristics.md` with the threshold, the message text, and the wavinfo accessor for `time_reference`.

**Decision triggered.** Phase 4 adds the warning to `sanity_check`.

### Phase 2 definition of done

Five `docs/research/*.md` files committed, plus a `docs/decisions/` index that names the next-phase action triggered by each.

---

## Phase 3 — Reconfiguration

### Goal

Make the codebase pleasant to extend. After this phase, `analyze.py` is no longer 834 lines, classification rules live in one place, all four ebur128 parsers share code, and a fixtures-backed smoke test runs end-to-end.

### Inputs

- Phase 1's stable foundation.
- `REVIEW-2026-05.md` §6.1, §6.2, §5.9.

### Implementation

#### 3.1 Shared modules

Extract three internal modules into `scripts/_*.py`:

| Module | Owns | Imported by |
|---|---|---|
| `scripts/_classification.py` | `CLASSIFICATION_RULES`, `classify_by_filename`, `_normalize` | `analyze.py`, `identify.py`, `import_pt_track_names.py` |
| `scripts/_measure.py` | `parse_ebur128_summary`, `parse_astats_dc_offset`, `parse_astats_silent_channels`, `tool_version` | `analyze.py`, `mix.py`, `plan.py`, `verify.py` |
| `scripts/_manifest.py` | `load_manifest`, `validate_manifest`, manifest schema constants | `analyze.py`, `import_pt_track_names.py`, `scaffold_manifest.py` (Phase 4) |

Underscore prefix signals "internal to this skill," not for external import.

#### 3.2 Decompose `analyze.py`

Split the current 834-line file into three modules:

| Module | Responsibility | Approx LoC |
|---|---|---|
| `scripts/discover.py` | `StemInfo` dataclass, file walking, ffprobe wrapping, classification application | 250 |
| `scripts/sanity.py` | `RedFlag` dataclass, all sanity checks, plain-English consequence appendices (P1-5) | 250 |
| `scripts/_enrichment.py` | `enrich_with_wavinfo`, `mediainfo_probe`, `run_bwfmetaedit_report` | 250 |

`scripts/analyze.py` becomes a thin orchestrator: parse args → call discover → call enrich → call sanity → emit JSON. ~80 lines.

This is mechanical, not conceptual. Behavior must not change.

#### 3.3 Test fixtures

Create `tests/fixtures/` with at least four scenarios:

| Fixture | Purpose |
|---|---|
| `tests/fixtures/mono-stems/` | Three mono WAVs at the same rate/depth — exercises pan-law upmix |
| `tests/fixtures/mixed-rates/` | One 96 kHz lossless + one 44.1 kHz lossy — exercises rate-mismatch + lossy-cap path |
| `tests/fixtures/dirty-inputs/` | One stem with DC offset, one fully silent — exercises sanity warnings |
| `tests/fixtures/24-in-32/` | One 24-in-32 WAV (manually crafted with `ffmpeg -bits_per_raw_sample 24`) — exercises wavinfo gating |

Each fixture has an `EXPECTED.md` documenting what passes / warnings / errors should appear. Each fixture is small (< 1 MB).

#### 3.4 Smoke test

`tests/run-all-passes.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
for fix in tests/fixtures/*/; do
  rm -rf "${fix%/}-mixdowns" "${fix}analysis.json" "${fix}plan.json"
  python3 scripts/identify.py --dir "$fix"  > /dev/null
  python3 scripts/analyze.py  --dir "$fix"  > "${fix}analysis.json" || true
  python3 scripts/plan.py     --analysis "${fix}analysis.json" > "${fix}plan.json" || true
  python3 scripts/mix.py      --plan "${fix}plan.json" --yes || true
  python3 scripts/verify.py   --plan "${fix}plan.json" || true
done
echo "All fixtures exercised."
```

This is a **smoke test, not a correctness test.** Phase 7 adds correctness assertions on output SHAs.

#### 3.5 Table-driven format-decision tests

`tests/test_format_decision.py`:

```python
# All cases covered by the matrix in references/format-decisions.md.
CASES = [
    # (name, stem_specs, expected_format, expected_rate, expected_depth, expected_lie)
    ("all_lossless_uniform_24_48k", [...], "flac", 48000, 24, False),
    ("mixed_depths_smallest_wins", [...], "flac", 48000, 16, False),
    ("mixed_rates_highest_wins", [...], "flac", 96000, 24, False),
    ("any_lossy_caps_to_44k_16", [...], "flac", 44100, 16, False),
    ("manifest_force_24_from_lossy", [...], "flac", 44100, 24, True),
    ("manifest_force_higher_rate", [...], "flac", 96000, 24, True),
    ("all_lossy_mp3_target", [...], "mp3", 44100, 0, False),
]
```

Run via `python3 -m pytest tests/test_format_decision.py`.

### Validation

```bash
# Module extraction didn't change behavior
diff <(python3 scripts/analyze.py --dir tests/fixtures/mono-stems) <(git show HEAD~1:- python3 scripts/analyze.py --dir tests/fixtures/mono-stems)
# (Conceptually — actually run before/after and diff the JSON outputs)

# Smoke test passes
bash tests/run-all-passes.sh

# Format-decision matrix
python3 -m pytest tests/test_format_decision.py -v
```

### Risks

- The `analyze.py` decomposition is the most invasive change. Do it as one PR with **before-and-after `analysis.json` snapshots committed**, so reviewers can verify byte-equivalence on the fixtures.
- Test fixture WAVs need to be tiny (a few hundred milliseconds, single tone). `ffmpeg -f lavfi -i sine=frequency=440:duration=0.5 -c:a pcm_s24le tests/fixtures/mono-stems/sine_440.wav` is the pattern.

### Definition of done

Three `_*.py` modules exist and are imported. `analyze.py` is < 100 lines. `tests/fixtures/` has four scenarios. `tests/run-all-passes.sh` and `tests/test_format_decision.py` exist and pass. JSON outputs are byte-equivalent to pre-refactor outputs on the fixtures.

---

## Phase 4 — Capability Expansion

### Goal

Add the features that turn a unity-sum tool into a useful daily driver: manifest scaffolding, preview deliverable, loudness reporting, solo / QC bounces, alignment-warning, and `--dry-run` with a manifest-only output. After this phase, a non-expert mixer can drive the skill from `~/Music/some-track-stems/` to a deliverable + a listening copy + a per-platform loudness report without writing a manifest by hand.

### Inputs

- Phase 2 research outputs (2B mono-fold, 2C loudness, 2E alignment).
- Phase 3's shared modules.
- `REVIEW-2026-05.md` §7.2 (P1-1 through P1-5) and §7.3 (P2-1, P2-5).

### Implementation

#### 4.1 Pro Tools intake re-pitch (P1-1)

Rename `scripts/import_session_info.py` → `scripts/import_pt_track_names.py`. Update `identify.py`'s `next_command`. Update `SKILL.md` and `README.md` framing. Keep `stems.session.yaml` sidecar.

#### 4.2 Plain-English plan output (P1-2)

In `plan.py:render_plan_markdown`, prepend each group's section with a "What this means" block — three plain-prose bullets summarizing loudness-vs-DAW-bounce, format-choice reason, and per-stem operations. Engineer detail follows underneath.

#### 4.3 Manifest scaffolding (P1-3)

`scripts/scaffold_manifest.py --analysis analysis.json --out stems.manifest.yaml [--overwrite]`:

- Pre-fills `classifications` from analysis.json.
- Writes `groups`, `gains`, `output`, `metadata` as **commented-out scaffolds** with example values, so the user just uncomments and edits.
- Refuses to overwrite without `--overwrite`.

Manifest written this way is immediately consumable by `analyze.py` (the commented-out blocks are no-ops).

#### 4.4 Preview deliverable (P1-4)

Add `--preview` to `mix.py`. When set, produces an additional `<project>_<group>.preview.flac` per group via single-pass `loudnorm=I=-14:LRA=11:TP=-1.5`.

The preview's sidecar log opens with: **"PREVIEW — for headphone listening, not for delivery. The canonical mixdown is the unity-sum FLAC alongside this file."**

`commandments.md` §17: "The preview is not the deliverable."

#### 4.5 Pass 2 consequence appendices (P1-5)

For each warn/error in `sanity.py`, append a one-line "→ ..." consequence (per `REVIEW-2026-05.md` §7.2 P1-5).

#### 4.6 Mono-fold check in Pass 5 (P2-5, gated on Phase 2B)

Implement the metric chosen in 2B. Add to `verify.py` as an info-only stat (not a fail) by default; gated behind `--check-mono-fold` for stricter use.

#### 4.7 Loudness-platform report (gated on Phase 2C)

After every Pass 5 run, print a delta table per output:

```
acapella.flac — output LUFS-I: -18.3
  vs Spotify (-14):    -4.3 LU (quieter; OK for streaming after mastering)
  vs Apple Music (-16): -2.3 LU
  vs YouTube (-14):    -4.3 LU
  vs Broadcast EBU R128 (-23): +4.7 LU (hot for broadcast)
```

Printed informationally. **The skill still does not normalize.**

#### 4.8 Stems-alignment warn (gated on Phase 2E)

Add `stems_unanchored` warn to `sanity.py` when cross-stem `bext.time_reference` variance exceeds the Phase 2E threshold. Message recommends Pro Tools' Edit → Consolidate as the fix.

#### 4.9 `--solo` / per-stem QC bounce

Add `mix.py --solo`: bounces each stem individually through the same format-decision and dither path. Outputs land at `mixdowns/qc/<project>_<stemname>.flac`. Useful for engineer ear-checking without DAW access.

#### 4.10 Honor `output.compression_level`

`mix.py` currently hardcodes FLAC `-compression_level 8`. Manifest's `output.compression_level` field is documented but unused. Wire it.

### Validation

```bash
# Scaffolding produces a usable manifest in one command
python3 scripts/scaffold_manifest.py --analysis tests/fixtures/mono-stems/analysis.json --out /tmp/m.yaml
test -f /tmp/m.yaml
python3 scripts/analyze.py --dir tests/fixtures/mono-stems  # reads the manifest cleanly

# Preview deliverable
python3 scripts/mix.py --plan /tmp/p.json --yes --preview
ls tests/fixtures/mono-stems-mixdowns/*.preview.flac

# Loudness report present
python3 scripts/verify.py --plan /tmp/p.json | grep -E "Spotify|Apple Music|YouTube"

# Solo bounce
python3 scripts/mix.py --plan /tmp/p.json --yes --solo
ls tests/fixtures/mono-stems-mixdowns/qc/

# Plain-English plan
python3 scripts/plan.py --analysis /tmp/a.json | grep -B1 -A3 "What this means"
```

### Risks

- `loudnorm` single-pass is only approximately on-target; double-pass gives better results but adds a probe pass. Single-pass is fine for a preview and clearly labeled as such.
- Loudness-platform deltas could be misread as a target. The "what this means" prose must be unambiguous: **deltas are reference, not aspirations.**

### Definition of done

All P1 items shipped. Phase 2 research items 2B, 2C, 2E have triggered concrete features. `--solo` and `--preview` work. Manifest scaffolding works. Plan output reads as English first, engineering second.

---

## Phase 5 — Opinionation Deepening

### Goal

The plugin's voice is what makes it useful for archival work. After this phase, every error message is shorter and more direct, every refusal cites its rule, and the doctrine answers "why" before "how" everywhere it matters.

### Inputs

- All previous phases.
- The current `commandments.md` (15 entries).
- The voice section of `SKILL.md`: "an engineer who's seen too many 'make it louder' sessions. Terse. Technical. Will explain *why* once. Won't apologize for refusing to upsample."

### Implementation

#### 5.1 New commandments

Three doctrine entries earned by the work:

- **§16 — Pan law is a choice. Declare it.** "Mono summed to stereo at 0 dB pan law is +3 dB louder than the same content centered through any DAW. Pan law is a session decision, not a default. The manifest declares it; the skill applies it; the sidecar records it; the plan calls out the consequence."
- **§17 — The preview is not the deliverable.** "Loudness-normalized previews exist for headphone listening. The canonical mixdown is the unity-sum file. If a preview ever ships in place of a deliverable, that's a process failure upstream, not the preview's fault."
- **§18 — Inputs are read-only.** "The skill writes outputs to a sibling directory. The source folder is never modified, never recursively scanned by default, never assumed safe to mutate. An archival mixdown that rewrites the source is not an archival mixdown."

#### 5.2 Voice audit

Pass over every stderr message and every plan-markdown rationale string. Cuts:

- "the skill" → "this" (in conversational copy) or implied subject (in directive copy).
- Overlong rationale strings split into a one-line consequence + a doctrine-pointer.
- Apologetic phrasing (`"unfortunately,"` `"please note"`) excised.
- Repeated explanations consolidated into a single canonical line in the relevant reference file, with the script citing the reference.

Example before:
```
[warn] Lossy inputs present (2 file(s)). Default output will be 16-bit / 44.1 kHz FLAC.
```

Example after:
```
[warn] Lossy in chain — output capped at 16/44.1 FLAC. (Cmd 1, Cmd 8)
```

#### 5.3 Refusal sharpening

Every refusal cites its rule. Every override path is named:

- Refuse multichannel: `[error] Multichannel input — out of scope. Downmix first; this skill sums stereo. (Cmd: out of scope)`
- Refuse upgrade beyond source: `[error] Refused: 24-bit FLAC out from MP3-in-chain. The source is the ceiling. Override: --lie. (Cmd 1)`

#### 5.4 Three-tier vocabulary surface

Add to `SKILL.md` and `README.md`:

> This skill produces **technical rough mixes** (unity-sum, no creative processing). With per-stem manifest gain trims it produces **balanced demo mixes**. It does not produce **release-quality masters** — that's a separate stage with its own tools and decisions.

Show the three tiers in a small table at the top of `SKILL.md`. Each row links to the relevant commandment.

#### 5.5 The "why this skill exists" doc

New `docs/why.md` (~one page). Opens with: "This exists because most stem-summing tools either default to normalization (which destroys gain decisions) or default to lossy intermediate (which destroys headroom). This is the conservative third option."

Lists the five things the skill insists on (unity sum, source ceiling, dither when reducing, true-peak measurement, sidecar provenance) and the five things it refuses to do (normalize, upsample, re-encode lossy hot, write into source, embed invented metadata).

Every commandment number appears in `why.md` exactly once, as a footnote pointing to `commandments.md`.

#### 5.6 Plan rationale sharpening

Per-group rationale strings in `plan.py:decide_output_format` are currently full sentences. Tighten:

```
# Before
"Mixed input rates ([44100, 96000]). Targeting highest common rate (96000 Hz) — upsampling existing samples is non-destructive; downsampling discards. Smallest common bit depth (24-bit)."

# After
"Mixed rates: 44.1k, 96k → 96k (highest common, no destructive resample). Depth: 24-bit (smallest common). Cmd 1 + 4."
```

The doctrine pointer at the end is the contract: details live in `commandments.md`, not in the plan.

### Validation

- Read every stderr message in every script aloud. If any sounds apologetic or wordy, rewrite.
- Diff plan output before/after on a fixture. Word count should drop ≥ 30%; comprehension should be unchanged or higher.
- `commandments.md` has 18 entries. Each is referenced by at least one error message or plan rationale.

### Definition of done

`docs/why.md` exists. New commandments §16, §17, §18 in `commandments.md`. Voice pass merged. Plan and stderr language is consistently terse and cites doctrine.

---

## Phase 6 — Sibling Skill (optional)

### Goal

Address the "I don't have stems, I have a finished song" use case via a separate, narrowly-scoped skill that wraps demucs and hands off cleanly to `stems-to-mixdown`. Keep `stems-to-mixdown` itself focused.

This phase is optional. Skip if Sal hasn't hit the "want stems from a mix" wall recently, or if GPU/CPU time isn't available.

### Inputs

- Phase 2D research output.
- demucs documentation and the htdemucs_ft model.

### Implementation

#### 6.1 Skill scaffold

`stems-from-mix/` (separate repo or sibling folder; not nested inside `stems-to-mixdown/`):

```
stems-from-mix/
├── SKILL.md
├── README.md
├── scripts/
│   ├── separate.py        # Wraps `demucs` CLI, writes vox/drums/bass/other.wav
│   ├── verify.py          # Confirms separation didn't introduce clipping
│   └── handoff.py         # Writes a stems.manifest.yaml ready for stems-to-mixdown
└── references/
    ├── model-choice.md    # Why htdemucs_ft, not spleeter
    └── separation-limits.md  # Honest about what bleeds and why
```

#### 6.2 Hand-off contract

`stems-from-mix` writes the demucs output into `<song>-stems/` and emits a `stems.manifest.yaml` with `classifications` filled in (no guessing — the model knows what it produced). The user then points `stems-to-mixdown` at that folder and gets a clean acapella / instrumental.

The two skills share no code. They share a contract: the manifest schema and the regex names.

#### 6.3 Doctrine for separation

Three commandments unique to `stems-from-mix`:

- "Separation is approximation. Bleed is real. Don't paper over it."
- "Always keep the original mix file. Separated stems are derivatives, not sources."
- "If the separation result has visible audio artifacts in a spectrogram, the model is wrong for the material. Try a different one."

#### 6.4 Validation

- A 30-second test track with a known acapella (e.g., a song with a publicly-available a cappella version) gets separated; the demucs vocals output null-tested against the published acapella; residual recorded.
- `stems-from-mix` → `stems-to-mixdown` round-trip on the same input produces an instrumental that nulls reasonably against `(original) - (acapella)`.

### Risks

- demucs is large (model weights ~ hundreds of MB). Document the install footprint.
- Separation quality varies wildly with material. Document this honestly in `references/separation-limits.md`.

### Definition of done

`stems-from-mix` skill exists, installs cleanly, separates a test song, hands off to `stems-to-mixdown`, and documents what it can't do as honestly as what it can.

---

## Phase 7 — Validation and v1.0

### Goal

Ship `stems-to-mixdown` v1.0. After this phase, anyone with the workspace folder can install the skill, point it at stems, and trust the output.

### Implementation

#### 7.1 Correctness assertions

Extend `tests/run-all-passes.sh` to assert output SHAs against committed expectations on the fixtures. Re-running the pipeline must produce byte-identical FLAC output (modulo dither randomness — pin the dither seed if needed; ffmpeg's `aresample` dither is deterministic given identical input).

#### 7.2 README polish

- One-paragraph "what is this" at the top.
- Three-tier vocabulary table.
- Quick-start (5 commands or fewer).
- Honest scope: what it does, what it refuses, what's adjacent (`stems-from-mix`).
- Install matrix for optional tools, per OS.

#### 7.3 CHANGELOG

`CHANGELOG.md` from v0.1 (current state) through v1.0 (after this plan). Note breaking changes (output dir default, schema versions).

#### 7.4 Version stamp

Add `__version__ = "1.0.0"` to a new `scripts/_version.py`. Sidecar logs include the version.

#### 7.5 Pre-release smoke test

```bash
# Fresh clone in a tmp dir
git clone <repo> /tmp/s2m-test && cd /tmp/s2m-test
# Run on every fixture
bash tests/run-all-passes.sh
# Run on a real archival folder of Sal's choice
python3 scripts/identify.py --dir ~/Music/some-real-track-stems
# Manually approve the plan, run mix, run verify
```

If anything in the smoke test reads as confusing for a non-expert, it's a release blocker.

#### 7.6 Tag and ship

`git tag v1.0.0` with release notes summarizing the four major changes since v0.1: pan-law correctness, decomposed codebase, capability expansion (preview / loudness report / scaffold / solo), and doctrine-deepening.

### Definition of done

v1.0.0 tag exists, `CHANGELOG.md` is current, README reads cleanly, all fixtures pass with SHA assertions, a real archival run completes without operator confusion.

---

## Sequencing constraints

```
Phase 1 ─────────────────────────────────────────────► Phase 7
   │                                                       ▲
   ▼                                                       │
Phase 2 (5 parallel research items) ──┐                   │
                                       │                   │
                                       ▼                   │
                                    Phase 3 ──► Phase 4 ──► Phase 5
                                                    │
                                                    ▼
                                               Phase 6 (optional)
```

- Phase 2 starts only after Phase 1's foundation is trustworthy.
- Phase 3 starts only after Phase 2's decisions are recorded — refactoring around the wrong abstraction is wasted work.
- Phase 4 features depend on the modules created in Phase 3.
- Phase 5 sharpens the doctrine of features that exist; it can't sharpen what isn't built.
- Phase 6 is independent of 5 and can run in parallel with it if there's appetite.
- Phase 7 happens last.

---

## What "highly opinionated, capable" looks like at the end

### Highly opinionated

- 18 commandments, each cited by at least one error message or plan rationale.
- Plan output reads as terse, declarative, doctrine-citing prose.
- Every refusal names its rule and its override path.
- Three-tier vocabulary (technical rough / balanced demo / release master) surfaced everywhere.
- A `docs/why.md` that explains the existence of the skill in one page.
- Default behavior chooses correctness over convenience: mixdowns land outside the source folder, pan law defaults to a pan law (not 0 dB), `--lie` is named honestly.

### Capable

- Drives end-to-end from a folder of stems to a deliverable + a listening preview + a per-platform loudness report.
- Manifest scaffolding removes the "write YAML by hand" friction.
- `--solo` produces per-stem QC bounces for ear-checking.
- Pass 2 catches 12+ classes of pathological input with plain-English consequences.
- Pass 5 verifies output honestly, including 24-bit-FLAC depth honesty, mono-fold compatibility (gated), and null-test against a reference bounce.
- The Pro Tools track-name borrower correctly does what it says and stays out of session-timing claims.
- A sibling `stems-from-mix` skill exists for the "no stems, only a mix" case, with honest doctrine about separation's limits.

### Maintainable

- 4-module Python codebase; no file > 300 LoC.
- Three internal `_*` modules eliminate triplicated logic.
- Test fixtures plus a smoke test plus table-driven format-decision tests.
- Schema-versioned JSON contracts.
- Versioned releases with a CHANGELOG.

---

## Out of scope (named explicitly so you stop wondering)

- Native `.ptx` parsing. Rejected. See `REVIEW-2026-05.md` §3.
- AAF / OMF / OTIO timeline reconstruction. Deferred until a real user has the workflow.
- A loudness-targeting mastering pass. Out of scope by Commandment 9.
- Multichannel inputs (5.1, 7.1, ambisonic). Out of scope by Commandment §scope.
- Any DAW plug-in. This is a CLI / skill, not a plug-in.
- Cloud / network operations. Local-only.
- A GUI. The plan is the UI.

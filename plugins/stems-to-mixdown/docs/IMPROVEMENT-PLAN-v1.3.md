# `stems-to-mixdown` — improvement plan, v1.3

_End state: the plugin no longer demands that the operator pre-flatten their folder structure, treats stereo as the universal output channel count without compromising mono compatibility, and ships a deliverable that's listenable on any device out of the box. Reference document: previous `IMPROVEMENT-PLAN.md` (Phases 1–7) and `CHANGELOG.md` through 1.2.0._

This plan is sequenced for safe application. Phase 1 is a pure UX win that removes a friction point. Phase 2 is a doctrinal re-statement around stereo output backed by external research. Phase 3 is the load-bearing change — it deliberately revises Commandment 9 and introduces a default normalization stage. Phase 4 wires it together and ships v1.3.

Phases are not interchangeable: Phase 3 is a doctrine revision and the rest of the plan depends on the new policy being settled before code lands.

---

## Phases at a glance

| Phase | Goal | Type | Blocks |
|---|---|---|---|
| 1. Folder shape detection | Auto-detect "audio dir" vs "project folder containing one audio dir" without prompting | Implementation | — |
| 2. Stereo-output policy | Codify "always stereo out"; refine mono-stem treatment per current expert consensus | Doctrine + light implementation | Phase 4 |
| 3. Default normalization (Cmd 9 revision) | Canonical output ships normalized to -14 LUFS-I / -1 dBTP; archival unity-sum becomes opt-in | Doctrine + implementation | Phase 4 |
| 4. Wire-up, docs, validation, ship | run.py default flow, fixtures, baselines, README/CHANGELOG, v1.3.0 tag | Ship | — |

The shape: **reduce friction → settle stereo doctrine → revise loudness doctrine → ship.**

---

## Cross-cutting policies (apply to every phase)

These supersede the v1.0/v1.1/v1.2 cross-cutting list only where they say so explicitly; otherwise the originals stand.

1. **No silent doctrinal changes.** Every commandment edited or added in this plan gets a one-line `commandments.md` entry plus a CHANGELOG line that names the prior behavior, the new behavior, and the migration flag.
2. **The unity-sum capability never leaves the codebase.** Phase 3 changes the default; it does not delete the old code path. `--archival` (or equivalent) reaches the v1.2 behavior byte-for-byte.
3. **Schema versioning.** If `analysis.json` or `plan.json` change shape in this plan, bump `schema_version` and document the change in `docs/decisions/`.
4. **Soft-import discipline holds.** No new hard dependency. Every phase must produce a valid mixdown with only `ffmpeg`, `ffprobe`, and Python 3.10+ installed.
5. **Provenance still reigns.** Sidecar `.log.md` records every gain stage, every filter, every measurement — including the new normalization stage's pre/post LUFS-I and dBTP.
6. **Voice consistency.** New copy follows the existing terse-engineer tone established in Phase 5 of the v1.0 plan.

---

## Phase 1 — Folder shape detection

### Goal

Stop asking the operator whether they pointed at the audio directory or the project folder. After this phase, `run.py --dir <X>` does the right thing whether `<X>/*.wav` exists, or whether `<X>/<one-subdir>/*.wav` is the actual audio location, or whether `<X>` contains multiple sibling directories one of which contains the stems.

The only surviving interactive case is "no audio anywhere within reasonable depth," which is the genuine error and gets a single, clear prompt.

### Inputs

- `scripts/identify.py` (already does the cheap top-level scan).
- The DAW-export reality: Logic / Pro Tools / Cubase typically write into a project folder named after the song, with a `Bounces/` or `Audio Files/` subdirectory holding the actual stems.
- The archival reality: a clean folder of stems is also common, often dropped beside or inside an outer `~/Music/<song>/` parent.

### Implementation

#### 1.1 Recursive cheap scan in `identify.py`

Extend the cheap top-level scan to walk one extra level, capped by `--max-depth N` (default `3`). The scan still does no `ffprobe` and no SHA — it only looks at extensions and filenames. New fields in `identify.json`:

```json
{
  "schema_version": "3",
  "audio_locations": [
    { "path": "...", "stem_count": 9, "master_candidates": ["..."], "naming_quality": "informative" },
    ...
  ],
  "resolved_directory": "...",
  "resolution_reason": "single_audio_subdir | exact_match | needs_user_clarification"
}
```

#### 1.2 Resolution rules (in priority order)

The new logic in `identify.py:resolve_audio_directory()`:

1. **Direct hit.** `<X>/*.{wav,flac,...}` contains audio files → `resolved = <X>`, `reason = exact_match`. (Behavior unchanged from v1.2.)
2. **Single nested audio dir.** `<X>` has no top-level audio files but exactly one subdirectory at depth ≤ `--max-depth` contains audio → `resolved = <subdir>`, `reason = single_audio_subdir`. Print a one-line stderr note: `[info] no audio at <X>; descending into <subdir> (the only candidate).`
3. **Multiple nested audio dirs.** More than one subdirectory contains audio → `resolved = None`, `reason = needs_user_clarification`. Print all candidates with stem counts and master-candidate notes; recommend the operator pick one and re-invoke. This is the only surviving prompt path.
4. **No audio anywhere.** Report and exit 2.

The `single_audio_subdir` case never prompts — it's the obvious choice. The `needs_user_clarification` case is rare in practice but real; it gets the same treatment as today's PT-without-export case in identify.py.

#### 1.3 `run.py` consumes the resolved path

`run.py` calls `identify` first, reads `resolved_directory`, and feeds that into `analyze.py`. The `--dir` flag the operator passed remains visible in artifacts so the audit trail records what they typed.

### Validation

```bash
# A: direct hit (existing fixture)
python3 scripts/run.py --dir tests/fixtures/with-master --yes
# Expect: identify.resolution_reason = exact_match

# B: project folder with single audio subdir (synthetic)
mkdir -p /tmp/proj/audio && cp tests/fixtures/with-master/* /tmp/proj/audio/
python3 scripts/run.py --dir /tmp/proj --yes
# Expect: identify.resolution_reason = single_audio_subdir, resolved = /tmp/proj/audio

# C: project folder with two audio subdirs
mkdir -p /tmp/proj2/{stems,bounces}
cp tests/fixtures/with-master/* /tmp/proj2/stems/
cp tests/fixtures/with-master/* /tmp/proj2/bounces/
python3 scripts/run.py --dir /tmp/proj2 --yes
# Expect: exit 1; needs_user_clarification with both candidates listed

# D: empty parent
mkdir -p /tmp/proj3
python3 scripts/run.py --dir /tmp/proj3 --yes
# Expect: exit 2; "no audio found"
```

Add a fixture `tests/fixtures/nested-project-folder/` mirroring case B for the smoke runner.

### Risks

- **Wrong-hop on a project that contains both stems and a top-level master.** Already handled — the master in the parent gets picked up by master auto-detection (v1.2) and the audio subdir wins by direct/single-subdir rule.
- **Symlinks and weird mountpoints.** Resolve through `Path.resolve()` and bail on cycles via a visited-set.

### Definition of done

`identify.json` schema 3, four validation cases pass, new fixture in the smoke set, README "Quickstart" updated to drop the "make sure you point at the audio dir" caveat.

---

## Phase 2 — Stereo-output policy

### Goal

Stereo is not optional. The plugin already outputs stereo because `target_channels = 2` is hard-coded in `decide_output_format`; this phase makes the policy explicit in doctrine, refines the per-stem mono-handling rules with current external guidance, and adds operator controls for cases where multiple mono stems would otherwise pile up at center.

### External research (last 9 months)

Before any code changes, this phase grounds itself in the current expert consensus on mono-in-stereo-mix treatment. Sources consulted (all 2025–2026, audio engineering discipline):

- **Sound on Sound — "Are there any panning rules for maintaining mono compatibility?"** Confirms the long-standing rule: lead vocal, bass, kick centered; supporting elements panned. Mono compatibility check is the gate.
- **Mastering The Mix — "Guide to Panning and Stereo Width" (2025)**. Centered anchor + panned supports. Cautions against pseudo-stereo widening on individual sources because it kills mono compatibility.
- **Mixing Monster — "Stereo Widening In Mastering 2026"**. Mid-Side processing on the master bus is the modern stereo-width tool; per-source pseudo-stereo (Haas, decorrelation) is positioned as a creative effect, not a default.
- **ISMIR 2023 paper — "Mono-to-stereo through parametric stereo generation"** (Serrà & Scaini). Confirms: every modern pseudo-stereo / mono-upmix technique trades mono compatibility for stereo-width perception. For an archival/neutral deliverable that must survive mono fold, **do nothing creative** — pan and let stereo width emerge from the actual stereo content in the mix.

The consensus is clean: for the kind of mixdown this plugin produces, the right answer for a mono stem is **pan it, declare the pan law, don't apply pseudo-stereo**. Exactly what v1.2 does. The phase therefore mostly codifies the existing behavior plus a single missing capability — auto-distribution of multiple unspecified mono stems.

### Implementation

#### 2.1 New Commandment §20

`references/commandments.md`:

> **§20 — Stereo is the deliverable; mono is the source format. Don't decorate it.**
> Every mixdown is stereo. Mono stems are upmixed via the declared pan law (Cmd 16). The plugin does not apply Haas, decorrelation, or any pseudo-stereo treatment by default — every such technique trades mono compatibility for perceived width, and the deliverable is verified against mono fold (Cmd 6). Operators who want creative stereo placement use a manifest `pan` map; operators who want pseudo-stereo use a different tool.

#### 2.2 Manifest `pan` map (per-stem placement)

Currently the manifest has `gains:` and `output.pan_law` but no per-stem pan. Add:

```yaml
pan:
  vox_lead.wav: 0          # center (default for mono)
  bg_left.wav: -50         # 50% left
  bg_right.wav: 50         # 50% right
  perc_a.wav: -30
  perc_b.wav: 30
```

Values are -100..+100 (left to right). Mono stems with a non-zero pan get a stereo upmix that places them at the requested position via `pan=stereo|c0=L_coef*c0|c1=R_coef*c0` with constant-power law on top of the declared pan law. Stereo stems are unchanged.

#### 2.3 Auto-distribution opt-in (`--auto-pan`)

When the manifest has no `pan:` map and the group contains ≥3 mono stems all classified the same (e.g., three percussion stems), the operator can pass `--auto-pan` to spread them evenly across the field according to a documented rule (e.g., `vocal` stays center, multiple percussion gets ±30/0/±60, multiple guitars gets ±50/0/±50). The default remains "all mono stems centered" so the v1.2 behavior is preserved unless the operator opts in.

This is the only behavioral change in Phase 2; everything else is doctrine + validation.

#### 2.4 Pass 2 update — "all mono, all centered" warn

When all stems in a group are mono and no `pan:` map is present, sanity emits `mono_pile_at_center` (warn): "N mono stems all summing to center; the result is mono-in-a-stereo-container. Consider a `pan:` map or `--auto-pan`."

### Validation

- New fixture `tests/fixtures/multi-mono-pan/` with three classified-as-percussion mono stems + a `pan:` map, plus baseline assertions on the resulting filter graph.
- Mono-fold delta on the `--auto-pan` output must remain ≤ 6 LU (Cmd 6 partial-cancellation threshold) on the new fixture.
- `tests/test_pan_distribution.py` — table-driven cases for the auto-pan rule (3 mono percussion → ±30/0; 4 mono guitars → ±50/±25; etc.).

### Risks

- **Auto-pan rules are opinionated.** Document the table in `references/format-decisions.md`; allow override via the `pan:` map for any operator who disagrees.
- **Per-stem pan + declared pan law interaction.** The math composes correctly when both use the constant-power convention; explicit test in `test_pan_distribution.py`.

### Definition of done

§20 in commandments. `pan:` map field documented in `references/manifest-schema.md`. `--auto-pan` flag in `mix.py`. `mono_pile_at_center` warn in sanity. New fixture + test pass.

---

## Phase 3 — Default normalization (Cmd 9 revision)

### Goal

The canonical output ships normalized for "neutral playback with minimal alterations." A v1.2 mixdown handed to a non-engineer will play back at -14 LUFS-I / -1 dBTP — broadly the same loudness as anything they'd hear on Spotify or YouTube — without ad-hoc tools. The unity-sum-only path remains available behind `--archival`, but it stops being the default.

This is a deliberate doctrine revision and gets called out as such.

### External research (last 9 months)

Sources consulted (all 2025–2026, treated as authoritative when they converge):

- **Spotify — "Loudness normalization on Spotify"** (current artist support page): -14 LUFS-I, ITU-R BS.1770; positive gain applied to softer masters, negative to louder.
- **iZotope — "How to master for streaming platforms" (2025)** and the **Soundplate "Streaming Loudness LUFS Table 2026"**: Spotify, YouTube, Tidal, Amazon, TikTok, Instagram all normalize to **-14 LUFS-I**; Apple Music sits at **-16 LUFS** via Sound Check; broadcast EBU R128 sits at -23 LUFS.
- **Mat Leffler-Schulman — "True Peak vs Inter-Sample Peaks"** and **AES streaming loudness recommendation**: target true-peak ceiling **-1 dBTP** for any signal that will be transcoded to AAC/Ogg; this is non-negotiable when downstream encoding is in the picture.
- **Ian Shepherd — "Why LUFS Don't Matter As Much As You Think" (Mar 2025)**: the loudness target is a guideline, not a religion; dynamics and mix balance matter more. Practical reading for this plan: aim at -14, don't crush dynamics to get there, and treat the LUFS number as informational once you're within ±2 LU of target.
- **Mastering The Mix — "Guide to Panning and Stereo Width" (2025)**: separates "mastering" (creative decisions about EQ/compression/character) from "loudness conditioning" (LUFS + true-peak limiting). The plugin's scope, post-revision, is the second category and not the first.

**Synthesis.** The 2025–2026 consensus: a single target master at **-14 LUFS-I / -1 dBTP** is universally compatible across the major streaming platforms. Apple's Sound Check will quiet a -14 master by 2 dB; that's fine. EBU R128 broadcast wants -23 — that's a different deliverable and stays out of scope. **For a "neutral playback" default, -14 LUFS-I + true-peak limit at -1 dBTP, applied without any spectral or dynamics processing, is the most-compatible single answer.**

### The doctrinal change

Cmd 9 currently reads (paraphrased): _Loudness normalization is not mastering. The plugin measures LUFS; it doesn't target it._

Cmd 9 is rewritten to: _Loudness normalization is not mastering. **The default deliverable is normalized to -14 LUFS-I with a -1 dBTP true-peak ceiling.** Mastering — EQ, compression, creative limiting — is still out of scope. Operators who need bit-exact unity sum pass `--archival`; the manifest archives both the unnormalized canonical and the normalized listening copy when both are produced._

The motivation, recorded in `docs/decisions/2026-05-cmd-9-revision.md`:

1. The plugin's primary user (per the original review) is not a mixing engineer. Handing them a -25 LUFS unity-sum FLAC requires them to know how to normalize before sharing — exactly the friction the plugin was supposed to remove.
2. Unity-sum is not the same as "no processing." Pre-attenuation already happens (Cmd 3). The output is already engineered. Pretending the unity-sum is "raw" overstates the plugin's hands-off-ness.
3. The two existing escape hatches (`--preview` Cmd 17 + `loudnorm` listening copy) are confusing because they produce a sidecar that the operator is told *not* to ship. The default-normalized output collapses preview + canonical into one file the operator can actually share.
4. The unity-sum path is a real archival need (null-test against a DAW bounce; recombine-null in the reference bundle) — it stays as `--archival` and as the path the reference bundle uses internally. The doctrine doesn't lose the capability; it loses the default.

### Implementation

#### 3.1 New normalization stage in `plan.py` and `mix.py`

After Pass 4 produces the unity-sum WAV intermediate at 32-bit float, a new normalization stage runs:

```
ffmpeg ... -af "loudnorm=I=-14:LRA=11:TP=-1.0:print_format=summary"
```

Two-pass loudnorm (first pass measures, second pass applies the calibrated gain) — accurate to ±0.1 LU per the ffmpeg docs and well within Ian Shepherd's "treat ±2 LU as fine" guidance. The single-pass version used by `--preview` today is fast but less accurate; the canonical deliverable warrants the second pass.

A true-peak-only second stage uses `alimiter=limit=0.891:level=disabled` (-1 dBTP) as an insurance pass against any peaks the loudnorm gain stage created. The two-stage pipeline matches the standard mastering-engineer workflow for streaming-target normalization.

#### 3.2 New CLI flags

- `--archival` (mutually exclusive with `--target-lufs`): produce only the unity-sum unprocessed file, no normalization, no preview. The v1.2 default behavior, now opt-in.
- `--target-lufs <value>` (default `-14.0`, allowed `-14`, `-16`, `-23`): override the normalization target. `-16` for Apple-first deliveries; `-23` for broadcast.
- `--target-true-peak <value>` (default `-1.0`, allowed `-1.0`, `-1.5`, `-2.0`): override the true-peak ceiling.

`--preview` is removed (the canonical IS the listening copy now); existing `--preview` invocations get a one-time deprecation warning that points at `--archival` as the inverse.

#### 3.3 Reference bundle: archival mode internally

The reference bundle (Cmd 19) keeps using the unity-sum path internally — null tests against the master only work when the deliverables haven't been touched by loudnorm. The bundle's three files are unity-sum; a fourth file `<project>_master_listening.<ext>` is added as the normalized listening copy of the master, separate from the bundle.

#### 3.4 Sidecar `.log.md` records both stages

The sidecar log gets two new sections: `## Normalization` (loudnorm measured-input stats, applied gain, threshold) and `## True-peak ceiling` (limiter pass; how many samples were attenuated, by how much). The unity-sum intermediate's measurements are also recorded so an operator can reconstruct what the file would have looked like in `--archival` mode.

#### 3.5 Schema bumps

- `plan.json` schema → `"4"`: each group gains `normalization: { target_lufs, target_true_peak, two_pass: true }` and `archival: bool`.
- The reference bundle members each carry `normalization: null` (unity-sum, by design).

### Validation

```bash
# Default: normalized to -14 / -1 dBTP
python3 scripts/run.py --dir tests/fixtures/with-master --yes
ffmpeg -i ...with-master_instrumental.flac -af ebur128=peak=true -f null - 2>&1 | grep -E "Integrated|True peak"
# Expect: I within ±0.5 LUFS of -14; True peak ≤ -1.0 dBTP

# Archival opt-out: byte-equivalent to v1.2 output
python3 scripts/run.py --dir tests/fixtures/mono-stems --archival --yes
md5sum tests/fixtures/mono-stems-mixdowns/mono-stems_acapella.flac
# Expect: matches the v1.2 baseline in tests/baselines/expected-audio-md5s.txt

# Reference bundle still null-tests
python3 scripts/run.py --dir tests/fixtures/with-master --yes
python3 scripts/verify.py --plan ...plan.json
# Expect: recombine residual ≤ -90 dBTP (bundle members are unity-sum internally)

# Apple-first override
python3 scripts/run.py --dir tests/fixtures/mono-stems --target-lufs -16 --yes
# Expect: I within ±0.5 LUFS of -16
```

### Risks

- **Doctrinal resistance.** The plugin's identity is built on Cmd 9. Some operators will object to the change. Mitigation: `--archival` preserves the old behavior bit-for-bit; the CHANGELOG names the doctrine revision in the first line; `docs/decisions/2026-05-cmd-9-revision.md` records the reasoning in detail. Anyone who wants the old default can alias `s2m='python3 .../run.py --archival'` permanently.
- **loudnorm artifacts on extreme dynamic-range source.** Two-pass loudnorm can over-correct on tracks with very low LRA. Mitigation: clamp `LRA=11` (the standard); document in `references/format-decisions.md`; surface `loudnorm_low_dynamic_range` warn from Pass 2 when measured LRA < 4 LU (suggests the input is already crushed and normalization will mostly add gain).
- **Test baselines invalidated.** Every existing baseline's audio MD5 changes because the canonical now differs. Regenerate baselines under the new default; keep the old baselines as `tests/baselines/v1.2-archival/` and gate them behind `--archival` runs.

### Definition of done

Cmd 9 rewritten + `docs/decisions/2026-05-cmd-9-revision.md` committed. `--archival`, `--target-lufs`, `--target-true-peak` work. Sidecar logs include normalization sections. Default fixture runs pass at -14 LUFS-I ± 0.5 / -1 dBTP. `--archival` runs match v1.2 baselines byte-for-byte. Reference bundle still null-tests cleanly (bundle uses unity-sum internally).

---

## Phase 4 — Wire-up, docs, validation, ship

### Goal

Make the new defaults the default. After this phase, a fresh user running `run.py` against a project folder full of mono stems gets a normalized stereo deliverable with no flags set, and the docs explain why.

### Implementation

1. **`run.py` flags forward.** Wire `--archival`, `--target-lufs`, `--target-true-peak`, `--auto-pan` through from `run.py` to the per-pass scripts.
2. **README rewrite.** "What it does" section leads with the normalized listening output; archival mode is mentioned as the opt-in; the three-tier vocabulary table from v1.0 is rewritten to:
   - **Listening master** (default) — unity sum + loudnorm to -14 LUFS-I + -1 dBTP. Universal-streaming-compatible; ready to send.
   - **Archival unity-sum** (`--archival`) — bit-exact sum of stems, no loudness conditioning. The reference for null tests and reconstructions.
   - **Release-quality master** — still out of scope. (Cmd 9 unchanged on this point.)
3. **CHANGELOG entry for v1.3.0.** Names every doctrinal change explicitly. Notes that the default audio output bytes change for every fixture.
4. **`commandments.md` updated.** §9 rewritten, §20 added.
5. **`docs/decisions/index.md` index entries.** Phase 1 (folder shape), Phase 2 (stereo policy), Phase 3 (Cmd 9 revision) each get a one-line entry pointing at the relevant decision doc.
6. **Version bump.** `_version.py` → `1.3.0`. `plugin.json` description rewritten to lead with the listening-master default.
7. **Baseline regeneration.** Every fixture's mixdown MD5 + analysis/plan JSON is regenerated against the new default. The v1.2 baselines stay at `tests/baselines/v1.2-archival/` and are exercised by `--archival` runs in `tests/run-all-passes.sh`.

### Validation

- All v1.2 tests pass under `--archival` against the preserved v1.2 baselines.
- All v1.3 tests pass under default flags against new baselines.
- `tests/test_codec_detection.py` and `tests/test_format_decision.py` unchanged.
- Two new fixtures: `tests/fixtures/nested-project-folder/` (Phase 1) and `tests/fixtures/multi-mono-pan/` (Phase 2).
- A real archival run on a folder of Sal's choice — mono and stereo stems mixed, at least one ALAC m4a in the chain (regression-coverage from v1.2), plus a master sitting alongside.
- Sidecar `.log.md` for the default mixdown reads top-to-bottom as a coherent story: inputs → unity-sum measured → loudnorm gain → true-peak limited → output measured.

### Definition of done

v1.3.0 tag exists. CHANGELOG is current. Default fixtures pass with normalized output; `--archival` fixtures pass against preserved v1.2 baselines. README leads with the new default. Cmd 9 revision and §20 addition are documented. A real archival run completes end-to-end without operator intervention.

---

## Open questions before any code lands

These are deliberately listed at the end so they're seen and resolved before Phase 3 starts:

1. **Is `-14` the right default, or should the plugin pick `-16` to be safe across Apple Music?** Spotify / YouTube / Tidal / Amazon all sit at -14; Apple is the only major outlier at -16. A -14 master gets quieted by 2 dB by Apple Sound Check (which is fine). A -16 master gets boosted by 2 dB by everyone else (which is also fine but reduces headroom against the -1 dBTP ceiling). Recommendation: default `-14`, document the trade-off, expose `--target-lufs -16` for Apple-first delivery.

2. **Two-pass loudnorm vs. ReplayGain 2 (R128)?** Two-pass is standard but slow. RG2 is faster and uses the same BS.1770 measurement. For the canonical-default path, two-pass loudnorm is the right call for accuracy; for `--quick-mix` or future `--draft` modes, RG2 measure-then-apply could be a follow-up.

3. **Should `--auto-pan` (Phase 2) live in the manifest as `output.auto_pan: true` instead of a CLI flag?** A manifest field is more reproducible. Recommendation: support both; CLI overrides manifest.

4. **`loudnorm_low_dynamic_range` threshold (Phase 3 risk).** The recommended LRA threshold of 4 LU is conservative; some genres legitimately sit lower. Recommendation: warn at < 4 LU but never refuse; the warn message suggests the operator inspect the source for upstream compression and pass `--archival` if the unity-sum is preferable.

5. **Reference-bundle naming convention with the new default.** Today the bundle's `<project>_master.<ext>` is the unity-sum. In v1.3 it's still the unity-sum (the bundle uses archival internally). Should there be a fourth member, `<project>_master_listening.<ext>`, at the normalized -14 LUFS? Recommendation: yes, but as a sibling of the bundle dir, not inside it — the bundle's three-synced-versions promise depends on identical loudness, which the listening copy violates by design.

---

## What "v1.3 ready" looks like

### Less friction
- One command, one folder argument, no "but did you point at the audio dir or the parent dir" question.
- The output plays back at a normal volume on any device, against any reference track on the user's library, without manual normalization.

### More opinionated, in the right places
- Stereo is the deliverable, mono compatibility is verified, pseudo-stereo is refused (Cmd 20).
- The default loudness target is a deliberate engineering choice (-14 LUFS-I / -1 dBTP) chosen to match the 2025–2026 streaming consensus, not an accident.

### No capability lost
- `--archival` produces the v1.2 unity-sum output bit-for-bit.
- The reference bundle still null-tests cleanly against the master.
- Every commandment that survives is still cited by an error message or a plan rationale.

### Provenance preserved
- Sidecar `.log.md` documents both the unity-sum intermediate and the normalization stages.
- `docs/decisions/2026-05-cmd-9-revision.md` records why the doctrine changed.

---

## Sources consulted

Phase 2 — stereo / mono treatment:
- Sound on Sound, "Q. Are there any panning rules for maintaining mono compatibility?" (current archive).
- Sound on Sound, "Q. How do I create a stereo mix from mono material?" (current archive).
- Mastering The Mix, "Guide to Panning and Stereo Width" (2025).
- Mixing Monster, "Stereo Widening In Mastering | More Width And Depth In 2026" (2026).
- ISMIR 2023, Serrà & Scaini, "Mono-to-stereo through parametric stereo generation."

Phase 3 — normalization / loudness policy:
- Spotify, "Loudness normalization on Spotify" (current artist support).
- iZotope, "How to master for streaming platforms" (2025 update).
- Soundplate, "The Ultimate Guide to Streaming Loudness (LUFS Table 2026)."
- Sean Kim, "Loudness Mastering Streaming Platforms: The Complete 2026 LUFS Standards Guide."
- Mat Leffler-Schulman, "True Peak vs Inter-Sample Peaks."
- Mixing Lessons, "True peak: why your songs should never peak above -1 dBTP."
- Lost Stories Academy, "Why Mastering for Streaming is Different in 2025."
- Ian Shepherd, "#186: Why LUFS Don't Matter As Much As You Think" (The Mastering Show, March 2025).
- Sound on Sound, "Ian Shepherd On Loudness & Dynamics."

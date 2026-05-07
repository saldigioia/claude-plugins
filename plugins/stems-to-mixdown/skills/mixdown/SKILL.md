---
name: mixdown
description: Sum a directory of multitrack audio stems into stereo mixdowns (acapella, instrumental, custom groupings) at the highest quality the source material honestly supports. Triggers on phrases like "sum these stems," "bounce an instrumental," "make an acapella," "mix these stems down," or pointing at a folder of audio files and asking for a combined version. When a released master sits alongside the stems, the skill auto-detects it and produces a three-synced-versions reference bundle plus a recombine-null verification battery.
argument-hint: "<stems-folder> [--master <path>] [--preview] [--solo] [--yes]"
allowed-tools:
  - Bash(python3 *)
  - Bash(ffmpeg *)
  - Bash(ffprobe *)
  - Bash(jq *)
  - Bash(ls *)
  - Bash(cat *)
  - Bash(mkdir *)
  - Read
  - Write
  - Edit
  - Grep
  - Glob
---

# mixdown

A conservative mixdown engineer in script form. Reads a directory of stems, refuses to invent fidelity that wasn't captured, produces stereo sums with full provenance.

## TL;DR — the obvious case

When the directory is unambiguous (well-named stems, optional master alongside, no Pro Tools artifacts), one command does the whole pipeline:

```bash
python3 "${CLAUDE_SKILL_DIR}/../../scripts/run.py" --dir <stems-or-project-folder>
```

`run.py` surveys first, then chains identify → analyze → plan → mix → verify with auto-decisions:

- **Folder shape detection (v1.3).** `--dir` may point at the audio dir itself OR at a project folder containing one nested audio dir; identify hops one level deeper without prompting. Multiple sibling audio dirs is the only surviving prompt path.
- **Master auto-detection.** Any file in the audio dir named `master`, `final`, `released`, `reference`, or `bounce_final` (and not classifying as a stem) is treated as the master reference; it gets excluded from the stem walk and drives the reference bundle. `--no-auto-master` disables; `--master <path>` overrides.
- **Default normalized output (v1.3 / Cmd 9 revised).** The canonical mixdown ships at -14 LUFS-I / -1 dBTP via two-pass loudnorm + true-peak limiter — the 2025–2026 streaming consensus, ready to send. Pass `--archival` to get the v1.2 unity-sum behavior. `--target-lufs -16` for Apple-first delivery; `--target-lufs -23` for EBU R128 broadcast.
- **Stereo always (v1.3 / Cmd 20).** Mono stems are panned via the constant-power curve renormalized to the declared pan law; the manifest's `pan:` map (per-stem -100..+100) overrides; `--auto-pan` opts into auto-distribution for groups of N classified-the-same mono stems (vocals + bass stay center).

`--yes` skips the plan-approval prompt; `--solo` adds per-stem QC bounces. The per-pass scripts below remain available for power users who want intermediate JSON or to re-run a single step.

## What you're getting (three tiers, v1.3 revised)

| Tier | What it is | How to get it | Doctrine |
|---|---|---|---|
| **Listening master** _(default)_ | Unity sum + two-pass loudnorm to -14 LUFS-I + true-peak limit at -1 dBTP. Universal-streaming-compatible; ready to send. No EQ, no compression, no spectral processing — strictly loudness conditioning. | `mix.py` (or `run.py`) with no extra flags. | Cmd 9 (revised), Cmd 2 (still sums at unity inside) |
| **Archival unity-sum** | Bit-exact sum of the stems, no loudness conditioning. The reference for null tests, the source for downstream mastering, the v1.2 default. | `--archival` (or `output.archival: true`). | Cmd 2, Cmd 9 (revised; archival path still honors the original framing) |
| **Release-quality master** | Loudness target + EQ + compression + limiting + creative judgment. | **Out of scope.** Use a mastering tool. | Cmd 9 (mastering vs. loudness conditioning is a structural distinction) |

The default deliverable is the listening master. Pass `--archival` when you need the unity-sum file (e.g. for null testing against a DAW bounce, or when the file will be mastered downstream). The reference bundle (Cmd 19) always uses unity-sum internally regardless of which mode the canonical was rendered in — null tests against the master only work on un-normalized signals.

## With a master reference (auto-detected, or opt-in)

When the released version of the song is available — the master, as it appears on streaming or the physical release — three things happen automatically:

1. **Auto-detection.** If a single file in the stems folder matches a master pattern (`master`, `final`, `released`, `reference`, `bounce_final`) and does not classify as a stem, `analyze.py` (and `run.py`) treats it as the master reference and excludes it from the stem walk. Pass `--no-auto-master` to disable this. Multiple matches → refusal; the operator picks via `--master <path>` or by renaming.
2. **Manifest opt-in.** `source.master_reference.path` in `stems.manifest.yaml` works exactly as before and overrides auto-detection.
3. **CLI override.** `--master <path>` on `analyze.py` / `run.py` / `verify.py` wins above all.

When any of those resolve, the skill produces a **`reference-bundle/`** alongside the canonical mixdowns containing three perfectly synchronized files: `<project>_master.<ext>`, `<project>_instrumental.<ext>`, `<project>_acapella.<ext>`, all at identical rate / depth / channels / duration.

Pass 5 runs the **reference battery**: the recombine null `(instrumental + acapella) - master` (headline), and two diagnostic inverse-stems nulls (`master - acapella` ≈ instrumental, `master - instrumental` ≈ acapella), plus per-deliverable LUFS-I and dBTP deltas vs the master. Recombine residual ≤ -90 dBTP is a pass within dither noise; -60 to -90 is a smell; above -60 is structurally different.

The master is the witness, not the source (Cmd 19). The skill **refuses** to resample, requantize, downmix, or trim the master to fit — mismatched rate / depth / channels / duration fires Pass 2 errors and the run stops until the operator either re-renders the master or omits the reference. The original master file is never modified; only the bundle copy is re-encoded, and only when the format already differs.

## Voice

The skill's logs and error messages talk like an engineer who's seen too many "make it louder" sessions. Terse. Technical. Will explain *why* once. Won't apologize for refusing to upsample.

## Scope

**In scope:**
- Mono and stereo input stems
- Lossless inputs (WAV, FLAC, AIFF) and lossy inputs (MP3, AAC, OGG)
- Output to FLAC (default), WAV, AIFF, or single-generation MP3 (V0 only, with explicit warning)
- Automatic grouping (acapella / instrumental) and custom groupings via manifest

**Out of scope — refuse and explain:**
- Multichannel inputs (5.1, 7.1, ambisonic). Different problem, different tooling.
- Mastering. This skill bounces a clean sum. Loudness targets are a separate decision.
- Re-encoding lossy → same lossy at higher bitrate. That's a fidelity claim the source doesn't support.

## The workflow (Pass 0a → 0b → 1 → 2 → 3 → 4 → 5)

Follow this order. Do not skip Pass 3's approval gate unless the user passed `--yes`.

### Pass 0a — Identify (always first)

Run `python3 "${CLAUDE_SKILL_DIR}/../../scripts/identify.py" --dir <path>` whenever the user points at a folder. This is a cheap triage pass — no `ffprobe`, no measurements, no heavy parsing — that decides whether the rest of the workflow needs to think about Pro Tools at all. It scans filenames, looks for Session Info text exports / `.ptx` artifacts, samples a few WAVs for `bext` / `iXML` chunk signals, and emits `identify.json` plus a markdown report on stderr.

**The output is a contract.** Read the `recommendation` field and act on it:

- `skip_to_pass1` — Filenames are informative or a manifest is already present. Go directly to Pass 1. **Do not run `import_pt_track_names.py`. Do not load Pro Tools metadata into context.** This is the common case for well-named stem folders, and reading PT metadata anyway will only confuse the planning step.
- `run_pass0_pt_intake` — Filenames are mostly generic AND a Session Info text export is present. Run Pass 0b before Pass 1. Identify will give you the exact command in `next_command`.
- `needs_user_clarification` — Filenames are generic and no Session Info export is available. Stop and ask the user; don't run Pass 1 blind (it will classify everything as `other`).

The point is the negative result. When the directory is a clean folder of well-named stems, identify says so and the LLM moves on without ever loading the Pro Tools machinery.

### Pass 0b — Pro Tools track-name borrowing (only if Pass 0a says so)

When Pass 0a's recommendation is `run_pass0_pt_intake`, run `python3 "${CLAUDE_SKILL_DIR}/../../scripts/import_pt_track_names.py" --session-info <txt> --audio-dir <wav-folder> --out <wav-folder>`. The helper **borrows the track names** from the Pro Tools export so analyze.py's classifier can label files the engineer didn't bother to rename. It does **not** reconstruct session timing — the "Session Info as Text" export simply doesn't carry that data in machine-parseable form.

If you have stems with different timeline anchors (different `bext.time_reference` values per stem), the right move is to **consolidate stems in Pro Tools first** (Edit → Consolidate). The rest of the pipeline assumes anchor-aligned stems at sample 0; `amix=duration=longest` will sum at zero offset and the song will be wrong otherwise. Pass 2's `stems_unanchored` warn flags this when wavinfo is installed.

The helper writes two files into the audio dir:

- `stems.session.yaml` — full structural context from the Pro Tools export (session metadata, track listing, file listing, markers as raw blocks). This is LLM-reference material; `analyze.py` does not consume it.
- `stems.manifest.yaml` — a partial manifest in the existing schema (see `references/manifest-schema.md`). Only `classifications` is populated, derived from track names. `groups`, `gains`, `output`, `metadata` are left empty for the user to complete.

Files referenced by the session but not present in the audio dir are preflighted and dropped, so the first `analyze.py` run after Pass 0b won't hard-error on a stale reference. Pass 0b is read-only — it never modifies the source WAVs or the `.ptx` file.

### Pass 1 — Discovery

Run `python3 "${CLAUDE_SKILL_DIR}/../../scripts/analyze.py" --dir <path>`. It walks the directory, calls `ffprobe` on every audio file, computes SHA-256, and classifies each stem by filename heuristic. Output: `analysis.json` (machine) plus a human report on stderr. If `stems.manifest.yaml` exists in the directory, the manifest's classifications and groupings override the heuristics — see `references/manifest-schema.md`.

The classification buckets are: `vocal`, `drums`, `bass`, `guitar`, `keys`, `fx`, `other`. The skill maps these to *groups* (the actual mixdown deliverables) in Pass 3.

**Optional pro-audio enrichment.** If `wavinfo` (Python) and/or `mediainfo` (CLI) are installed, Pass 1 enriches each stem record with a `production_metadata` block (BWF `bext` chunk, iXML `scene`/`take`/`project`, MediaInfo cross-check). This material is **LLM-reference context only** — it lives in `analysis.json` so Claude has the production context to plan a mixdown intelligently, and never auto-flows into output FLAC tags. wavinfo is also the only tool of the trio that reads `wValidBitsPerSample` correctly, fixing a 24-in-32 bit-depth ambiguity in `WAVE_FORMAT_EXTENSIBLE` files. Pass `--bwf-report` to additionally emit FADGI-conformant XML/CSV reports via BWF MetaEdit, written to `<dir>/.s2m/metadata/`. See `references/pro-audio-metadata.md` for the full source-of-truth rule.

### Pass 2 — Sanity check

The same script runs sanity checks: rate / depth / channel-count consistency, length drift (±1 sample tolerance), inter-sample true-peak (via ffmpeg `ebur128`), DC offset (via `astats`), fully-silent files, stereo files silent on one channel.

If red flags appear, the script exits nonzero. The user must pass `--force` to proceed past genuine problems, or fix the inputs and re-run. Red flags include:

- Sample rate disagreement across stems
- True-peak above 0.0 dBTP on any input (already-clipped source)
- DC offset beyond ±0.001
- Length mismatch beyond 1 sample
- Stereo file with one dead channel
- Any file fully silent

A red flag is not the end of the world — it's a request for the human to look. Don't paper over it.

### Pass 3 — Plan (dry-run)

Run `python3 "${CLAUDE_SKILL_DIR}/../../scripts/plan.py" --analysis analysis.json`. It reads the discovery output, applies the format-decision matrix in `references/format-decisions.md`, predicts the mixdown peak, and prints a markdown plan to stdout. The plan is the contract — show it to the user and wait for approval.

The format-decision matrix in short:

- **All lossless, same rate/depth** → FLAC at native rate/depth. Native fidelity preserved.
- **All lossless, mixed rates** → FLAC at the *highest* common rate (upsampling is mathematically a no-op transform on existing samples; downsampling discards). Bit depth: smallest common.
- **All lossless, mixed depths** → FLAC at smallest input bit depth.
- **Any lossy input present** → 16-bit / 44.1 kHz FLAC default. The deliverable refuses to claim more precision than the lossy source implies. User can override to MP3 V0 same-codec output, with a logged warning that this is a second-generation encode.
- **User requests upgrade beyond source** (e.g., 24-bit FLAC out from 16-bit inputs) → refuse. Cite the source-is-the-ceiling rule.

Peak prediction is **measured, not estimated**. The plan stage runs the mix at 32-bit float to a null sink and reads the actual true peak via `ebur128`. If predicted peak exceeds -1 dBTP, the plan proposes pre-attenuation to land at -3 dBTP (pre-sum gain trim, applied per-stem proportionally — never post-hoc normalization).

### Pass 4 — Execute

Run `python3 "${CLAUDE_SKILL_DIR}/../../scripts/mix.py" --plan plan.json`. The mix engine is **ffmpeg** with `amix=normalize=0` and explicit weights (decision documented in `references/tool-cheatsheet.md` — sox's `--guard` was rejected because it conflates "fits without clipping" with "unity sum," and we want unity sum). Internal precision: 32-bit float. Mono stems are upmixed to stereo via `pan=stereo|c0=K*c0|c1=K*c0` with `K = 10 ** (pan_law_db / 20)` (default `-3.0 dB` per Commandment 16; `output.pan_law` in the manifest overrides) before summing.

Outputs land in a **sibling** directory of the source by default — `<source-dir>/../<source-dirname>-mixdowns/<project>_<group>.<ext>` — so the source folder is never written into. Pass `--output-dir` to plan.py to override (e.g., to keep the legacy `<source-dir>/mixdowns/` layout). Project name derives from the directory basename unless the manifest specifies one.

Each output gets a sidecar `<output>.log.md` recording: input files (path + SHA-256), tool versions, exact ffmpeg command, filter graph, per-input measurements (LUFS-I, LRA, dBTP), output measurements, pre-attenuation applied, timestamp. This is the reversibility commitment — a future engineer can reconstruct what was done and why.

Dither is applied at final encode if and only if bit depth is being reduced. Method: `aresample=osf=s16:dither_method=triangular_hp`. No exceptions, no "just a reference bounce" carve-out.

### Pass 5 — Verify

Run `python3 "${CLAUDE_SKILL_DIR}/../../scripts/verify.py" --plan plan.json`. Re-probes every output, confirms format matches the plan, confirms no clipping. If the user passed `--reference <file>`, it does a null test (phase-invert + sum) against the reference and reports residual peak. Below -90 dBFS residual is a pass; louder is a smell worth investigating.

## Group definitions

Groups are the actual mixdown deliverables. Three are derived automatically from buckets; more can be added via manifest.

- **`acapella`** — all stems classified as `vocal`.
- **`instrumental`** — all stems *not* classified as `vocal`.
- **Custom groups** — defined in `stems.manifest.yaml` under the `groups:` key. The manifest's group definitions override the automatic ones if names collide.

If no vocal stems are present, `acapella` is skipped silently and only `instrumental` is produced (which equals "everything"). If only vocal stems are present, `instrumental` is skipped.

## Non-negotiables (inline, not buried in references)

These four rules govern the skill's behavior. The full opinionated list lives in `references/commandments.md`.

1. **The source is the ceiling.** Output rate/depth follows the inputs. Do not upsample. Do not extend bit depth beyond what was captured.
2. **Sum at unity.** `amix=normalize=0` always. Never let the mixer divide by input count. Headroom comes from pre-sum attenuation when measurement says it's needed, not from automatic normalization.
3. **Dither when reducing bit depth.** Triangular PDF, noise-shaped. Always. Even reference bounces.
4. **Approve the plan before executing.** Pass 3 prints a plan; the user approves; Pass 4 runs. The `--yes` flag exists for automation but is the exception, not the default.

## When the inputs are pathological

The most common pathological case: lossless stems plus one MP3 someone forgot to replace. The skill's behavior:

- Pass 2 flags the lossy file in the report.
- Pass 3 proposes 16/44.1 FLAC output and explains the format-decision rule in plain prose.
- Pass 4 will not produce 24-bit output even if the user passes `--yes`. The hard floor is the source. If the user truly wants 24-bit FLAC out of MP3-in-the-chain material, they can run the script with `--lie` (which is named that on purpose; the log will record it; the output filename gets a `.degenerate` suffix). This exists for testing, not for production.

Other pathologies (DC offset, length drift, channel mismatch) get flagged in Pass 2 and require either input fixes or `--force` to proceed.

## References

- `references/commandments.md` — Full opinionated principles list with rationale for each.
- `references/tool-cheatsheet.md` — Task → exact ffmpeg/sox/ffprobe invocation. The skill cites this rather than reasoning from memory.
- `references/format-decisions.md` — Input-situation → output-format matrix in full.
- `references/manifest-schema.md` — `stems.manifest.yaml` field reference and example.
- `references/pro-audio-metadata.md` — Source-of-truth rule for technical fields, the LLM-reference framing for production metadata, the install matrix for optional deps, and the 24-in-32 ambiguity.

## Scripts

- `python3 "${CLAUDE_SKILL_DIR}/../../scripts/run.py"` — One-shot orchestrator. Runs identify → analyze → plan → mix → verify with auto-decisions; the recommended entry point for the common case.
- `python3 "${CLAUDE_SKILL_DIR}/../../scripts/identify.py"` — Pass 0a (triage, always run first when invoking the per-pass scripts directly).
- `python3 "${CLAUDE_SKILL_DIR}/../../scripts/import_pt_track_names.py"` — Pass 0b (Pro Tools intake bridge, run only when 0a recommends it).
- `python3 "${CLAUDE_SKILL_DIR}/../../scripts/analyze.py"` — Pass 1 + Pass 2.
- `python3 "${CLAUDE_SKILL_DIR}/../../scripts/plan.py"` — Pass 3 (dry-run, prints plan).
- `python3 "${CLAUDE_SKILL_DIR}/../../scripts/mix.py"` — Pass 4 (executes the plan).
- `python3 "${CLAUDE_SKILL_DIR}/../../scripts/verify.py"` — Pass 5 (re-probes outputs, optional null test).

All scripts: `--dir <path>` or `--analysis/--plan <json>`, JSON to stdout, logs to stderr, exit nonzero on red flags unless `--force`. Idempotent — re-running yields identical artifact hashes. (The advisory artifacts under `<dir>/.s2m/metadata/` from `--bwf-report` are not subject to the determinism contract; see `references/pro-audio-metadata.md`.)

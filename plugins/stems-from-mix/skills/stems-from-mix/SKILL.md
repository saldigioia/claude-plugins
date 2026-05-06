---
name: stems-from-mix
description: Extract stems (vocals, drums, bass, other) from a finished stereo mix using demucs htdemucs_ft, then hand off to stems-to-mixdown for unity-sum mixdowns. Use this skill when the user has only a finished song or mixdown and asks for an acapella, an instrumental, separated stems, source separation, "give me the vocals from this track," or any phrasing involving a mix-to-stems extraction. Trigger when the input is a single audio file (not a folder of stems) and the user wants individual elements pulled out. Hands off cleanly to stems-to-mixdown for the bouncing step.
argument-hint: "<finished-mix.wav> [--device cpu|mps|cuda] [--out <dir>]"
allowed-tools:
  - Bash(python3 *)
  - Bash(ffmpeg *)
  - Bash(ffprobe *)
  - Bash(demucs *)
  - Bash(jq *)
  - Bash(ls *)
  - Bash(mkdir *)
  - Read
  - Write
  - Grep
  - Glob
---

# stems-from-mix

A separation engineer in script form. Reads a finished stereo mix, runs `demucs` to estimate stems, renames the outputs to match the regex contract of [`stems-to-mixdown`](../stems-to-mixdown/), and emits a manifest so the bounce step doesn't have to guess.

This is a **sibling** of `stems-to-mixdown`. The two skills share a contract — the `stems.manifest.yaml` schema and the regex stem names — but no code. Use this skill to get stems out of a mix; use `stems-to-mixdown` to bounce them back into deliverables.

## Voice

Honest about approximation. Bleed is real. Separated stems are sketches that read as deliverables only after a human listens and verifies. The skill says so.

## Scope

**In scope:**
- Single stereo audio file input (WAV, FLAC, AIFF, MP3, M4A, AAC).
- Four-stem separation: `vocal`, `drum`, `bass`, `other` (matches `stems-to-mixdown`'s regex set).
- CPU, Apple MPS, and CUDA. Defaults to MPS on Apple Silicon, CUDA when available, CPU otherwise.
- Hand-off manifest with explicit classifications so the downstream skill doesn't re-classify.

**Out of scope — refuse and explain:**
- Stems that are already separated (use `stems-to-mixdown` directly).
- Mono input (separation models are trained on stereo and will degrade on mono).
- "Stems" of a multitrack session — different problem; that's `stems-to-mixdown`'s domain.
- Mastering or loudness targeting on the separated outputs (Cmd S3 below).

## Workflow

```
finished-mix.wav
       │
       ▼
   separate.py     # demucs htdemucs_ft → 4 stems (renamed)
       │
       ▼
<song>-stems/
├── vocal.wav
├── drum.wav
├── bass.wav
├── other.wav
└── stems.manifest.yaml   # explicit classifications, source provenance
       │
       ▼
   verify.py       # clipping / silence / artifact spot-checks
       │
       ▼
[ then hand off to stems-to-mixdown ]
       │
       ▼
   stems-to-mixdown/scripts/identify.py --dir <song>-stems
   ... → analyze → plan → mix → verify
```

## Doctrine (separation-specific)

Three rules unique to this skill. The eighteen commandments of `stems-to-mixdown` still apply downstream of the hand-off.

- **Cmd S1 — Bleed is real.** Separated stems contain residue of every other source. They're approximations, not ground truth. Null-test against the original mix, not against zero.
- **Cmd S2 — Keep the original mix.** Retain the source mix alongside the stems forever. The mix is truth; the stems are a lossy projection of it. The manifest records the source path and SHA so the chain stays auditable.
- **Cmd S3 — Don't master separation outputs.** Demos, remixes, karaoke, training data — yes. Release deliverables — no. Tell the user before they ask.

## Quick start

When invoked from a Claude Code session with both plugins installed:

```
/stems-from-mix:stems-from-mix finished-mix.wav
```

Then, after the separation finishes:

```
/stems-to-mixdown:mixdown finished-mix-stems/
```

Or invoke the underlying scripts directly via their plugin install paths:

```bash
# Separation (writes <song>-stems/ next to the input)
python3 "${CLAUDE_SKILL_DIR}/../../scripts/separate.py" --input finished-mix.wav

# Optional QC
python3 "${CLAUDE_SKILL_DIR}/../../scripts/verify.py" --stems-dir finished-mix-stems

# Hand off to stems-to-mixdown (its own ${CLAUDE_SKILL_DIR})
python3 "${CLAUDE_PLUGIN_ROOT}/../stems-to-mixdown/scripts/identify.py" --dir finished-mix-stems
python3 "${CLAUDE_PLUGIN_ROOT}/../stems-to-mixdown/scripts/analyze.py" --dir finished-mix-stems > a.json
python3 "${CLAUDE_PLUGIN_ROOT}/../stems-to-mixdown/scripts/plan.py" --analysis a.json > p.json
python3 "${CLAUDE_PLUGIN_ROOT}/../stems-to-mixdown/scripts/mix.py" --plan p.json --yes
```

(In a checkout of the `claude-plugins` repo, the cross-plugin path is just `../stems-to-mixdown/scripts/...`.)

## Dependencies

Required:
- `demucs` (PyPI): `pip install demucs`. Brings PyTorch as a transitive dep.
- `ffmpeg` + `ffprobe` for QC and any transcoding from non-WAV input.
- Python 3.9+.

Model weights: `htdemucs_ft` is a bag of 4 sub-models, ~1 GB total, cached on first use under `~/.cache/torch/hub/checkpoints/`.

See `references/model-choice.md` for why `htdemucs_ft` and not BS-RoFormer / Spleeter / MDX-Net. See `references/separation-limits.md` for what bleeds and why.

## Hand-off contract

The `stems.manifest.yaml` written by `handoff.py` matches the schema in `../stems-to-mixdown/references/manifest-schema.md`. Specifically:

- `source.type: separation` — non-mixdown manifest origin.
- `source.tool: demucs`, `source.model: htdemucs_ft` — provenance.
- `source.source_mix: { path, sha256 }` — link back to the truth.
- `classifications:` — explicit per-file mapping (`vocal.wav: vocal`, etc.). The downstream regex never needs to fire because the manifest is authoritative (`stems-to-mixdown` resolves manifest > regex > default).

This is the entire contract. No new fields in `analysis.json`. No changes to `stems-to-mixdown`.

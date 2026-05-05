# `stems-from-mix`

A separation engineer in script form, packaged as a Claude Code plugin. Reads a finished stereo mix, runs Demucs (htdemucs_ft) to estimate four stems, renames the outputs to match the regex contract of [`stems-to-mixdown`](../stems-to-mixdown/), and writes a hand-off manifest.

## What it does

```
finished-mix.wav
   ↓ (this skill, htdemucs_ft separation)
finished-mix-stems/
├── vox.wav
├── drums.wav
├── bass.wav
├── other.wav
└── stems.manifest.yaml      ← classifications + source provenance
   ↓ (stems-to-mixdown)
finished-mix-mixdowns/
├── finished-mix_acapella.flac
└── finished-mix_instrumental.flac
```

## Honest framing

- **Cmd S1 — Separation is approximation.** Bleed is real. Don't paper over it.
- **Cmd S2 — Keep the original mix.** The mix is truth; the stems are a lossy projection. The hand-off manifest records the source path and SHA so the chain stays auditable.
- **Cmd S3 — Don't master separation outputs.** Demos, remixes, karaoke, training data — yes. Release deliverables — no.

## Install

```bash
claude plugin marketplace add saldigioia/claude-plugins
claude plugin install stems-from-mix@rare-data-club
# Pair with the bouncing skill
claude plugin install stems-to-mixdown@rare-data-club
```

For local development:

```bash
claude --plugin-dir ./plugins/stems-from-mix --plugin-dir ./plugins/stems-to-mixdown
```

## Dependencies

| Tool | Install | Notes |
|---|---|---|
| `demucs` | `pip install demucs` | Brings PyTorch as a transitive dep (~2 GB on disk after first model download) |
| `ffmpeg` / `ffprobe` | `brew install ffmpeg` / `apt install ffmpeg` | For QC and any non-WAV transcoding |
| Python 3.9+ | system | |

Model: `htdemucs_ft` (a bag of 4 sub-models, ~1 GB total). Cached on first use under `~/.cache/torch/hub/checkpoints/`.

Device: defaults to MPS on Apple Silicon, CUDA when available, CPU otherwise. `--device cpu|mps|cuda` overrides.

## Why htdemucs_ft and not Spleeter / BS-RoFormer / MDX-Net

See `skills/stems-from-mix/references/model-choice.md`. Short version: htdemucs_ft is the open-source default that's actively maintained, runs locally, and performs within 0.5 dB SDR of the proprietary leader on MUSDB-HQ. Spleeter is abandoned (last update 2019); MDX-Net is good but heavier per stem; BS-RoFormer is the new SOTA but commercial-license-encumbered.

## Quick start

```bash
cd plugins/stems-from-mix

# Separation
python3 scripts/separate.py --input finished-mix.wav

# Optional QC (clipping check, integrity probe)
python3 scripts/verify.py --stems-dir finished-mix-stems

# Hand off
cd ../stems-to-mixdown
python3 scripts/identify.py --dir ../stems-from-mix/finished-mix-stems
python3 scripts/analyze.py --dir ../stems-from-mix/finished-mix-stems > a.json
python3 scripts/plan.py --analysis a.json > p.json
python3 scripts/mix.py --plan p.json --yes
```

## Layout

```
stems-from-mix/
├── .claude-plugin/
│   └── plugin.json
├── skills/
│   └── stems-from-mix/
│       ├── SKILL.md
│       └── references/
│           ├── model-choice.md
│           └── separation-limits.md
├── scripts/
│   ├── separate.py        # demucs wrapper
│   ├── verify.py          # post-separation QC
│   └── handoff.py         # writes the stems-to-mixdown manifest
├── tests/
│   └── test_handoff_and_verify.sh
├── LICENSE
└── README.md
```

## License

MIT — see [LICENSE](LICENSE).

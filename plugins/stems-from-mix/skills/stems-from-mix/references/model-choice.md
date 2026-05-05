# Model choice — why htdemucs_ft

The decision was made in `../../stems-to-mixdown/docs/research/2D-demucs-sibling.md` (live-verified 2026-05-05). The short version is below; the long version with sources is over there.

## Pick

**`htdemucs_ft`** (Hybrid Transformer Demucs, fine-tuned). Best general-purpose 4-stem (vocals/drums/bass/other) model in late 2025/early 2026 for a self-hosted, offline, permissively licensed stack.

## Why not the alternatives

| Model | MUSDB-HQ avg SDR | Vocals | Drums | Bass | Other | Why we didn't pick it |
|---|---|---|---|---|---|---|
| `htdemucs_ft` | **9.0 dB** | ~8.9 | ~9.5 | ~9.4 | ~6.4 | **Picked.** Single CLI, single weights download, four named outputs. |
| `htdemucs` (single) | ~7.7 dB | ~8.1 | ~8.4 | ~8.6 | ~5.9 | Faster (~4× the speed of `_ft`) but ~1.3 dB worse on average. Fine for previews if speed matters. |
| BS-RoFormer | ~9.8 dB | — | — | **~11.3** | — | Beats `htdemucs_ft` on bass, comparable elsewhere — but not packaged as a clean 4-stem CLI. Per-stem checkpoint assembly + xformers. Research-grade. Revisit when there's a single-CLI 4-stem RoFormer release. |
| MDX-Net (UVR successors) | ~9.2 (vocals) | ~9.2 | — | — | — | Comparable on vocals; ecosystem fragmented across UVR forks. Not a stable contract. |
| Spleeter | ~5.4 dB | ~5.9 | ~5.9 | ~5.5 | ~4.5 | Abandoned 2019. Skip. |

Sources: [2026-04-29 benchmark](https://dev.to/codesugar_lin_037a57b06a4/htdemucs-vs-bs-roformer-vs-spleeter-a-2026-audio-source-separation-benchmark-2ll8), [demucs repo](https://github.com/facebookresearch/demucs).

## Runtime

The benchmark's verified data point: **htdemucs_ft on a single Nvidia A40 separates a 3-minute song in 90–150 s end-to-end** (~1.2–2× real-time, including container startup). Other devices are operator-grade extrapolations — refine the table below the first time the skill ships on real hardware:

| Target | 3-min song, htdemucs_ft (4-bag) | Source |
|---|---|---|
| Apple Silicon CPU | ~6–10 min | extrapolation |
| Apple Silicon **MPS** | ~60–120 s | extrapolation |
| Nvidia A40 | **90–150 s** | benchmark, verified 2026-04-29 |
| Nvidia A100 | ~30–60 s | extrapolation |

`separate.py` defaults to MPS on Apple Silicon, CUDA when available, CPU otherwise. The `--device` flag overrides the auto-detection.

## Install footprint

- Package: `demucs` on PyPI, plus PyTorch (transitive). PyTorch ≥ 2.0; 2.1+ recommended for MPS stability.
- Model weights: `htdemucs_ft` is a bag of 4 sub-models cached at `~/.cache/torch/hub/checkpoints/`. The official repo doesn't publish the on-disk size; budget ~1 GB based on the v4 model architecture (single `htdemucs` is ~80 MB; `_ft` is the 4× bag).
- Demucs only accepts WAV input — non-WAV input must be transcoded upstream. `separate.py` doesn't do this transcoding today; if you point it at an MP3 it will surface demucs's error rather than silently re-encode.

## When to revisit

- BS-RoFormer ships a single-CLI 4-stem release with comparable polish.
- A new model surpasses htdemucs_ft on the `other` stem (the weakest at 6.4 dB SDR — `other` is the bin everything that isn't vocals/drums/bass falls into, so it's where the bleed shows up).
- Operator hardware shifts; the Apple Silicon MPS numbers above are extrapolations and should be replaced with measured data on the first real run.

The model choice is a pinned constant in `separate.py:DEFAULT_MODEL`. Bumping it is a one-line change plus a refresh of this doc.

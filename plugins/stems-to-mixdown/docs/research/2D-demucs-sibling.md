---
phase: 2
item: 2D
status: final
date: 2026-05-05
last_verified: 2026-05-05
---

# 2D — Demucs sibling skill (`stems-from-mix`)

## Question

If a user has only a finished mix and wants stems out of it, what model and contract should the sibling skill `stems-from-mix` use to hand off cleanly to `stems-to-mixdown`?

## Model decision

**Pick `htdemucs_ft` (Hybrid Transformer Demucs, fine-tuned).** Best general-purpose 4-stem (vocals/drums/bass/other) model as of 2026-05-05 for a self-hosted, offline, permissively licensed stack.

| Model | MUSDB-HQ SDR (avg) | Vocals | Drums | Bass | Other | Notes |
|---|---|---|---|---|---|---|
| `htdemucs_ft` (Demucs v4 FT) | **9.0 dB** ([demucs repo](https://github.com/facebookresearch/demucs)) | ~8.9 | ~9.5 | ~9.4 | ~6.4 | 4-model bag, ~4× slower than `htdemucs`. Default Sony/Meta release. |
| `htdemucs` (single) | ~7.7 dB | ~8.1 | ~8.4 | ~8.6 | ~5.9 | Faster, slightly worse. Fine for previews. |
| BS-RoFormer (MVSEP / ZFTurbo weights) | ~9.8 dB | — | — | **~11.3** | — | Beats htdemucs_ft on bass; per-stem; not a clean 4-stem CLI. |
| MDX-Net (UVR successors) | ~9.2 dB (vocals) | ~9.2 | — | — | — | Comparable on vocals; ecosystem fragmented across UVR forks. |
| Spleeter | ~5.4 dB | ~5.9 | ~5.9 | ~5.5 | ~4.5 | Abandoned 2019. Skip. |

Per-stem and aggregate numbers from the [2026 audio-source-separation benchmark](https://dev.to/codesugar_lin_037a57b06a4/htdemucs-vs-bs-roformer-vs-spleeter-a-2026-audio-source-separation-benchmark-2ll8) (published 2026-04-29, MUSDB-HQ test set). The 9.0 dB SDR figure for `htdemucs_ft` is corroborated by the [official demucs repo](https://github.com/facebookresearch/demucs).

**Why htdemucs_ft over BS-RoFormer for *this* skill:** `stems-from-mix` needs one CLI, one weights download, four named outputs, no GPU assumed. Demucs ships exactly that. BS-RoFormer wins on bass SDR but is per-source, not packaged as a clean 4-stem CLI; using it well requires assembling per-stem checkpoints and `xformers`. Revisit when there's a single-CLI 4-stem RoFormer release with comparable polish.

## Runtime / install

The verified data point is the [2026-04-29 benchmark](https://dev.to/codesugar_lin_037a57b06a4/htdemucs-vs-bs-roformer-vs-spleeter-a-2026-audio-source-separation-benchmark-2ll8): **htdemucs_ft on a single Nvidia A40 separates a 3-minute song in 90–150 s end-to-end** (~1.2–2× real-time, including container startup). The benchmark does not publish CPU or MPS numbers; the values below for those targets are operator-grade extrapolations the sibling skill should refine the first time it ships:

| Target | 3-min song, htdemucs_ft (4-bag) | Source / confidence |
|---|---|---|
| Apple Silicon CPU (M1/M2) | ~6–10 min | extrapolation; pure CPU PyTorch is roughly 20× slower than a discrete GPU on this workload |
| Apple Silicon **MPS** | ~60–120 s | extrapolation; some demucs ops fall back to CPU under MPS so M-series GPU never reaches A40 parity |
| Nvidia GPU (A40) | **90–150 s** | benchmark, verified 2026-04-29 |
| Nvidia GPU (A100) | ~30–60 s | extrapolation; ~2–3× A40 |

The first Phase-6 task should be benchmarking the sibling on whatever hardware Sal actually runs, then pinning the table here.

**Install footprint**

- Package: `demucs` on PyPI.
- Model weights: `htdemucs_ft` is a bag of 4 sub-models cached at `~/.cache/torch/hub/checkpoints/`. The official repo doesn't publish the on-disk size; expect ~1 GB total based on the v4 model architecture (single htdemucs is ~80 MB; ft is the 4× bag).
- Requires Python ≥ 3.8 per the demucs README; PyTorch 2.x recommended (2.1+ for MPS stability).
- Demucs only accepts WAV input — the sibling must transcode upstream MP3 / AAC inputs to WAV before invoking demucs.
- Default CLI: `demucs -n htdemucs_ft <input>` (full 4-stem) or `--two-stems=vocals` (acapella + instrumental). `-d cpu` / `-d mps` / `-d cuda` selects the device.

## Output-naming decision

Demucs writes `separated/<model>/<track>/{vocals,drums,bass,other}.wav`.

Existing regex in `scripts/analyze.py:52-55`:

```python
("vocal", r"\b(vox|vocal|lead|bg|chorus|adlib|harm|hook|rap|verse)\b")
("drums", r"\b(drum|kick|snare|hat|tom|perc|cymbal|ride|crash|clap|shaker|conga|808kit)\b")
("bass",  r"(\bbass\b|\bsub\b|\b808\b)")
```

| Demucs default | Matches existing regex? | Falls through to |
|---|---|---|
| `vocals` | **No** — `\bvocal\b` needs a word boundary between `l` and `s`; trailing `s` is a word char, no boundary. | `other` (broken) |
| `drums` | **No** — same issue | `other` (broken) |
| `bass` | Yes | `bass` (correct) |
| `other` | No (intentional) | `other` (correct) |

Confirmed empirically — `python3 -c "import re; ..."` against the live regex returns False for `vocals` and `drums` and True only for `bass`.

**Recommendation: rename on output in the sibling skill.** Demucs already gives ground-truth labels — we don't need the regex to find them. Sibling renames to `vocal.wav`, `drum.wav`, `bass.wav`, `other.wav` and also emits the manifest below (belt and suspenders). Do **not** widen `analyze.py`'s regex to accept plurals; strictness protects users who name multitrack stems carelessly.

## Hand-off manifest schema

Sibling writes `stems.manifest.yaml` next to the four WAVs. `stems-to-mixdown`'s manifest reader already honours `classifications` overrides (precedence `manifest > regex > default`).

```yaml
schema_version: 1
source:
  type: separation
  tool: demucs
  model: htdemucs_ft
  model_sha256: <hash of weights bag>
  source_mix:
    path: original/finished_mix.wav
    sha256: <hash>
  device: mps           # or cuda, cpu
  demucs_version: 4.x.y
classifications:
  vocal.wav: vocal
  drum.wav: drums
  bass.wav: bass
  other.wav: other
notes: |
  Separation outputs, not multitrack stems. Bleed and artefacts present.
  Sum is not bit-identical to the source mix; expect ~0.1–0.5 dB residual.
```

That is the entire contract. No new fields in `analysis.json`. No changes to `stems-to-mixdown`.

## Doctrine (separation-specific)

- **Bleed is real.** Separated stems contain residue of every other source. Approximations, not ground truth. Null-test against the original mix, not against zero.
- **Keep the original mix.** Retain the source mix alongside the stems. The mix is truth; stems are a lossy projection.
- **Spectrogram-check before delivery.** Inspect each stem (`sox spectrogram`, `ffmpeg showspectrumpic`, Audacity). Demucs sometimes leaks transients into `other` or smears reverb tails into `vocals`.
- **Do not master separation outputs.** Sketches, not deliverables. Acceptable for remixes, demos, karaoke, training data; not for release.

## Decision triggered

Phase 6 builds `stems-from-mix` against this spec: `htdemucs_ft`, MPS-aware, 4-stem default, renamed outputs, manifest emitted. Spec is build-time-recoverable — no API contract is locked until Phase 6 ships, so revisions before that point cost nothing.

## Sources

- [facebookresearch/demucs](https://github.com/facebookresearch/demucs) — model card; confirms 9.0 dB SDR for `htdemucs_ft` on MUSDB-HQ.
- [htdemucs vs BS-RoFormer vs Spleeter — 2026 benchmark](https://dev.to/codesugar_lin_037a57b06a4/htdemucs-vs-bs-roformer-vs-spleeter-a-2026-audio-source-separation-benchmark-2ll8) — per-stem SDR table and A40 runtime, published 2026-04-29.
- [Hybrid Transformers for Music Source Separation (Défossez et al., 2022)](https://arxiv.org/abs/2211.08553) — htdemucs paper.
- `REVIEW-2026-05.md` §4.3 — internal framing.
- Empirical regex confirmation against `scripts/analyze.py:52-55` and `scripts/identify.py:92-94`, 2026-05-05: `vocals.wav` and `drums.wav` both fall through to `other` because Python `\b` requires a non-word/word transition that the trailing `s` doesn't provide.

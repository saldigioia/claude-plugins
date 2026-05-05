# Separation limits — what bleeds and why

Demucs htdemucs_ft is the best general-purpose 4-stem separator available offline as of 2026-05-05. It is not perfect. This document is the operator's pre-flight on what the model will and won't get right, so a "clean separation" expectation doesn't survive contact with reality.

## What bleed actually means

Bleed is residual signal from one source appearing in another's stem. It's not a model bug; it's the inverse problem being underdetermined — the source mix is **one** signal, and the model is asked to factor it into four. There are infinitely many factorizations that sum to the original, and the model picks a plausible one. "Plausible" doesn't mean "correct."

Concrete examples on htdemucs_ft (typical material):

- **Vocal fricatives leak into `other`.** Sibilants at 6–10 kHz are spectrally close to cymbals; the model sometimes mis-routes them.
- **Hat tails smear into `vocal`.** Continuous high-frequency content with reverb sits in the vocal-band and the model treats the tail as breath.
- **Bass synth low-mids land in `drum`.** Sub-bass content with transient attack overlaps the kick's spectral fingerprint.
- **Reverb tails on the vocal end up in `other`.** The reverb is technically not the dry vocal source, so the model puts it somewhere else. This is correct by the model's definition and wrong by the operator's.

## What the model is good at

- Separating vocal from a moderately-dense pop / rap / R&B mix (vocals SDR ~8.9 dB on MUSDB-HQ).
- Separating drums when the drum kit is the dominant transient source.
- Separating bass when there is a clear, isolated bass source in the mix.

## What the model is bad at

- Densely-orchestrated material (orchestra, big band) — too many sources vying for the same spectral real estate.
- Heavy effects (vocoder, talkbox, autotune at high settings) — the model doesn't know what "vocal" looks like under those effects.
- Mono-summed mixes — the model is trained on stereo and uses spatial information; mono input is technically valid but the SDR drops.
- Amateur recordings with bleed already in the source — the model can't unbleed what came in bled.
- Short content (< 10 s) — there isn't enough context for the model's transformer to settle.

## How to spot artifacts

A spectrogram is the fastest diagnostic. `ffmpeg -i stem.wav -lavfi showspectrumpic out.png` produces a static spectrogram; visual inspection catches:

- **Phantom vocals in `drum`** — vocal formants visible as horizontal bands in the drum stem's spectrogram, especially in vowel passages.
- **Drum bleed in `vocal`** — kick/snare transients visible as vertical streaks at the song's tempo.
- **Reverb in `other`** — long horizontal tails after every vocal phrase.

Listening is more sensitive than measurement for these. The QC script (`scripts/verify.py`) catches clipping and full silence; it doesn't catch bleed. There is no algorithmic substitute for an engineer's ears here.

## When the source mix has a stem

If you have access to a pre-mastered version, an isolated vocal, or a published acapella, use them. They are always closer to truth than the demucs output. The right comparison is:

```bash
# Null-test the demucs output against a known clean version:
python3 ../stems-to-mixdown/scripts/verify.py \
    --plan p.json --reference known-acapella.wav
# Residual peak below -40 dBFS is good for separation work;
# below -90 dBFS is reserved for genuine multitrack stem comparisons.
```

The `null_test` ladder in `stems-to-mixdown/scripts/verify.py` (pass/smell/fail) was tuned for unity-sum mixdowns, not separation outputs. Expect "smell" verdicts on separation null-tests; "fail" doesn't necessarily mean the model was wrong — it might mean the reference was a different master.

## What this skill explicitly doesn't promise

- That the separated stems will null against any reference.
- That all four stems will be usable. `other` is often the bin where bleed lives; sometimes the right answer is "throw away `other` and keep only what works."
- That two runs on the same input will be byte-identical. PyTorch's nondeterminism on GPU + the htdemucs_ft bag-of-4 ensemble means small numerical differences are normal.

If the operator needs deterministic, byte-equivalent runs, set `--device cpu` and pin a torch seed via the demucs CLI's `--seed` flag (when it exists in your demucs version). This trades runtime for reproducibility.

## Doctrine pointer

Cmd S1: bleed is real. The operator decides whether the bleed is acceptable; the skill surfaces the limits and gets out of the way.

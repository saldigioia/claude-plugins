# tests/fixtures/mixed-rates

Two stems with mismatched rates and one lossy:

| File | Codec | Rate | Depth | Channels | Classification |
|---|---|---|---|---|---|
| `synth_lead.wav` | pcm_s24le | 96 kHz | 24-bit | stereo | `other` |
| `bass.mp3` | mp3 V2 | 44.1 kHz | lossy | stereo | `bass` |

Exercises the **lossy-in-chain + rate-mismatch** path of the format-decision matrix:

- Pass 2 fires `rate_mismatch` (error) and `lossy_input` (warn).
- Pass 3 default plan caps output at 16-bit / 44.1 kHz FLAC (lossy in chain → ceiling).
- The 96 kHz lossless stem is downsampled to 44.1 kHz with `aresample=resampler=soxr:precision=28`.
- No mono stems → no `pan_law_default_assumed` warning.
- Both stems are stereo so `pan` filter is bypassed.

`analyze.py` exits 1 by default because of the `rate_mismatch` error; `--force` overrides.

# tests/fixtures/24-in-32

One 32-bit-container WAV (single mono sine, 48 kHz):

| File | Codec | Rate | Depth | Channels | Notes |
|---|---|---|---|---|---|
| `lead_24in32.wav` | pcm_s32le | 48 kHz | 32-bit (per ffprobe `bits_per_raw_sample`) | mono | Synthesized via `ffmpeg -c:a pcm_s32le` |

**What this fixture exercises:** the 32-bit-lossless input path through analyze → plan → mix. With one mono stem and one auto group (no `vocal` regex match → falls into `instrumental`), the plan emits 48 kHz / 32-bit FLAC and exercises `-bits_per_raw_sample 32` / `-sample_fmt s32` on the encoder.

**What it does NOT exercise:** the `bit_depth_uncertain` warn path. Genuine 24-in-32 WAVs have `wValidBitsPerSample = 24` in a `WAVE_FORMAT_EXTENSIBLE` fmt chunk, which `ffmpeg`'s PCM encoder doesn't write by default. Producing such a file requires `sox`, `BWF MetaEdit`, or a hex-edited header; out of scope for synthesized fixtures. The wavinfo-disambiguation path is verified by inspection of `scripts/analyze.py` (lines 460–477, see `enrich_with_wavinfo`); a real-world test would need an authored 24-in-32 WAV from a session export.

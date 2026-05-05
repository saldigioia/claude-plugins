# tests/fixtures/dirty-inputs

Three stems with sanity-check pathologies:

| File | Codec | Rate | Depth | Channels | Pathology |
|---|---|---|---|---|---|
| `dc_offset_stem.wav` | pcm_s24le | 48 kHz | 24-bit | mono | DC offset injected via `aeval=val(0)+0.05` |
| `silent_stem.wav` | pcm_s24le | 48 kHz | 24-bit | stereo | Fully silent |
| `vox_lead.wav` | pcm_s24le | 48 kHz | 24-bit | mono | Clean — keeps the group non-empty |

Exercises Pass 2 sanity flags:

- `dc_offset` warn on `dc_offset_stem.wav` (DC ≈ 0.05 > 0.001 threshold).
- `silent_file` warn on `silent_stem.wav`.
- `pan_law_default_assumed` warn (mono stems present, manifest unset).
- No errors — only warnings — so `analyze.py` exits 0.

`vox_lead.wav` triggers the `vocal` classification → automatic `acapella` group.

# Fixture: `with-master`

Three short stereo stems plus a hand-crafted master that is the unity sum of the
three. Exercises the master-reference pipeline (Cmd 19): bundle planning,
bundle execution, and the Pass 5 reference battery (recombine null, two
inverse-stems nulls, per-deliverable LUFS-I/dBTP deltas).

The recombine null residual should be very low (≤ -90 dBFS within dither
noise) because the master is mathematically the sum of the stems.

## Files

- `vox_lead.wav` — 440 Hz sine, 2 s, 48 kHz, 24-bit, stereo
- `bass.wav` — 110 Hz sine, 2 s, 48 kHz, 24-bit, stereo
- `drums.wav` — noise burst, 2 s, 48 kHz, 24-bit, stereo
- `song_master.flac` — `(vox + bass + drums)` summed at unity, 24-bit/48k FLAC
- `stems.manifest.yaml` — opts into the master reference

## Pass 1+2 expectations

- 3 stems classified: `vocal`, `bass`, `other` (noise → other)
- master_reference present in analysis.json
- No errors. The default-pan-law warn does NOT fire (stems are stereo).

## Pass 3 expectations

- Two groups: `acapella` (vox_lead) and `instrumental` (bass + drums).
- Format: 24-bit / 48 kHz / FLAC.
- `reference_bundle` populated; bundle dir = `<source>/../with-master-mixdowns/reference-bundle/`.

## Pass 4 expectations

- Canonical mixdowns produced.
- Bundle directory contains `with-master_master.flac`,
  `with-master_acapella.flac`, `with-master_instrumental.flac`.
- `bundle.log.md` sidecar present.

## Pass 5 expectations

- All canonical verifications pass.
- Reference battery runs:
  - `recombine` verdict = `pass` (≤ -90 dBTP residual).
  - `inverse_acapella` verdict = `pass` or `smell`.
  - `inverse_instrumental` verdict = `pass` or `smell`.
  - Headline verdict = `pass`.

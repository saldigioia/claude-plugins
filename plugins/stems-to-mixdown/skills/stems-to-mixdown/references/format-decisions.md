# Format Decisions

The full input-situation → output-format matrix. This is the spec Pass 3 (`plan.py`) implements. When the rules conflict with what the user wants, the rules win and the script explains why.

The governing principle: **the source is the ceiling**. The output cannot honestly claim more fidelity than the inputs supplied. Every entry below is a corollary of that one rule.

---

## Decision matrix

| Input situation | Default output | Rationale |
|---|---|---|
| All lossless, all same rate, all same bit depth | FLAC at input rate / input depth | Native fidelity preserved end to end. |
| All lossless, all same rate, **mixed** bit depths | FLAC at input rate / **smallest** input depth | Bit-depth math going up is a no-op; going down is a discard. Smallest depth is the honest common denominator. |
| All lossless, **mixed** rates, same depth | FLAC at **highest** common rate / input depth, with `aresample=resampler=soxr:precision=28` on the lower-rate stems | Upsampling existing samples is mathematically a no-op transform (zero-padding the spectrum); downsampling discards information. Going up is conservative; going down is destructive. The skill flags the rate disagreement as a Pass 2 red flag — proceeding requires `--force` because rate disagreement among supposed siblings is almost always a production bug worth surfacing. |
| All lossless, mixed rates, mixed depths | FLAC at highest common rate / smallest common depth | Combine the two rules above. |
| **Any lossy input present** (MP3, AAC, OGG, etc.) | 16-bit / 44.1 kHz FLAC | The deliverable refuses to imply more precision than the lossy source supports. The lossy compression has already discarded frequency content and applied perceptual coding; pretending the sum is 24/96 material is dishonest. 16/44.1 is the honest floor. |
| Any lossy input + user explicitly requests MP3 output | MP3 V0 (variable bit rate, highest LAME quality) | This is the one allowed lossy → lossy path. Logged as a second-generation encode. |
| User requests output rate or depth **higher than any input supports** | Refuse, print explanation citing Commandment 1 | Use `--lie` to override (named that on purpose; output filename gets `.degenerate` suffix; log records the decision). For testing, not production. |
| All inputs already at user's requested output format | Match exactly | Don't re-encode a file when no change is needed. Skip the format conversion if the math allows. |

---

## Predicted-peak handling

Independent of format decisions, every plan includes a measured prediction of the mixdown peak:

1. Build the planned filter graph (with weights all at 1.0, no pre-attenuation yet).
2. Run it to a null sink at 32-bit float intermediate.
3. Measure true peak via `ebur128 peak=true`.

| Measured peak | Action |
|---|---|
| Below -3 dBTP | Sum as-is, no pre-attenuation. |
| -3 to -1 dBTP | Sum as-is, log a warning. Within acceptable range. |
| -1 to 0 dBTP | Pre-attenuate uniformly to land at -3 dBTP. |
| Above 0 dBTP | Pre-attenuate uniformly to land at -3 dBTP, flag prominently in the plan. The sum is hot; the user should look at why. |

Pre-attenuation is uniform across all stems within a group — preserves relative balance. The dB amount is computed as `-(measured_peak + 3.0)` and applied via `volume=<n>dB` in the per-stem filter chain before the `amix`.

---

## Channel-count reconciliation

Independent of format, channels are reconciled before the sum:

| Input mix | Output channels | How |
|---|---|---|
| All mono | Stereo (mono content centered) | Each stem upmixed via `pan=stereo|c0=K*c0|c1=K*c0` with `K = 10 ** (pan_law_db / 20)`. |
| All stereo | Stereo | Pass-through. |
| Mixed mono + stereo | Stereo | Mono stems upmixed via `pan=stereo|c0=K*c0|c1=K*c0` (see Pan law); stereo stems untouched. |
| Multichannel input present (>2 channels) | **Refuse** | Out of scope. The skill is not a downmix tool; multichannel → stereo is a creative decision involving downmix coefficients and is handled elsewhere. |

---

## Pan law

A mono stem panned to center is **not** copied at full level into both L and R. Every DAW applies a per-channel attenuation (the "pan law") so the same content panned center doesn't sum +3 dB hotter than the same content panned hard. This skill applies the law as a per-channel coefficient in the `pan` filter:

```
K = 10 ** (pan_law_db / 20)
pan=stereo|c0=K*c0|c1=K*c0
```

| `pan_law_db` | Coefficient `K` | Convention |
|---|---|---|
| `0.0` | 1.0000 | Legacy / naïve `pan=stereo|c0=c0|c1=c0`. **+3 dB hotter than any DAW.** |
| `-2.5` | 0.7499 | Pro Tools default |
| `-3.0` | 0.7079 | Logic / Cubase default. **This skill's default when manifest is silent.** |
| `-4.5` | 0.5957 | Pro Tools "-4.5 dB" option |
| `-6.0` | 0.5012 | Older film-sound and broadcast convention |

The default is `-3.0` because Logic / Cubase default to it, REAPER's modern default is configurable but usually `-3.0`, and -3 dB happens to be the equal-RMS-power center pan, which is the sanest default for technical sums. Pro Tools' `-2.5 dB` is available because Pro Tools shops will want their bounce to null against a Pro Tools session; `-2.5` is the right answer there.

Set `output.pan_law` in the manifest to declare the choice. When the field is absent and any mono stems are present, Pass 2 fires `pan_law_default_assumed` so the operator knows what coefficient is about to apply. Stereo stems pass through unchanged regardless of `pan_law`.

See Commandment 16.

---

## Project name and file naming

Project name source, in priority order:

1. `project:` field in `stems.manifest.yaml` if present.
2. Directory basename of the input directory.

Output filenames default to a **sibling** directory of the source — the source folder itself is never written into (Cmd 18, Cmd 13):

```
<source-dir>/../<source-dirname>-mixdowns/<project>_<group>.<ext>
```

`plan.py --output-dir <path>` overrides; passing `<source-dir>/mixdowns` reproduces the legacy in-source layout.

Examples:

- `~/sessions/the-college-dropout-stems/` with vocal stems → `~/sessions/the-college-dropout-stems-mixdowns/the-college-dropout-stems_acapella.flac` and `..._instrumental.flac`.
- Manifest specifies `project: tcd-2003`, custom group `drums-only` → `~/sessions/the-college-dropout-stems-mixdowns/tcd-2003_drums-only.flac`.

Sidecar log: same path with `.log.md` appended (e.g., `tcd-2003_acapella.flac.log.md`). The `.log.md` includes ext deliberately so the log clearly belongs to that specific output, not a sibling.

---

## What gets written into the FLAC tags

Preserved from input metadata when consistent across all stems in the group:

- `ARTIST`
- `ALBUM`
- `DATE`
- `GENRE`

Set by the skill:

- `TITLE` — `<project> (<group>)` e.g. `tcd-2003 (acapella)`
- `COMMENT` — `Mixed by stems-to-mixdown skill v<version> on <ISO date>. See sidecar log.`
- `ENCODER` — `ffmpeg <version>`

Never invented:

- `ISRC`
- `BARCODE`
- `MUSICBRAINZ_*`

If input metadata is inconsistent across stems (different artist tags on different stems), the script flags it in the plan and writes nothing to that field rather than picking arbitrarily.

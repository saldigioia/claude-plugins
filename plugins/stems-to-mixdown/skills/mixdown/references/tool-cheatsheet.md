# Tool Cheatsheet

Every command in this file has been validated against the actual man pages. Memory lies; flags drift between versions; the only reliable source is the tool itself. When you go to extend the skill, **re-validate** before adding anything new — don't trust this file blindly past its commit date.

Tooling: `ffmpeg`, `ffprobe`, `sox`. Engine choice for the mix itself: **ffmpeg**. Sox is used only for input inspection and one-off measurements where its output format is more convenient.

---

## Inspection

### Full probe (machine-readable)

```bash
ffprobe -v error -show_streams -show_format -of json "$file"
```

Returns codec, sample_rate, channels, channel_layout, bit_rate, sample_fmt, bits_per_raw_sample, duration, format_name, tags. Parse the first audio stream (`streams[?codec_type=='audio']`).

**Watch out:** `bit_rate` on the format may differ from the audio stream's bit rate, especially for variable bit rate lossy. Check both.

### Sox quick-look (human-readable)

```bash
sox --i "$file"
```

Useful for sanity-checking what ffprobe reported. The two should agree on rate / channels / duration; if they don't, something is structurally weird about the file.

### Sample / file integrity stats

```bash
ffmpeg -i "$file" -af astats=metadata=1:reset=0 -f null - 2>&1
```

Reports per-channel: peak level, RMS, DC offset, min/max sample, number of samples, number of NaNs, dynamic range, crest factor. Parse from stderr.

For DC offset specifically:

```bash
ffmpeg -i "$file" -af astats -f null - 2>&1 | grep "DC offset"
```

DC offset beyond ±0.001 (-60 dBFS roughly) is a red flag — almost always indicates an analog-stage problem upstream, and it eats headroom for free.

### True-peak measurement (ITU-R BS.1770)

```bash
ffmpeg -i "$file" -af ebur128=peak=true -f null - 2>&1
```

Stderr at the end contains a "Summary:" block with `Integrated loudness` (LUFS-I), `Loudness range` (LRA), and `True peak` (dBTP). Parse with regex on stderr.

**Critical:** the `peak=true` flag enables the inter-sample true-peak measurement. Without it, you get sample peak, which is not the same number and is not what you want.

---

## Mixing

### The unity-sum incantation

```bash
ffmpeg \
  -i "stem1.wav" -i "stem2.wav" -i "stem3.wav" \
  -filter_complex "[0:a][1:a][2:a]amix=inputs=3:duration=longest:normalize=0:weights=1 1 1[mix]" \
  -map "[mix]" \
  -sample_fmt flt \
  -c:a pcm_f32le \
  -f wav \
  "intermediate.wav"
```

The five things that matter:

1. `inputs=N` — must match the count of streams piped into the filter.
2. `duration=longest` — preserve all tails.
3. `normalize=0` — **do not divide by input count**. This is the difference between a unity sum and a mystery scaling.
4. `weights=1 1 1 ...` — explicit per-input weights. Always 1.0 unless pre-attenuation is being applied (see below).
5. `-sample_fmt flt` and `-c:a pcm_f32le` — 32-bit float intermediate. Bit depth reduction happens at final encode, not during summing.

### Pre-sum attenuation (uniform across stems)

When measurement says the sum exceeds -1 dBTP, attenuate all inputs by the same dB amount before summing — preserves relative balance. Example for -3 dB attenuation:

```bash
-filter_complex "[0:a]volume=-3dB[a0];[1:a]volume=-3dB[a1];[2:a]volume=-3dB[a2];[a0][a1][a2]amix=inputs=3:duration=longest:normalize=0:weights=1 1 1[mix]"
```

Attenuating after the sum (using `volume` on `[mix]`) is mathematically equivalent for linear signals but conceptually wrong — it implies the sum was hot and we're rescuing it post-hoc. Pre-sum makes the intent explicit.

### Mono input, stereo output (center pan)

A mono stem in a stereo group needs to be upmixed to stereo with the signal at center. Don't just duplicate the channel — use pan with a pan-law coefficient:

```bash
# K = 10 ** (pan_law_db / 20); -3 dB → 0.707946; -2.5 dB → 0.749894; 0 dB → 1.0
-filter_complex "[0:a]pan=stereo|c0=0.707946*c0|c1=0.707946*c0[stereo0];..."
```

The coefficient is the per-channel attenuation that implements the chosen pan law. The skill defaults to `-3.0 dB` (Logic / Cubase convention; equal-RMS-power center pan); the manifest's `output.pan_law` field overrides. **The legacy `pan=stereo|c0=c0|c1=c0` (no coefficient) is `0 dB pan law` and produces a center sum +3 dB hotter than any DAW-equivalent bounce — it is never the right default.** See Commandment 16 and `references/format-decisions.md`.

### Channel-count reconciliation

When stems disagree on channel count (some mono, some stereo), reconcile by upmixing all mono stems to stereo before the sum. Stereo stems pass through untouched. The check happens in Pass 2 and the upmix happens in Pass 4's filter graph.

---

## Resampling

Used only when stems disagree on rate and the user has approved proceeding. Target rate: highest common rate among inputs.

```bash
-filter_complex "[0:a]aresample=resampler=soxr:precision=28:osr=48000[r0];..."
```

`soxr` precision 28 is the highest-quality option. Lower precisions exist; we don't use them. CPU cost is real but the skill is not in the inner loop of anything realtime — quality wins.

---

## Final encode (with dither when reducing depth)

### FLAC at native intermediate depth

```bash
ffmpeg -i "intermediate.wav" -c:a flac -compression_level 8 "final.flac"
```

If intermediate is 32-bit float and target is 24-bit FLAC, ffmpeg handles the float→int conversion. No dither needed when going to 24-bit (the noise floor of 24-bit is below the noise floor of any real signal — dither at 24-bit is a religious argument we sidestep).

### FLAC reducing to 16-bit (dither required)

```bash
ffmpeg -i "intermediate.wav" \
  -af "aresample=osf=s16:dither_method=triangular_hp" \
  -c:a flac -compression_level 8 "final.flac"
```

`triangular_hp` is high-pass triangular dither — noise-shaped to push dither energy out of the most ear-sensitive bands. `triangular` (without `_hp`) is acceptable but less optimal. `rectangular` is forbidden (correlated with signal at low levels — defeats the point).

### MP3 V0 (lossy, single generation only)

```bash
ffmpeg -i "intermediate.wav" \
  -af "aresample=osf=s16:dither_method=triangular_hp" \
  -c:a libmp3lame -q:a 0 "final.mp3"
```

V0 is variable-bit-rate, ~245 kbps average, the highest quality LAME setting. Used only when the user explicitly asks for MP3 output and the inputs were already lossy.

### WAV / AIFF (PCM)

```bash
ffmpeg -i "intermediate.wav" -c:a pcm_s24le "final.wav"   # 24-bit
ffmpeg -i "intermediate.wav" -c:a pcm_s16le -af "aresample=osf=s16:dither_method=triangular_hp" "final.wav"   # 16-bit with dither
ffmpeg -i "intermediate.wav" -c:a pcm_s24be -f aiff "final.aiff"   # AIFF is big-endian PCM
```

---

## Verification

### Re-probe (Pass 5)

Same `ffprobe ... -of json` invocation as inspection. Compare the resulting fields to `plan.json` — codec, rate, depth, channels must match exactly.

### Null test against a reference

If `--reference <file>` is supplied:

```bash
ffmpeg -i "skill_output.flac" -i "reference.flac" \
  -filter_complex "[1:a]volume=-1.0[ref];[0:a][ref]amix=inputs=2:duration=longest:normalize=0:weights=1 1[null]" \
  -map "[null]" -af "ebur128=peak=true" -f null - 2>&1
```

`volume=-1.0` is multiplication by -1 (polarity inversion), not -1 dB. Sum the inverted reference with the skill's output and measure the residual true peak. Below -90 dBFS = pass within dither noise. -60 to -90 = something is subtly different (maybe dither method, maybe a sample-level offset). Above -60 = something is structurally wrong.

---

## What we deliberately do not use

- **`amix` without `normalize=0`** — divides by input count, destroys gain staging.
- **`amerge`** — interleaves channels rather than summing them. Different operation, different use case (combining mono stems into a multichannel file, not summing them into a stereo mixdown).
- **`sox --norm`** — post-hoc normalization. Conflates "fits without clipping" with "is at the right level."
- **`sox --guard`** — preemptive attenuation to prevent clipping. Better than `--norm` but still not unity sum: it scales the result down by whatever amount is needed to fit, with no record of how much. We want known, measured, intentional gain decisions.
- **`loudnorm`** — automatic loudness normalization. Useful tool for the right job; this is not the right job. The mix bus is not where loudness targets get set.
- **Sample-peak measurement (`astats peak`)** — uses raw sample peak, not true peak. We use `ebur128 peak=true` exclusively.

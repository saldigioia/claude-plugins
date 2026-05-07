# Decision: Cmd 9 revised — default deliverable is normalized

_Recorded 2026-05-07. Implemented in v1.3.0._

## Context

Through v1.2 the plugin's identity was built on Commandment 9, which read (paraphrased): "Loudness normalization is not mastering. The skill measures LUFS; it doesn't target it." The canonical mixdown shipped at unity sum — typically -22 to -28 LUFS-I depending on the source material — and the operator was responsible for normalizing the file before sharing it. A `--preview` flag (Cmd 17) produced a sidecar listening copy at -14 LUFS-I, but the operator was explicitly told the preview was not the deliverable.

The friction this created in real archival use:

1. The plugin's primary user (per the original review) is not a mixing engineer. Handing them a -25 LUFS unity-sum FLAC asks them to know how to normalize before sharing — exactly the friction the plugin was supposed to remove.
2. "Unity sum" is not the same as "no processing." The pipeline already applies pre-attenuation (Cmd 3), pan-law gain on every mono stem (Cmd 16), and triangular-PDF dither at any 16-bit reduction (Cmd 5). Pretending the unity-sum is "raw" or "untouched" overstates the plugin's hands-off-ness.
3. The two existing escape hatches (`--preview` Cmd 17 + the `loudnorm` listening copy) were confusing because they produced a sidecar file that the operator was told not to ship. A user asking the plugin "give me a file I can play back" got two files and a footnote about which one to share.
4. Streaming consensus has converged. Spotify, YouTube, Tidal, Amazon Music, TikTok, and Instagram all normalize incoming masters to -14 LUFS-I. Apple Music's Sound Check sits at -16. EBU R128 broadcast sits at -23. A single master at -14 LUFS-I with a -1 dBTP true-peak ceiling plays back at a sensible volume on every major platform without requiring per-platform versions.

## Decision

Cmd 9 is rewritten to make the default deliverable a normalized listening master, while keeping mastering (creative EQ, dynamics, character) structurally out of scope:

> **§9. Loudness normalization is not mastering — but the deliverable should be listenable.** _Revised in v1.3._ EBU R128 (the LUFS measurement standard) is a measurement discipline. The mix bus is not the place to do EQ, compression, multiband processing, or creative limiting — that's mastering, and the skill still refuses to do any of it. But shipping a unity-sum file at -22 to -28 LUFS-I, which is what most archival multitracks sum to before any conditioning, asks the operator to know how to normalize before sharing — exactly the friction this plugin exists to remove. The 2025–2026 streaming consensus (Spotify / YouTube / Tidal / Amazon at -14 LUFS-I, Apple Music at -16, EBU R128 broadcast at -23) is converged enough that a single-target normalization at -14 LUFS-I with a -1 dBTP true-peak ceiling produces a file that plays back at a sensible volume on every major platform, off-platform, and against any reference track in the operator's library, without touching dynamics or spectrum.
>
> **Behavioral consequence:** The default deliverable is a normalized listening master. After the unity-sum stage produces a 32-bit float intermediate, two-pass `loudnorm` (gain-only, `linear=true`) brings the integrated loudness to `output.target_lufs` (default -14, allowed -14 / -16 / -23) and a true-peak limiter (`alimiter`, `level=disabled`) clamps to `output.target_true_peak` (default -1.0 dBTP, allowed -1.0 / -1.5 / -2.0). No EQ, no compression, no spectral processing — strictly loudness conditioning. Operators who need bit-exact unity-sum output (null tests, archival masters intended for further processing) pass `--archival` (or set `output.archival: true` in the manifest) and get the v1.2 behavior byte-for-byte. The reference bundle (Cmd 19) keeps using unity-sum internally regardless of the canonical's normalization state, because null tests against the master only work on unprocessed signals; a separate `<project>_master_listening.<ext>` is produced alongside the canonicals as a normalized version of the master itself. Mastering — creative EQ, dynamics, character — remains structurally out of scope.

## Why -14 LUFS-I + -1 dBTP

A single master at -14 plays back unchanged on Spotify, YouTube, Tidal, Amazon, TikTok, and Instagram, and gets quieted by ~2 dB by Apple Music's Sound Check (which reads as fine to most listeners). A single master at -16 — the natural Apple-first choice — gets boosted by 2 dB by every other platform, eating into the headroom against the -1 dBTP ceiling and producing more inter-sample peaks after AAC transcoding. -14 is therefore the most-compatible single answer; -16 is exposed as `--target-lufs -16` for Apple-first delivery, and -23 for EBU R128 broadcast.

The -1 dBTP true-peak ceiling is the modern standard from the AES streaming-loudness recommendation: 1 dB of headroom above the highest reconstructed analog peak, accounting for inter-sample peaks introduced by lossy transcoding (AAC, Ogg). -1.5 and -2.0 are exposed for conservative AAC headroom and ATSC A/85 broadcast respectively.

Two-pass loudnorm (first pass measures, second pass applies the calibrated gain via `linear=true`) is used for accuracy — single-pass loudnorm hits within ~1 LU and is fine for a listening copy, but the canonical deliverable warrants the second pass. Per Ian Shepherd's repeated reminder ("Why LUFS Don't Matter As Much As You Think," March 2025), anything within ±2 LU of the target sounds the same after platform normalization, so the precision is precaution rather than necessity.

## Why preserve unity-sum behavior

Three reasons the v1.2 unity-sum path stays available bit-for-bit behind `--archival`:

1. **Null testing.** When a master reference is declared (Cmd 19), the recombine null `(instrumental + acapella) - master` only works on unprocessed signals. Normalized files cannot null against an un-normalized master. The reference bundle inside `reference-bundle/` always uses unity-sum internally regardless of the canonical's mode.
2. **Downstream mastering.** Operators who plan to feed the bounce into a mastering chain need the unity-sum file, not a pre-normalized one. Two consecutive normalization passes produce worse results than one.
3. **Archival reproducibility.** The v1.2 audio-MD5 baselines exist; they're correct for what they assert; they should keep passing. `--archival` is the path under which they pass.

## Why no spectral / dynamic processing

Cmd 9's revision adds loudness conditioning to scope, not mastering. The distinction:

- **Loudness conditioning** is gain — applied uniformly across time and frequency, with a true-peak limiter as insurance. Two operations: a single gain coefficient from loudnorm's measurement, and a peak ceiling from alimiter. Both are deterministic, neither alters relative balance between stems, neither modifies the spectrum.
- **Mastering** is creative judgment — EQ to taste, multiband compression to glue elements, transient shaping, harmonic excitation, character chains. None of that fits in a scriptable archival pipeline; it requires ears and intent.

The plugin produces the first; it refuses to produce the second. `--archival` short-circuits even the conditioning, restoring the unity-sum.

## Sources consulted (last 9 months)

Streaming-loudness landscape:
- [Spotify — Loudness normalization](https://support.spotify.com/us/artists/article/loudness-normalization/)
- [iZotope — How to master for streaming platforms](https://www.izotope.com/en/learn/mastering-for-streaming-platforms.html) (2025)
- [Soundplate — The Ultimate Guide to Streaming Loudness (LUFS Table 2026)](https://soundplate.com/streaming-loudness-lufs-table/)
- [Sean Kim — Loudness Mastering Streaming Platforms: Complete 2026 LUFS Standards Guide](https://blog.imseankim.com/loudness-mastering-lufs-streaming-platforms-spotify-apple-music-2026/)

True-peak / inter-sample peak:
- [Mat Leffler-Schulman — True Peak vs Inter-Sample Peaks](https://matlefflerschulman.com/mastering-articles/true-peak-vs-inter-sample-peaks)
- [Mixing Lessons — True peak: why your songs should never peak above -1 dBTP](https://www.mixinglessons.com/dbtp-decibel-true-peak/)

Pragmatic perspective:
- [Ian Shepherd — Why LUFS Don't Matter As Much As You Think (The Mastering Show ep. 186, March 2025)](https://podcasts.apple.com/gb/podcast/186-why-lufs-dont-matter-as-much-as-you-think-with-ian/id1551795483?i=1000699602786)
- [Sound on Sound — Ian Shepherd On Loudness & Dynamics](https://www.soundonsound.com/techniques/ian-shepherd-loudness-dynamics)
- [Lost Stories Academy — Why Mastering for Streaming is Different in 2025](https://www.loststoriesacademy.com/blogs-and-tutorials/why-mastering-for-streaming-is-different-in-2025)

## What this changes operationally

- Default deliverable bytes change for every existing fixture and every existing user folder (a one-time invalidation; cached unity-sum outputs are still reachable via `--archival`).
- The `--preview` flag becomes redundant; `run.py` no longer forwards it, and the canonical IS the listening copy. `mix.py --preview` remains as a back-compat curiosity.
- Reference bundle behavior is unchanged on disk in `--archival` mode. When normalized, the bundle's `instrumental.flac` and `acapella.flac` are unity-sum re-renders from the original stems — byte-identical to what v1.2 would have produced.
- A new `<project>_master_listening.<ext>` appears alongside the canonicals when both normalization is on and a master is present. The original master file is never modified.

## What's still out of scope

Cmd 9's revision narrows the "out of scope" boundary; it does not eliminate it. Still refused:

- Equalization (mastering EQ, corrective EQ, tilt EQ).
- Dynamic processing other than the true-peak limiter (compression, multiband, sidechain, expansion).
- Spectral processing (harmonic excitation, exciter, saturator).
- Creative limiting (anything that knowingly distorts to gain perceived loudness — the alimiter pass is set to `level=disabled` precisely to avoid this).
- Per-platform output variants (the plugin produces a single master that's broadly compatible; per-platform mastering is a separate workflow).
- Anything else that would require taste rather than measurement.

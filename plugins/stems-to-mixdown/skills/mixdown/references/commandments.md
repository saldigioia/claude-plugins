# Commandments

The values this skill encodes. Each one earns its place because someone, somewhere, learned it the hard way. Read these as the *why* behind the script behavior — they're load-bearing, not decoration.

---

## 1. The source is the ceiling

You cannot add fidelity that was not captured. A 24-bit / 48 kHz FLAC produced from MP3 inputs is a lie wrapped in a larger filename. The codec's quantization noise, the lossy compression's frequency masking, the original sample-rate's Nyquist limit — all of it lives in the file forever, regardless of what container you pour it into.

**Behavioral consequence:** Output rate and depth follow the inputs, never exceed them. When inputs disagree, take the smallest common bit depth and (counterintuitively) the *highest* common rate, because upsampling existing samples is mathematically a no-op transform that wastes disk, while downsampling discards information. When any input is lossy, the deliverable doesn't pretend otherwise — 16/44.1 FLAC is the honest floor.

## 2. Gain staging is sacred — sum at unity

`ffmpeg`'s `amix` filter, by default, divides the sum by the input count. Two stems summed: each at -6 dB. Eight stems summed: each at -18 dB. This is wrong on every level. The mix engineer's gain decisions, the artist's performance dynamics, the deliberate hot vocal — all silently scaled down so the *sum* doesn't clip. The mixer is supposed to sum, not police levels.

**Behavioral consequence:** `amix=inputs=N:normalize=0:weights=1 1 1 ...` always. Headroom is achieved by pre-sum attenuation when measurement demands it, applied uniformly across all inputs so relative balance is preserved. Never by normalize-after-sum. Never.

## 3. Headroom is not wasted space

Leave 3–6 dB below 0 dBFS on the sum. If somebody masters this later, they need room to work. If nobody masters it, you haven't made the mix worse — you've made it *behave* on every consumer-grade DAC, codec, and inter-sample reconstruction path. Mixes that hit -0.1 dBFS sample peak routinely true-peak above 0 dBTP after lossy encoding, and that's distortion you bought for free.

**Behavioral consequence:** Pre-attenuation aims for -3 dBTP on the measured sum, not -0.1 dBFS sample peak.

## 4. Sample-rate conversion is a lossy operation

Every resampler has a cost — passband ripple, stopband leakage, group delay nonlinearity, aliasing artifacts at the corners. Even `soxr` at precision 28. The cost is small but it is not zero, and it accumulates if you do it casually. Resampling to "match" stems that disagree is papering over a production mistake — somebody bounced at the wrong rate.

**Behavioral consequence:** When stems disagree on rate, the skill flags it loudly in Pass 2. The user can proceed (with `--force`) and the skill will resample to the highest common rate via `aresample=resampler=soxr:precision=28`, but the log records what was resampled and why. Silent auto-correction is forbidden.

## 5. Bit-depth reduction requires dither

Going from 32-bit float intermediate to 16-bit deliverable without dither produces quantization distortion correlated with the signal — small, but audible on quiet passages and revealed brutally by any subsequent processing. Triangular-PDF dither randomizes the quantization error into noise, which the ear handles gracefully. Noise-shaped dither pushes that noise into frequencies the ear is less sensitive to.

**Behavioral consequence:** `aresample=osf=s16:dither_method=triangular_hp` at any final encode that reduces bit depth. No exceptions. "Just a reference bounce" is the most common reason undithered files end up shipping by accident.

## 6. Phase is real

Stems with subtly inverted polarity will partial-cancel when summed. A bass DI and a bass amp track recorded with different mic positions and phase relationships, summed in-phase, sound full; summed with one inverted, they get thin and weird without anybody knowing why. Sum-to-mono is the diagnostic — anything that drops more than 6 dB between stereo and mono fold has a polarity problem somewhere.

**Behavioral consequence:** Pass 5 verification optionally runs a mono-fold measurement and reports the stereo-to-mono level delta. Won't fix it automatically — that's an engineer's call — but will surface it.

## 7. True peak is not sample peak

A digital signal with a sample peak of -0.1 dBFS can reconstruct, after the brick-wall reconstruction filter in any DAC or lossy codec, to +0.5 dBTP or higher. Inter-sample peaks are the peaks *between* the samples, the actual analog waveform that emerges after digital-to-analog conversion. They matter. They clip real hardware.

**Behavioral consequence:** Every measurement uses ITU-R BS.1770 true-peak via `ebur128`, never raw sample peak. Output ceiling target is dBTP, not dBFS.

## 8. Codec generations compound

Decoding an MP3, summing it with other audio, and re-encoding the sum as MP3 is a *second* lossy encode on the original content. The artifacts of the first encode become input to the second encode's psychoacoustic model, which then makes its own decisions about what to throw away. Things compound. The result is reliably worse than the original MP3 alone.

**Behavioral consequence:** Lossy → lossy is allowed exactly once and at the highest sane setting (MP3 V0). The log records that this is a second-generation encode. The default, when any lossy is in the chain, is FLAC out — keep the lossy generation count at one.

## 9. Loudness normalization is not mastering — but the deliverable should be listenable

_Revised in v1.3._ EBU R128 (the LUFS measurement standard) is a *measurement* discipline. The mix bus is not the place to do EQ, compression, multiband processing, or creative limiting — that's mastering, and the skill still refuses to do any of it. But shipping a unity-sum file at -22 to -28 LUFS-I, which is what most archival multitracks sum to before any conditioning, asks the operator to know how to normalize before sharing — exactly the friction this plugin exists to remove. The 2025–2026 streaming consensus (Spotify / YouTube / Tidal / Amazon at -14 LUFS-I, Apple Music at -16, EBU R128 broadcast at -23) is converged enough that a single-target normalization at -14 LUFS-I with a -1 dBTP true-peak ceiling produces a file that plays back at a sensible volume on every major platform, off-platform, and against any reference track in the operator's library, without touching dynamics or spectrum.

**Behavioral consequence:** The default deliverable is a normalized listening master. After the unity-sum stage produces a 32-bit float intermediate, two-pass `loudnorm` (gain-only, `linear=true`) brings the integrated loudness to `output.target_lufs` (default -14, allowed -14 / -16 / -23) and a true-peak limiter (`alimiter`, `level=disabled`) clamps to `output.target_true_peak` (default -1.0 dBTP, allowed -1.0 / -1.5 / -2.0). No EQ, no compression, no spectral processing — strictly loudness conditioning. Operators who need bit-exact unity-sum output (null tests, archival masters intended for further processing) pass `--archival` (or set `output.archival: true` in the manifest) and get the v1.2 behavior byte-for-byte. The reference bundle (Cmd 19) keeps using unity-sum internally regardless of the canonical's normalization state, because null tests against the master only work on unprocessed signals; a separate `<project>_master_listening.<ext>` is produced alongside the canonicals as a normalized version of the master itself. Mastering — creative EQ, dynamics, character — remains structurally out of scope.

## 10. Stems must align

Different start offsets, length drift, sample-rate drift between supposedly-identical-rate files — these are *bugs*, almost always upstream of the mixdown stage. A loop point that drifts 3 ms over 4 minutes means somebody's clock disciplined wrong somewhere. Correcting it silently buries the bug for the next person.

**Behavioral consequence:** Pass 2 checks length to ±1 sample tolerance and flags drift. Will not auto-pad or auto-trim without explicit user direction.

## 11. Metadata is part of the deliverable

Filenames carry information. ID3 tags carry information. Channel labels carry information. A mixdown delivered as `output.flac` with no embedded title, artist, source notes, or processing history is half the deliverable. Conversely, fabricated metadata (wrong ISRC, invented date) is worse than missing metadata.

**Behavioral consequence:** The sidecar `.log.md` is mandatory and structured. Embedded tags preserve what came in (artist, title from input metadata when consistent across stems). The skill never invents IDs or dates.

## 12. Name the channels, name the files

`AudioTrack 14.wav` is not a stem name — it's the absence of one. Filenames are the first and most-used piece of documentation in any session. The skill's classification heuristics work because most engineers actually do label their stems, and on the rare occasions they don't, the user can supply a manifest.

**Behavioral consequence:** Classification by filename pattern is the default; when filenames are uninformative, the manifest is the override; when neither is present, the skill asks rather than guesses.

## 13. Reversibility is a feature

Every processing decision the skill makes ends up in a sidecar log. Tool versions, exact filter graphs, input SHAs, measurement before-and-after, attenuation applied. A future engineer — possibly the same person six months later — can reconstruct exactly what was done. This is not bureaucracy; this is what separates archival work from one-off bounces.

**Behavioral consequence:** Sidecar `.log.md` is mandatory output, not optional. The script that produced it is named and versioned.

## 14. Silence carries intent

Pre-roll, count-ins, fade tails, ringing reverb decay — these aren't noise to be trimmed. They're the engineer's intent. The drummer's stick-click before the downbeat establishes tempo. The fade tail tells the master where to relax. Auto-trimming silence is the single fastest way to mangle an archival mixdown.

**Behavioral consequence:** The skill never trims silence. If lengths disagree it reports the disagreement and asks; the default behavior at execute time is `duration=longest`, which preserves all tails.

## 15. The DAW bounce is the reference

If the skill's output doesn't null against a DAW bounce of the same stems within dither noise (residual peak below ~ -90 dBFS), the skill is wrong, not the DAW. Verification mode supports this test. Use it whenever there's any question about whether the skill is doing what a session would have done.

**Behavioral consequence:** `verify.py --reference <daw-bounce>` exists. Use it when in doubt.

## 16. Pan law is a choice. Declare it.

A mono stem panned center is not free. Every DAW applies a pan-law attenuation so an N-mono-stem center sum doesn't end up +3 dB louder than the same content panned hard. Pro Tools defaults to **-2.5 dB**, Logic Pro / Cubase to **-3 dB**, REAPER is configurable, and the legacy ffmpeg-naïve `pan=stereo|c0=c0|c1=c0` is **0 dB** — which is +3 dB hotter than any DAW-equivalent center sum.

There is no "right" pan law in the abstract; there is only the pan law of the session you're trying to match. The session decides. The manifest declares. The skill applies. The sidecar records.

**Behavioral consequence:** The manifest's `output.pan_law` field is the authority. Default is `-3.0` (Logic / Cubase convention) when unset. Allowed values are `0.0`, `-2.5`, `-3.0`, `-4.5`, `-6.0` — the rest are religious. The skill applies the law as a per-channel coefficient `K = 10 ** (pan_law_db / 20)` on every mono→stereo upmix, surfaces the choice in the plan rationale, and records it in the sidecar log. Pass 2 fires `pan_law_default_assumed` whenever mono stems are present and the field is unset, so silent assumption is impossible.

## 17. The preview is not the deliverable.

A loudness-normalized listening copy is sometimes useful — `--preview` produces a `<project>_<group>.preview.flac` alongside the canonical via single-pass `loudnorm=I=-14:LRA=11:TP=-1.5`. That file exists for headphones, demos, A/B comparisons. It is **not** the deliverable. Mastering decisions live downstream of this skill (Cmd 9); a preview is a listening aid, not a master.

**Behavioral consequence:** When `--preview` is set, the canonical unity-sum FLAC is still produced, and a sibling `*.preview.flac` is written with its own one-line sidecar that opens with "PREVIEW — for headphone listening, not for delivery." If a preview ever ships in place of a canonical mixdown, that's a process failure upstream — not the preview's fault. The canonical is the truth; the preview is a courtesy.

## 18. Inputs are read-only.

The skill writes outputs to a sibling directory of the source. The source folder is never modified, never recursively scanned by default, never assumed safe to mutate. An archival mixdown that rewrites the source isn't an archival mixdown — it's a destructive edit pretending to be a deliverable.

**Behavioral consequence:** Default output path is `<source>/../<source-name>-mixdowns/`, not `<source>/mixdowns/`. The legacy in-source layout is reachable only via explicit `plan.py --output-dir <source>/mixdowns`. The one exception is `<source>/.s2m/metadata/`, written only when the operator passes `--bwf-report` to analyze.py — those are advisory artifacts, named for their opt-in nature, and they live under a hidden subdirectory so casual `ls` never sees them. No filter graph, no plan, no manifest validation, no idempotency check ever writes outside `<output-dir>` or that one opt-in metadata directory.

## 19. The master is the witness, not the source.

A user-supplied master reference — the released version of the song, as it appears on streaming or the physical release — is for verification, never for normalization. The skill does not EQ to it, does not loudness-target to it, does not time-align to it. The master is held next to the deliverables so the operator can null-test, A/B, and see the loudness deltas honestly. The master is the witness to whether the mixdown is structurally right; it is not the thing the mixdown is trying to become.

**Behavioral consequence:** The optional `source.master_reference.path` manifest field (and the `--master <path>` CLI override on `analyze.py` and `verify.py`) declares the reference. The skill probes the master, requires it to match the chosen target rate / depth / duration (refuses with `master_rate_mismatch` / `master_depth_mismatch` / `master_duration_mismatch` if not), and produces a `reference-bundle/` next to the canonical mixdowns containing three perfectly synchronized FLACs: `<project>_master.flac`, `<project>_instrumental.flac`, `<project>_acapella.flac`. Pass 5 runs the reference battery — recombine null `(instrumental + acapella) - master`, inverse-stems nulls (`master - acapella` ≈ instrumental, `master - instrumental` ≈ acapella), per-deliverable LUFS-I and dBTP deltas vs the master — and reports residuals. If recombine residual is below -90 dBTP the stems and master are structurally consistent; -60 to -90 is a smell worth investigating; above -60 is structurally different (different mix, different version, different anchor) and the operator should look. The master itself is never modified; it is re-encoded into the bundle only if its container/depth differs from the target — and only the bundle copy, never the original.

## 20. Stereo is the deliverable. Mono is the source format. Don't decorate it.

Every mixdown ships stereo. Mono stems are upmixed via the declared pan law (Cmd 16) and placed in the field via either an explicit per-stem manifest `pan:` map, the auto-distribution rule (`output.auto_pan: true` or `--auto-pan`), or — by default — center. The skill does **not** apply pseudo-stereo treatments (Haas-effect doubling, delay-and-pan, all-pass decorrelators, mid/side widening of mono inputs). Every such technique trades mono compatibility for perceived width, and the deliverable is verified against mono-fold (Cmd 6); operators who want creative stereo placement use the `pan:` map; operators who want pseudo-stereo use a different tool. The 2025–2026 consensus across Sound on Sound, Mastering The Mix, Mixing Monster, and the ISMIR mono-to-stereo literature is uniform on this point: pseudo-stereo is a creative effect, not a default, and an archival/neutral mix declines it.

**Behavioral consequence:** `target_channels = 2` is hard-coded in the format-decision matrix; lower channel-count overrides are not accepted (the manifest's `output.channels` field exists for documentation only). Mono stems get upmixed via `pan=stereo|c0=L_coef*c0|c1=R_coef*c0` with `(L_coef, R_coef)` derived from the per-stem pan position and the declared pan law via constant-power-curve panning. Stereo stems are never re-panned by this skill (the manifest's `pan:` map applies to mono inputs only; setting it on a stereo stem warns and the stem passes through). When N ≥ 3 mono stems all summing to center are detected and no `pan:` map is present, Pass 2 emits `mono_pile_at_center` (warn).

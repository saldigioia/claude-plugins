# Manifest Schema (`stems.manifest.yaml`)

The manifest lives in the input directory and overrides automatic behavior. It is **optional** — the skill works fine without it on most directories. Use it when filename heuristics aren't enough or when the user wants custom groupings.

Manifest values always override automatic values. The skill reads the manifest first and treats it as authoritative.

---

## Full schema

```yaml
# stems.manifest.yaml

# Project name. Overrides directory basename for output filenames.
# Optional. Default: directory basename.
project: my-project-2024

# Per-file classification override. Maps filename (relative to manifest dir)
# to one of: vocal, drums, bass, guitar, keys, fx, other.
# The skill normally classifies via filename regex; entries here override
# the regex for the specified files.
# Optional.
classifications:
  weird_synth_thing.wav: keys
  AudioTrack14.wav: drums
  background_noise_layer.wav: fx

# Per-file gain trim, in dB, applied before the sum.
# Use sparingly — most balance decisions belong upstream of this skill,
# not in it. Useful when one stem was bounced hot by mistake and you
# don't want to re-bounce.
# Optional.
gains:
  vox_lead.wav: -1.5
  kick_room.wav: -3.0

# Custom group definitions. Maps group name to list of filenames.
# These are EXACT filenames (relative to manifest dir), not patterns.
# Custom groups are produced IN ADDITION TO the automatic acapella
# and instrumental, unless a custom group has the same name as an
# automatic one (in which case the manifest's definition wins).
# Optional.
groups:
  drums_only:
    - kick.wav
    - snare.wav
    - hat.wav
    - tom_h.wav
    - tom_l.wav
    - cymbals_room.wav
  rhythm_section:
    - kick.wav
    - snare.wav
    - hat.wav
    - bass_di.wav
    - bass_amp.wav
  acapella:    # overrides the automatic vocal-bucket grouping
    - vox_lead.wav
    - vox_bg_l.wav
    - vox_bg_r.wav
    - vox_adlib.wav

# Output format overrides. The format-decision matrix in
# references/format-decisions.md applies by default; these
# fields force a specific choice.
# All fields optional.
output:
  format: flac          # flac | wav | aiff | mp3
  rate: null            # null = auto-decide; integer = force (e.g., 48000)
  depth: null           # null = auto-decide; integer = force (e.g., 24)
  compression_level: 8  # FLAC compression level 0-12; default 8
  pan_law: -3.0         # Mono→stereo center upmix attenuation, in dB.
                        # Allowed: 0.0, -2.5, -3.0, -4.5, -6.0.
                        # Default: -3.0 (Logic / Cubase convention).
                        # Pro Tools default is -2.5; legacy 0 dB is +3 dB
                        # hotter than any DAW-equivalent center sum.
                        # See Commandment 16; format-decisions.md.

# Metadata to embed in the output files.
# Anything specified here overrides values inherited from input metadata.
# Optional.
metadata:
  artist: Artist Name
  album: Album Name
  date: 2024
  genre: Hip-Hop
  comment: Mixed from session-XYZ stems on 2024-04-15

# Provenance / reference material. Recognized keys:
#
#   master_reference:
#     path: ../mastered/song.flac          # relative to manifest dir, or absolute
#     duration_tolerance_samples: 1        # optional; default 1 sample
#
# The master_reference block opts the run into the reference-bundle deliverable
# (see Cmd 19). When present, Pass 1 probes the master, Pass 2 enforces that its
# rate / depth / channels / duration match the chosen target (refuses with
# master_rate_mismatch / master_depth_mismatch / master_channels_mismatch /
# master_duration_mismatch on disagreement), Pass 3 plans a `reference-bundle`
# output set, Pass 4 writes the bundle, and Pass 5 runs the reference battery
# (recombine null, inverse-stems nulls, per-deliverable LUFS-I/dBTP deltas).
# Optional.
source:
  master_reference:
    path: ../mastered/song.flac
    duration_tolerance_samples: 1
```

---

## Behavior notes

**Files referenced in `groups` that don't exist in the directory:**
The script errors out at Pass 1. The manifest is wrong; fix it before continuing. No silent skipping.

**Files in the directory not referenced in any group:**
Fine — they get classified by heuristic and slot into `acapella` or `instrumental` automatically. The manifest can be partial.

**A file appears in multiple custom groups:**
Allowed. The same drum loop can legitimately appear in `drums_only` and `rhythm_section`.

**A file is in `gains` but not in any group:**
Warning, but proceeds. The gain trim only applies when the file is actually used.

**Manifest forces an output format the inputs don't honestly support:**
The skill respects the manifest but logs a warning citing the source-is-the-ceiling rule. If the manifest forces 24-bit FLAC out of MP3 inputs, the output gets a `.degenerate` filename suffix and the log records the discrepancy. This matches `--lie` flag behavior — the manifest is essentially a permanent `--lie` for that directory.

**Per-stem `gains` trim and Pass 3 measured pre-attenuation interact:**
The per-stem gain is applied first, then the measurement runs, then if peak still exceeds threshold the uniform pre-attenuation applies on top. Per-stem gain is for fixing balance bugs; pre-attenuation is for fitting headroom. Different jobs.

**Pan law applies to mono→stereo upmix only.**
Each mono stem's center pan is implemented as `pan=stereo|c0=K*c0|c1=K*c0` where `K = 10 ** (pan_law_db / 20)`. -3 dB → K ≈ 0.7079; -2.5 dB → K ≈ 0.7499; 0 dB → K = 1.0. Stereo stems are passed through unchanged. The plan's rationale block calls out the chosen pan law whenever any mono stems are present.

**`source.master_reference` opts into the reference-bundle deliverable.**
The master must match the chosen target rate, depth, and channels exactly, and its duration must be within `duration_tolerance_samples` of the longest stem (default: 1 sample). Pass 2 fires `master_rate_mismatch` / `master_depth_mismatch` / `master_channels_mismatch` / `master_duration_mismatch` as **errors** (not warnings) on disagreement — Cmd 19 forbids the skill from resampling, requantizing, or trimming the master to make it fit. The user fixes the master (or omits it) and re-runs. A lossy master with lossless stems fires `master_lossy_with_lossless_stems` as a **warn**: the bundle still proceeds, but the recombine null residual will be limited by the lossy compression's noise floor. The `--master <path>` CLI flag on `analyze.py` and `verify.py` is an out-of-band override for the same field, useful when the manifest is hand-written and the master path is per-run.

---

## Minimal manifest (most common case)

```yaml
groups:
  acapella:
    - vox_lead.wav
    - vox_bg.wav
```

Use this when you have one stem that should be in the acapella but doesn't match the regex (e.g., named `talkbox_solo.wav`), or when you want to exclude something the regex picked up wrong.

---

## Custom-group-only manifest

```yaml
groups:
  drums_and_bass:
    - kick.wav
    - snare.wav
    - hat.wav
    - bass.wav
  full_band_minus_vox:
    - drums.wav
    - bass.wav
    - gtr_l.wav
    - gtr_r.wav
    - keys.wav
```

The skill produces both custom groups AND the automatic `acapella` / `instrumental`, since neither was overridden.

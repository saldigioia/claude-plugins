# Pro-Audio Metadata

How `stems-to-mixdown` handles the technical metadata (sample rate, bit depth,
channels) and production metadata (BWF / iXML / session structure) that lives
in professional WAV files. This document is the spec for `analyze.py`'s
production-metadata enrichment and the source-of-truth rule for fields that
drive the format-decision matrix in `references/format-decisions.md`.

## The framing

Production metadata is **LLM-reference context only**. It exists so an
operator (Claude or a human) reading `analysis.json` while planning a
mixdown has the project, scene, take, originator, time-reference, and other
session-side context to make better mixing choices. Nothing in
`production_metadata` ever auto-flows into the output FLAC's embedded tags.
Output embedding stays driven solely by the manifest's `metadata:` block,
which the operator sets deliberately. Commandment 11 is unambiguous:
the skill never invents IDs or dates.

## Source of truth, by field

| Field | Authority | Why |
|---|---|---|
| Sample rate | ffprobe | All four metadata tools read `nSamplesPerSec` from the same `fmt ` chunk and agree. ffprobe stays canonical because the rest of the pipeline already trusts it. |
| Channel count | ffprobe | Same — `nChannels` is unambiguous in the `fmt ` chunk. |
| Bit depth | **wavinfo when available, ffprobe when not** | ffprobe and MediaInfo conflate container and valid bits on `WAVE_FORMAT_EXTENSIBLE`. wavinfo reads `wValidBitsPerSample` correctly, which is the honest captured depth. |
| Codec / container | ffprobe | libavformat detection is the most-tested across odd files. |
| Duration | ffprobe | Decoder-level frame count is more reliable than chunk-size arithmetic. |
| BWF / iXML production fields | wavinfo (primary), BWF MetaEdit (audit-grade cross-check via `--bwf-report`) | wavinfo gives Python-native access; BWF MetaEdit's value is FADGI-conformant XML/CSV export, not different parsing. |

## The 24-in-32 ambiguity

Professional audio routinely stores 24-bit PCM in 32-bit containers using
`WAVE_FORMAT_EXTENSIBLE` (`wFormatTag = 0xFFFE`), which adds a
`wValidBitsPerSample` field separate from `wBitsPerSample`. A 24-in-32 file
has:

- `wBitsPerSample = 32` (container size — what ffprobe and MediaInfo report)
- `wValidBitsPerSample = 24` (the honest, captured depth — what wavinfo reports)

If the plugin sees only the container size, the format-decision matrix can
choose 32-bit FLAC output for material that captured 24 bits — a violation
of Commandment 1 ("the source is the ceiling"). `analyze.py` therefore
prefers wavinfo's `bits_per_sample` over ffprobe's container-derived value
when wavinfo is installed.

When wavinfo is not installed and the file is a `.wav` with `sample_fmt:
s32`, `analyze.py` records `bit_depth_source: "ffprobe_sample_fmt"` and
fires a `bit_depth_uncertain` warn red flag. The operator can install
wavinfo (`pip install wavinfo`) or pass `--force` to proceed with the
container-size value as a fallback.

## What's in `production_metadata`

For every stem that's a WAV/RF64 and has at least one optional probe
available, `analysis.json` contains a per-stem `production_metadata` block
with this shape:

```json
{
  "production_metadata": {
    "fmt": {
      "valid_bits": 24,
      "container_bits": 32
    },
    "bwf": {
      "description": "...",
      "originator": "...",
      "originator_reference": "...",
      "origination_date": "2024-04-15",
      "origination_time": "10:42:13",
      "time_reference": 12345678,
      "coding_history": "..."
    },
    "ixml": {
      "project": "...",
      "scene": "...",
      "take": "...",
      "tape": "...",
      "user_bits": "..."
    },
    "umid": "...",
    "mediainfo": {
      "sample_rate": 48000,
      "bit_depth": 32,
      "bit_depth_detected": 24,
      "channels": 2,
      "duration_ms": 240500.0,
      "format": "Wave",
      "compression_mode": "Lossless"
    },
    "bwf_reports": {
      "core": "/path/to/.s2m/metadata/file.bwf.core.txt",
      "tech": "/path/to/.s2m/metadata/file.bwf.tech.txt",
      "xml":  "/path/to/.s2m/metadata/file.bwf.xml"
    }
  }
}
```

Empty keys are omitted, so a vanilla WAV with no bext/iXML chunks gets a
small or absent block.

## Tag-precedence rule

Three sources of metadata can populate fields like `artist`, `title`,
`comment`:

1. ffprobe's `format.tags` → recorded in `stem.tags` (canonical for
   embedded tag strings).
2. wavinfo's BWF `description` / `originator` → recorded in
   `stem.production_metadata.bwf` (production-side, not output-side).
3. wavinfo's iXML `project` / `scene` / `take` → recorded in
   `stem.production_metadata.ixml`.

These are different namespaces, not competing values. An LLM operator
reading `analysis.json` can use bext fields to understand the recording
context without those fields polluting `stem.tags`.

The output FLAC's embedded tags come solely from the manifest's
`metadata:` block. Nothing in `stem.tags` or `stem.production_metadata`
auto-flows.

## Probe-disagreement red flags

When MediaInfo is available, `analyze.py` cross-checks rate, depth, and
channels against the chosen authority (wavinfo > ffprobe). A
`probe_disagreement` warn red flag fires only when the disagreement
would change the format-decision matrix output. Disagreements on
duration, container-string spelling, or codec name are recorded in
`stem.production_metadata.mediainfo` for review but do not fire a flag.

## Optional dependencies

These are not required for basic mixdown. They improve archival inspection
and the LLM operator's reasoning. The plugin works correctly when they're
absent — `analyze.py` logs at `[info]` severity and falls back where
needed.

| Tool | Install | What it adds |
|---|---|---|
| `wavinfo` (Python) | `pip install wavinfo` | Honest `bit_depth` on 24-in-32 WAV; BWF `bext` chunk; iXML `scene`/`take`/`project`; UMID |
| `mediainfo` (CLI) | `brew install mediainfo` (macOS), `apt install mediainfo` (Debian/Ubuntu) | Cross-check probe; fires `probe_disagreement` warnings on ffprobe disagreements |
| `bwfmetaedit` (CLI) | `brew install bwfmetaedit` (macOS), `apt install bwfmetaedit` (Debian/Ubuntu) | FADGI-conformant XML/CSV report export under `<dir>/.s2m/metadata/`. Opt-in via `--bwf-report`. |
| `pro-tools-session-info` (Python) | not required — `import_pt_track_names.py` ships with a self-contained parser | Deeper Pro Tools text-export parsing if a future contributor wants to swap in a third-party library |

## Pro Tools intake (Pass 0)

When stems are badly named or come from a Pro Tools session export,
`stems_to_mixdown/import_pt_track_names.py` reads a "Session Info as Text" export
and writes:

- `stems.session.yaml` — full structural context (session metadata,
  track listing, file listing, markers/plug-ins as raw blocks). LLM
  reference material; not consumed by `analyze.py`.
- `stems.manifest.yaml` — partial manifest in the existing schema with
  `classifications` derived from track names. The user completes
  `groups`, `gains`, `output`, `metadata` by hand.

Files referenced by the session but not present in `--audio-dir` are
dropped from the manifest (so `analyze.py` doesn't hard-error on a stale
reference) and listed as comments at the top of the generated manifest.

## Reversibility note

The mixdown pipeline's reproducibility commitment (Commandment 13:
"identical artifact hashes on re-runs") covers Pass 1–5 outputs:
`analysis.json`, `plan.json`, the FLAC outputs, and the `.log.md`
sidecars. It does **not** cover the BWF MetaEdit reports under
`<dir>/.s2m/metadata/`, which may include version-banner timestamps
that vary across machines. Those are advisory artifacts; treat them
as audit context, not as part of the deliverable.

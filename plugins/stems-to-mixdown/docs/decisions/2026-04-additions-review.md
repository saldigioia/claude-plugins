---
status: historical
applied: 2026-04
moved_to_decisions: 2026-05-05
---

# Review of Suggested Additions for `stems-to-mixdown` (April 2026)

> **Historical document.** This file critiqued five proposed additions against the
> April 2026 codebase. Items 1–4 (wavinfo / BWF MetaEdit / MediaInfo / Pro Tools
> session bridge) were applied and are reflected in the current code; item 5 was
> deferred. Moved from the repo root to `docs/decisions/` on 2026-05-05 per
> REVIEW-2026-05.md §7.4 — kept for traceability, not as a live design doc.

---

A critique of `stems-to-mixdown-suggested-additions.md` against the plugin as it
actually stood in April 2026 (`SKILL.md`, `scripts/analyze.py`, `references/manifest-schema.md`,
`references/commandments.md`, `references/format-decisions.md`).

The doc is sound in spirit and gets the read-only posture exactly right.
The notes below are about fit and second-order details, not direction.

---

## Verdict at a glance

The five additions split cleanly into two groups, and the doc is right to
distinguish them. Items 1, 2, and 3 (`wavinfo`, BWF MetaEdit, MediaInfo)
are *enrichment for Pass 1*. Items 4 and 5 (`pro-tools-session-info`, AAF)
are *intake helpers that run before Pass 1* — they manufacture or improve a
manifest, then the existing five-pass pipeline takes over. Worth naming this
distinction explicitly in `SKILL.md` so the plugin's identity stays sharp.
Calling it "Pass 0 — Manifest preparation" preserves the five-pass spine
while admitting that some folders need help before discovery is meaningful.

The recommended integration order in the doc (1→5) is roughly right but
worth tweaking: I'd promote the Pro Tools session-info bridge above
BWF MetaEdit, because it solves a real classification problem (badly named
stems) that the existing skill admits it cannot fix, while BWF MetaEdit
mostly duplicates `wavinfo`'s value once `wavinfo` is in.

---

## 1. `wavinfo` — strongest fit, lowest risk

Direct alignment with Commandment 11 ("metadata is part of the deliverable")
and Commandment 12 ("name the channels, name the files"). The soft-import
pattern already exists in `analyze.py` for PyYAML
(`try: import yaml ... except ImportError: yaml = None`), so the cost of
adding it is one more `try/except` and a small `enrich_with_wavinfo()` helper.

Two adjustments before implementing:

**Nest the fields, don't flatten them.** The doc's suggested shape puts
thirteen `bwf_*` / `ixml_*` keys into the stem record. The current `StemInfo`
dataclass already has 25-ish fields; flattening doubles its surface area and
makes the schema brittle as new metadata sources get added. Recommend a
single `production_metadata` field that nests:

```json
"production_metadata": {
  "bwf": { "description": null, "originator": null, "time_reference": null, ... },
  "ixml": { "project": null, "scene": null, "take": null, ... },
  "umid": null
}
```

This keeps the top-level shape of `analysis.json` stable for `plan.py` and
`mix.py` even as new probes get added.

**Format-gate the call.** `wavinfo` is WAVE/RF64 only. Don't call it on
FLAC, AIFF, MP3, etc. — that's an exception waiting to happen. Gate by
`path.suffix.lower() in {".wav", ".wave", ".rf64"}` before invoking.

**Define a tag-precedence rule.** `analyze.py` already collects ffprobe
`tags` at line 292. With `wavinfo` reading the same WAV directly, two
sources will sometimes disagree on `artist` / `title` / `comment`. Pick a
deterministic precedence so the LLM reading `analysis.json` doesn't have
to reconcile silently. Recommended split: ffprobe `tags` populate
`stem.tags` (the existing field); wavinfo populates
`stem.production_metadata.bwf` and `stem.production_metadata.ixml` in a
separate namespace; technical fields (rate, depth, channels) follow the
source-of-truth rule defined in the next section. Document the precedence
in the new `references/pro-audio-metadata.md` the doc proposes.

**Bound coding-history strings.** BWF coding history can be many lines.
Cap to ~2KB or hash-and-truncate; otherwise `analysis.json` becomes
unwieldy on archival batches.

**Surface for LLM reference, never to output metadata.** This enrichment
exists so an LLM operator (Claude, in the realistic case) reading
`analysis.json` while planning a mixdown has the production context — scene,
take, project, originator, time reference — to make better choices. It does
*not* exist to populate the FLAC/WAV output's embedded tags. Production
metadata from a recording session is almost always wrong for the mixdown
deliverable: the bext "originator" is the recordist, not the mixer; the
iXML "project" is the recording project, not the release. Auto-flowing any
of it into output tags would violate Commandment 11's "the skill never
invents IDs or dates." Output embedding stays driven solely by the
manifest's `metadata:` block, which the human (or LLM operator) sets
deliberately. Production metadata is read-only context, not output
material.

---

## 2. BWF MetaEdit — useful but the weakest of the trio

The proposal is correct that this should be read-only. Three frictions:

**Mostly redundant once `wavinfo` is in.** `wavinfo` reads the same BWF/CORE
chunks. BWF MetaEdit's added value is the FADGI-conformant XML/CSV export
format, useful for archival audit deliverables. If users don't need
FADGI-shaped reports, this adds an external CLI dependency for little gain.
Recommend gating it behind an explicit `--bwf-report` flag (the doc already
suggests this) and *not* running it on every analyze invocation.

**`--out-md5` is a different MD5.** The doc lists `bwfmetaedit --out-md5`
alongside the format reports. BWF MetaEdit's MD5 covers the audio-data chunk
specifically (a BWF chunk-integrity check), not the whole file. The plugin
already SHA-256s the whole file at line 298. These are not interchangeable.
Either drop `--out-md5` from the suggestion or document explicitly that
they're complementary checks at different scopes.

**Output location.** The doc proposes `mixdowns/metadata/`, but
`mixdowns/` is created during Pass 4 — analyze runs first. Either store
under `<input-dir>/.s2m/metadata/` (alongside `analysis.json`) or under the
user's selected output dir. Don't reach into a directory that doesn't exist
yet.

**Idempotency.** Commandment 13 commits to "re-running yields identical
artifact hashes." BWF MetaEdit XML reports may embed tool version strings
or a generation timestamp. Pin the version in the log and strip variant
banner lines from the saved report, or note explicitly that the reports
are advisory and not part of the artifact-hash contract.

---

## 3. MediaInfo / `pymediainfo` — good idea, prefer CLI over wrapper

The cross-check premise is sound and aligns with how the rest of the plugin
already works (multiple shells to `ffprobe`, `ffmpeg`, `sox`). Two pushbacks
on the implementation as proposed:

**Skip `pymediainfo`, shell out to `mediainfo --Output=JSON`.** `pymediainfo`
is a Python wrapper around `libmediainfo`, a C library. Declaring it as a
pyproject extra (`[pro-audio]`) does not install the C library — users will
hit `ImportError`-shaped runtime failures on macOS Homebrew vs. Linux apt vs.
Windows in three different ways. Shelling out matches the rest of the plugin
and makes the dependency a single CLI, not a two-layer install.

**Make disagreements a Pass 2 warning, not just a field.** The doc's
`probe_disagreements: []` is good but isn't wired into the existing red-flag
machinery. The format-decision matrix in Pass 3 keys off bit depth, sample
rate, and channels. If MediaInfo says 16-bit and `ffprobe` says 24-bit on the
same file, the matrix output is wrong half the time silently. Recommend a
red flag, severity `warn`, code `probe_disagreement`, that fires when fields
critical to format decisions (rate, depth, channels) disagree beyond a
tolerance. Disagreements on `duration` should be info-only with a small
sample-count tolerance — different decoders round differently. Disagreements
on container/codec strings should be info-only too (`riff` vs `wav` etc.).

**Keep `ffprobe` authoritative.** Don't introduce a "two of three votes
wins" rule. `ffprobe` stays canonical because the rest of the pipeline
already trusts it; MediaInfo's role is to surface contradictions to a human,
not to silently override. State this in `references/pro-audio-metadata.md`.

---

## 4. `pro-tools-session-info` — high practical value, schema collision risk

This solves a real and common pain point — the `AudioTrack 14.wav` problem
that Commandment 12 explicitly calls out — and the doc is right to keep it
to the safe textual export rather than `.ptx` reverse engineering.

The risk is schema collision. The plugin already defines
`stems.manifest.yaml` with `classifications`, `gains`, `groups`, `output`,
and `metadata`. The doc's helper output proposes a different shape with
`session`, `tracks`, `media`. Don't write that into `stems.manifest.yaml`
directly — that breaks the existing schema for anyone hand-editing the
manifest. Two cleaner options:

**Option A (preferred):** the helper writes a sidecar — call it
`stems.session.yaml` — capturing the session/track/media information,
*and* writes `classifications` and (where unambiguous) custom `groups` into
`stems.manifest.yaml`. The plugin reads both: `analyze.py` consults the
manifest as it does today; advanced users can read the sidecar for context.

**Option B:** the helper produces a manifest in *only* the existing schema,
filling what it can fill (classifications via track-name heuristics, groups
where the export marks them clearly) and leaving the rest blank. The
session-level data goes into the comment block at the top of the YAML.
Simpler, but loses the structural Pro Tools context.

Either way, two correctness checks:

**Filter to audio tracks with online media.** Pro Tools session info
includes MIDI tracks, Aux Inputs, Master Faders, Instrument tracks, VCAs,
and offline references. Most of these aren't stems. Filter to "audio track,
online, with at least one clip referencing a file present in `--audio-dir`."

**Preflight against the directory.** The existing manifest schema hard-errors
when `groups` references files that don't exist (per `manifest-schema.md`).
The helper must verify every file it writes into a group exists on disk
before writing — otherwise the first analyze run after intake fails
unhelpfully.

---

## 5. `pyaaf2` / OTIO AAF adapter — defer

Agree with the doc that this is the lowest-priority addition. Three concerns
worth recording even before any work starts:

**Pick one parser.** `pyaaf2` and `otio-aaf-adapter` are independent
implementations. Maintaining a code path that works on either is twice the
test surface. Pick `pyaaf2` (lower-level, more direct) unless the team is
already invested in the OTIO ecosystem.

**AAF can carry embedded media.** Some AAF exports embed essence rather
than referencing external files. If the helper extracts embedded essence
to disk, that crosses the "never write source files" line that the rest
of this proposal carefully holds. Either forbid extraction (manifest only
references files already present in `--audio-dir`) or extract to a
clearly-marked `<dir>/.s2m/extracted/` and document those files as
working-set, not source-of-truth.

**AAF is timeline data, not stem data.** A track in AAF can have multiple
clips with edit decisions, fades, crossfades. The plugin sums *files*, not
edited timelines. The helper should flag that timeline edits in the AAF
are advisory — the user must consolidate to flat stems first if they want
the edits applied.

---

## Cross-cutting concerns

**Optional dependency surface area.** With your selected approach
(soft imports + `pyproject` extras), the plugin grows from
`ffmpeg + ffprobe + sox + PyYAML` to a roster that includes `wavinfo`,
`bwfmetaedit`, `mediainfo`, `pro-tools-session-info`, and `pyaaf2`.
Document the install matrix in one place (`references/pro-audio-metadata.md`)
with explicit per-OS instructions for the C-library deps. Otherwise the
plugin's "just works" promise dies the death of a thousand
`brew install`s.

**JSON growth.** `analysis.json` per-stem record roughly doubles with all
five additions wired in. Nest under `production_metadata: {bwf, ixml,
mediainfo}` to keep the top level stable for `plan.py`. Future additions
land inside that block without further schema churn.

**Reversibility commitment.** Commandment 13 promises identical artifact
hashes on re-runs. Several proposed external tools (BWF MetaEdit XML
reports, MediaInfo JSON dumps, AAF parser banners) embed timestamps or
version strings that can vary. Either strip those at write time or carve
out an explicit "advisory artifacts" exception — don't let them silently
break the determinism contract.

**The Pass 2 gate.** The plugin's discipline comes from Pass 2 *blocking*
the user (or the LLM operator) when something's off. Each addition needs
a defined point where it can elevate to `RedFlag`. Concrete list:
`probe_disagreement` (warn) when ffprobe and MediaInfo disagree on
rate/depth/channels in a matrix-affecting way; `bit_depth_uncertain`
(warn) when wavinfo is unavailable on a `.wav` file with `sample_fmt:
s32` (the 24-in-32 ambiguity is real and the operator should know);
`session_orphan` (warn) when the Pro Tools bridge writes a manifest entry
referencing a file the audio dir doesn't contain after preflight; `aaf_
reference_missing` (warn) for the AAF case. None of these escalate to
`error` severity unless `--strict` is added. The point is to surface, not
to block by default.

---

## Probe source-of-truth (research)

Before fixing precedence we have to look at what each tool actually parses.
The four tools derive technical fields from the WAV `fmt ` chunk in
materially different ways. The summary below is grounded in source-code
review of the FFmpeg, MediaInfoLib, and `wavinfo` parsers, plus the
WAVEFORMATEXTENSIBLE specification (Microsoft `mmreg.h` / `ksmedia.h`).

**The pivot fact:** professional audio routinely stores 24-bit PCM in
32-bit containers using `WAVE_FORMAT_EXTENSIBLE` (`wFormatTag = 0xFFFE`),
which adds a `wValidBitsPerSample` field separate from `wBitsPerSample`.
A 24-in-32 file has `wBitsPerSample = 32` (container) and
`wValidBitsPerSample = 24` (the honest, captured depth). Whether a tool
reads the container or the valid bits decides whether it tells the truth.

### How each tool derives bit depth

**ffprobe** parses the `fmt ` chunk and exposes `bits_per_sample`,
`sample_fmt`, and `bits_per_raw_sample`. For WAV, `bits_per_raw_sample` is
typically `N/A` (it's a video-codec field in practice) and the output
prioritizes the container size. On a 24-in-32 file, ffprobe reports
`bits_per_sample: 32` and `sample_fmt: s32`. The decoder reads
`wValidBitsPerSample` correctly internally for playback, but does not
surface it in probe output. **ffprobe systematically over-reports bit
depth on 24-in-32 files.**

**MediaInfo** reads the same chunks via `File_Riff.cpp`. Its source
attempts coherent handling of `WAVE_FORMAT_EXTENSIBLE` but the CLI
output's `BitDepth` field commonly reports the container size (32) on
24-in-32 files, with version-dependent variation. There are documented
issues (#94, #135) where MediaInfo has misidentified WAV files entirely
or reported PCM as DTS. **MediaInfo's bit-depth reporting on extensible
formats is unreliable.**

**wavinfo** is the one parser of the four explicitly designed to surface
`wValidBitsPerSample` as `bits_per_sample`. On a 24-in-32 file, wavinfo
reports `24`, not `32`. It also handles RF64 (the >4GB WAV variant) and
the BWF/iXML/ADM extension chunks. **wavinfo is the only one of the
trio that reads the depth honestly.**

**BWF MetaEdit** is a metadata editor and validator, not a probe in the
ffprobe/MediaInfo sense. Its `--out-tech` reports rate, depth, channels
from the `fmt ` chunk as a unit but does not dissect WAVEFORMATEXTENSIBLE
either; it shows the container size. **BWF MetaEdit does not help
disambiguate 24-in-32.**

### Source of truth, by field

| Field | Source of truth | Why |
|---|---|---|
| Sample rate | **ffprobe** | All four tools read `nSamplesPerSec` from the same `fmt ` chunk and agree. ffprobe stays canonical because the rest of the pipeline already trusts it. |
| Channel count | **ffprobe** | Same — `nChannels` is unambiguous in the `fmt ` chunk. |
| Bit depth | **wavinfo when available, ffprobe when not** | ffprobe and MediaInfo conflate container and valid bits. wavinfo reads `wValidBitsPerSample` correctly, which is the honest captured depth. ffprobe is the safe fallback because it errs toward over-reporting (claiming 32 instead of 24), and the format-decision matrix takes the *smallest common* depth — over-reporting one stem doesn't cause an honesty breach unless every stem is misreported in the same direction (see latent bug below). |
| Codec / container | **ffprobe** | ffprobe's libavformat detection is the most-tested across odd files. |
| Duration | **ffprobe** | Decoder-level frame count is more reliable than chunk-size arithmetic. |
| BWF/iXML production fields | **wavinfo** primary, BWF MetaEdit as audit-grade cross-check | wavinfo gives Python-native access; BWF MetaEdit's value is FADGI-conformant XML/CSV export, not different parsing. |

### Latent correctness bug surfaced by the research

`scripts/analyze.py` lines 252–265 derive `bit_depth` by reading
`bits_per_raw_sample` first and falling back to a `sample_fmt` lookup
table when that's missing. For WAV, `bits_per_raw_sample` is "typically
N/A" — the code falls into the `sample_fmt` branch, which maps `s32` →
32. **A 24-in-32 file is currently recorded as 32-bit in `analysis.json`.**

The format-decision matrix takes the smallest common depth, so this
matters in one specific case: when one stem is honestly 24-bit (24-in-32)
and another is true 32-bit float, the current code reports both as 32 and
the matrix proposes 32-bit FLAC output. The honest answer is 24-bit FLAC,
because the 24-in-32 stem captured 24 bits of signal — claiming 32 in the
output violates Commandment 1.

This is independent of the additions in the suggestions doc, but adding
`wavinfo` is the cleanest fix: when wavinfo is present, prefer its
`bits_per_sample` over ffprobe's container-derived value. When wavinfo
isn't present, the bug remains and should be documented in the README's
known-limitations section.

---

## Decisions

**1. Probe-disagreement source of truth.** Per the research above, the
authoritative source depends on the field. ffprobe stays canonical for
sample rate, channels, codec, container, and duration. wavinfo is
authoritative for bit depth when present (and the 24-in-32 latent bug
gets fixed at the same time). MediaInfo's role is reduced from
cross-check to specific-case validator: surface a Pass 2 `warn` red flag
only when MediaInfo *and* the chosen authority disagree on a field that
would change the format-decision matrix output (rate, depth, channels).
Disagreements on duration, container string, and codec name remain
info-only.

**2. Sidecar location for advisory metadata.** Recommendation accepted:
`<input-dir>/.s2m/` for everything advisory — BWF MetaEdit XML reports,
MediaInfo cross-check dumps, AAF parser output. Matches the "right next
to the artifact" pattern of the existing `.log.md` sidecars and avoids
reaching into `mixdowns/` before it exists.

**3. Manifest schema for the PT bridge.** Recommendation accepted:
Option A. The bridge writes `stems.session.yaml` (Pro Tools structural
context — session, tracks, clips, markers) plus a partial
`stems.manifest.yaml` (only `classifications` and unambiguous custom
`groups`, in the existing schema, preflighted against the audio dir).
The two files coexist; `analyze.py` reads the manifest as today; the
session sidecar is reference material for the LLM operator and for
humans inspecting the intake.

**4. Output metadata flow.** Decided: nothing read by these tools ever
auto-flows into output embedded tags. All production metadata
(`production_metadata.bwf`, `production_metadata.ixml`, MediaInfo
cross-check, AAF context) is LLM-reference context only — it lives in
`analysis.json` and the session sidecar so an LLM operator (or a human)
can read it while planning a mixdown, and stops there. Output embedding
remains driven solely by the manifest's `metadata:` block, which the
operator sets deliberately. This makes the implementation rule
unambiguous: when in doubt, the data goes into `analysis.json` and not
into the output FLAC's tags. Commandment 11's "never invents IDs or
dates" stays binding.

---

## Recommended sequence

1. **`wavinfo` enrichment in `analyze.py`** — soft import, nested under
   `production_metadata.bwf` / `production_metadata.ixml`, format-gated to
   WAV/RF64. Carries two payloads in one change: archival metadata for the
   LLM operator's reference, *and* a fix for the latent 24-in-32 bit-depth
   bug (`stem.bit_depth = wavinfo's bits_per_sample` when wavinfo is
   present, ffprobe-derived value as documented fallback when it's not).
2. **MediaInfo cross-check via shell-out** (not `pymediainfo`) — fires a
   Pass 2 `warn` red flag with code `probe_disagreement` only when
   MediaInfo and the chosen authority disagree on rate, depth, or channels
   in a way that would change the format-decision matrix output. Other
   disagreements (duration rounding, container string spelling) are
   info-only fields in `analysis.json`. Skip the Python wrapper entirely
   to avoid the libmediainfo C-library install matrix.
3. **Pro Tools session-info bridge as a separate `import_session_info.py`** —
   produces `stems.session.yaml` (full Pro Tools structural context for the
   LLM operator) plus a partial `stems.manifest.yaml` populated only with
   `classifications` and unambiguous `groups`, preflighted against the
   audio dir. Documented as Pass 0 in `SKILL.md`.
4. **BWF MetaEdit reporter, opt-in via `--bwf-report`** — gated, writes
   reports to `<dir>/.s2m/metadata/`, marked as advisory artifacts not
   subject to Commandment 13's determinism contract.
5. **AAF intake** — defer until at least one user actually has an AAF
   workflow that the manifest path can't already serve.

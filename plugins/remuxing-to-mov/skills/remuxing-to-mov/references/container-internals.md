# Container Internals (reference)

Background on the MOV/QTFF container. Rarely needed for a routine remux — consult
when validating structure or debugging a malformed file.

## Atom anatomy (non-fragmented MOV)

```
ftyp (brands)
free/skip (padding)
moov (movie metadata)
  mvhd (timescale, duration)
  trak (one per track)
    tkhd (track header)
    edts/elst (edit list) [optional]
    mdia
      mdhd (media header)
      hdlr (vide/soun/tmcd)
      minf
        vmhd/smhd
        dinf > dref
        stbl (sample table)
          stsd (sample descriptions: avc1/hvc1/apch/mp4a ...)
          stts (decode time-to-sample)
          ctts (composition offsets) [optional]
          stsc (sample-to-chunk)
          stsz/stz2 (sample sizes)
          stco/co64 (chunk offsets)
          stss (sync samples / keyframes) [optional]
  udta/meta (user/metadata) [optional]
mdat (media payload)
```

Note (verified): color (`colr`) and field (`fiel`) info live *inside* the
sample-entry box (e.g. `avc1`) within `stsd`, not at the top level. On a plain
copy ffmpeg writes `colr` by default but does **not** write `fiel`.

## Key atoms

| Atom | Purpose | Common issue |
|------|---------|--------------|
| ftyp | major_brand + compatible_brands | MOV uses `qt  `; MP4 `isom/mp41/mp42` |
| moov | global metadata, track list | must exist exactly once |
| mvhd | timescale/duration | must agree with track mdhd |
| stsd | codec configuration (avcC/hvcC/...) | missing codec box → can't decode |
| stco/co64 | 32/64-bit chunk offsets | use co64 for files > 4 GiB |
| mdat | media payload | stco/co64 offsets must point here |

## MOV vs MP4

| Aspect | MOV | MP4 |
|--------|-----|-----|
| Brand (ftyp) | `qt  ` | `isom`, `mp41`, `mp42` |
| Box dialect | classic QTFF | ISO BMFF |
| Color info | historically nclc | colr/nclx standard |
| Preferred use | archival, editorial | distribution, streaming |

## Required structure (minimal valid MOV)

- `ftyp` with a major_brand
- exactly one `moov` containing `mvhd` + ≥1 `trak` with a complete sample table
- ≥1 `mdat` with payload
- streaming: `moov` before `mdat` (`-movflags +faststart`)

**Apple's recommended creation order.** Atom order is generally free and
moov-at-end is legal — placement affects neither validity nor durability of a
finished file. But the spec states a recommended order: *"the atom containing
the movie resource should precede any atoms containing the movie's sample
data"*, enabling playback while downloading, and the format's own history moved
the global movie information from the end of the file to the beginning. The
spec also names the one hazard of relocating it: *"be careful when constructing
a self-contained QuickTime file with its metadata (movie atom) at the front
because the size of the movie atom affects the chunk offsets to the media
data"* — which is precisely what gates (h)/(k)/(m) prove harmless on the
finished file. Since **1.16.7** faststart is therefore the default on every
`.mov`-writing route, archival masters included, with a manual announced
opt-out (`RTM_FASTSTART=0` / `--no-faststart`).

**faststart's cost (QTFF audit 5-5a; measured again 1.16.7):** ffmpeg still
writes `moov` LAST, then a second pass relocates it to the front — the muxer's
own log says so (`Starting second pass: moving the moov atom to the beginning
of the file`, probed 2026-07-26 on 8.1.2, again 2026-08-29 on 9.0.1) — and
moving `moov` shifts every `mdat` byte, so the pass rewrites the whole file:
**~2× write I/O per output**. Irrelevant on a small file; on multi-GB masters
over external SSDs it dominates batch throughput.

**The cost is TIME, not SPACE — measured, because the disk pre-flight budget
hung on it.** 2026-08-29, ffmpeg 9.0.1 / libavformat 63.1.101, macOS 26.6.2,
3.93 GiB output on an external APFS SSD: libavformat performs the relocation
**in place**. It reopens the finished output for READING (`lsof` showed one
`w` and one `r` descriptor on the same path) and shifts the media data forward;
**no temp file appeared in 50 directory samples**, and peak disk was
**1.000×** the output (4,224,974,848 B against a 4,224,596,893 B file). So
`rtm_disk_preflight`'s one-source-size budget already covers a faststart build
and 1.16.7 left it unchanged. What it costs is wall time: 8.1 s to mux, 10.9 s
more to relocate (19.0 s total). The older advice here — that faststart is an
access-copy need and a shelved master does not want it — is **superseded**: the
order is Apple's recommendation for any finished file, and the operator, not
the script, decides to trade it away.

## Validation checks

```
# structure present
ffprobe -v error -show_entries format=format_name -of default=nw=1 file.mov
# streams + tags
ffprobe -v error -show_streams -show_format -print_format json file.mov
# (if Bento4 available) atom dump
mp4dump -a file.mov | grep -E 'ftyp|moov|mdat|avcC|hvcC|colr'
```

## Common pitfalls

- `moov` at EOF without faststart → poor progressive playback.
- `stco` overflow on > 4 GiB files → needs `co64` (a fresh ffmpeg remux fixes it).
- Missing `avcC`/`hvcC` → can't decode.
- Edit lists with negative offsets → stalls; flatten with
  `-avoid_negative_ts make_zero`.
- Wrong handler type (`soun` for video) → breaks playback.

## Fragmented, encrypted & malformed files (edge cases)

- **Fragmented MP4/MOV** (`moof` boxes after `moov` — live/DASH/CMAF captures):
  sample tables live per-fragment (`traf`); a missing `tfdt` causes A/V drift.
  Everything else in this skill assumes non-fragmented files — a fresh
  `-c copy` remux defragments into a single `moov`+`mdat`, after which the
  normal workflow applies.
- **Encryption:** `sinf`/`schi`/`tenc`/`pssh` boxes mean DRM/CENC content — no
  remux or decode without keys; stop rather than chase phantom mux errors.
  Detect: `mp4dump -a file | grep -E 'sinf|schi|tenc|pssh'`.
- **Malformed atoms:** an atom with `size < header`, a size overrunning the
  file, or overlapping regions is corruption (or hostile input) — reject it.
  The 64-bit extended size field is legal only when `size == 1`.
- **Truncated `moov`:** without a complete sample table the file cannot be
  decoded; there is no in-place fix. Recovery means a donor file with identical
  encode parameters (untrusted) or salvaging the raw elementary stream.
- **Compressed `moov` (`cmov`):** early-QuickTime files may carry a
  zlib-compressed movie atom — the symptom is a confusing/truncated `mp4dump`.
  ffmpeg reads it transparently, so a stream-copy remux IS the normalization.

## QuickTime metadata (mdta) vs the legacy ©-atoms

Two ways to carry file metadata in a `.mov`, treated differently by QuickTime:

- **Proper QuickTime format** — `udta/meta` with an `mdta` handler, a `keys` box of
  reverse-DNS names (`com.apple.quicktime.title`, `.description`, `.author`,
  `.creationdate`, …) and a parallel `ilst` of values. This is what Apple tools and
  Finder read. ffmpeg writes it with `-movflags use_metadata_tags` plus
  `-metadata com.apple.quicktime.KEY=VALUE`.
- **Legacy ©-atoms** — bare `©nam`/`©des`/`©cmt` codes directly under `udta` (what the
  naive `-metadata title=…` one-liner emits). QuickTime reads some, but it's the older,
  lossier mapping.

The generic "second menu" some workflows add is **not** metadata — it's a **chapter
text track**: a `data` stream (`bin_data`, tag `text`) with `tref→chap` links from the
A/V tracks, which QuickTime renders as a navigable chapter menu. `-map 0 -map -0:d`
drops it (data tracks only); `-map_chapters -1` stops it being regenerated.
`scripts/metadata.sh` does all of this (plus `-fflags +bitexact` to drop the generic
`encoder=Lavf…` tag) — and it is **opt-in**: the remux path never tags anything.

## Tools & specs

`ffprobe` (streams/format), `mediainfo` (human summary, field-structure detail),
Bento4 `mp4dump` (atom dump), GPAC `MP4Box` (validate/edit/fragment),
`exiftool` (QuickTime metadata tags). Specs: Apple QTFF specification
(archived at developer.apple.com via web.archive.org), ISO/IEC 14496-12
(ISO BMFF), mp4ra.org (registered brands/codec tags).

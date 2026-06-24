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

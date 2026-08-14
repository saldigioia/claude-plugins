# Alternate groups: QuickTime's language menu (reference)

How multi-audio `.mov` deliverables get a working language menu, what every
candidate tool actually does to `tkhd alternate_group` (all measured), and why
`scripts/qt-groups.sh` patches two bytes instead of remuxing. Bench for every
measurement in this file: **2026-08-14, macOS 26.6.1, ffmpeg 9.0.1, GPAC/MP4Box
26.07** — grouping semantics are a property of the reader, so re-verify on a
new bench before trusting a verdict here.

## The mechanism (QTFF/ISOBMFF)

QuickTime Player offers an audio-language menu when the audio tracks form an
**alternate group**: every candidate track carries the same **nonzero** 16-bit
`alternate_group` in its `tkhd`, and **exactly one** of them has the enabled
flag set (`tkhd` flags bit 0 — Apple TN3177's "one enabled track per group").
The menu **names** come from the per-track language (`mdhd` code / `elng`),
which survives every `-c copy` (WO 3.5); the grouping only declares that the
tracks are alternatives. `alternate_group=0` means "not part of any group":
present-but-disabled tracks with no declared group get **no menu**.

`tkhd` is a fixed-layout leaf — the field sits at a version-dependent offset:

| tkhd version | box size | `alternate_group` offset from box start |
|---|---|---|
| v0 (32-bit times) | 92 B | +42 (8 hdr + 4 ver/flags + 4+4 times + 4 id + 4 rsvd + 4 dur + 8 rsvd + 2 layer) |
| v1 (64-bit times) | 104 B | +54 (same walk with 8-byte times/duration) |

Any other size/version is a layout nobody proved offsets for — qt-groups.sh
refuses the file untouched.

## Who needs the post-pass (measured)

- **ffmpeg 9.0.1 movenc already writes `alternate_group=1` on every audio
  tkhd** — measured on `.mov` and `.mp4` mode, single- and multi-audio, along
  with exactly one enabled audio track. Fresh builds on this bench are
  conformant out of the muxer; qt-groups.sh detects that and **no-ops, writing
  nothing**. (ffmpeg exposes no muxer option for the field — `-h muxer=mov`
  confirmed — the behavior is hardcoded.)
- The retrofit population: outputs of 8.x-era movenc and third-party muxers
  carrying `alternate_group=0`, and files that went through a group-scrubbing
  tool pass (`MP4Box -group-clean` zeroes every tkhd group — measured; that is
  also how the regression fixture is minted).

## Avenue log — what each tool really does

The dossier's first attempt stalled on MP4Box import syntax ("the incantation
is unfinished"). Finished, and corrected, below.

| Avenue | Measured result | Verdict |
|---|---|---|
| `MP4Box -group-add refTrack=0:switchID=-1:trackID=2:trackID=3:trackID=4 file.mov` (ONE `-group-add`, trackIDs colon-chained) | **Works**: all named tracks get one shared `Alternate Group ID`, essence preserved (video `-f md5` + per-stream audio `streamhash` identical), moov stays up front, same file size, enabled flags kept | The working MP4Box recipe — but the whole moov is rewritten (box layout visibly changes, `wide`→`free`), so "nothing ELSE changed" must be trusted, and it needs per-file track-ID bookkeeping |
| Separate `-group-add` args (`-group-add refTrack=0:trackID=2 -group-add trackID=3 …`) | Three **different** group IDs (1, 2, 3) — each arg opens a new group | Wrong shape for a language menu |
| `MP4Box -add self#2:group=5` (the import-option form; the dossier's dead end) | The group **does** land in 26.07 — but wrong-scoped: it re-imports, and the file's audio group set went `{1,1,1}` → `{5,1,1}` (uniform grouping destroyed) | Dead end (corrected reason: not "doesn't land" but "lands on the wrong scope") |
| `MP4Box -group-clean` | Zeroes `alternate_group` on **every** trak, essence intact | The fixture mint; also the hazard class this post-pass repairs |
| `MP4Box -lang 2=eng` (a plain in-place edit) | Groups **survive** (26.07). An earlier draft claimed edits strip them — **unreproduced** on this bench | In-place edits are not group-destructive here |
| gpac filter session `gpac -i in.mov -o out.mov` | **Drops the disabled tracks** (4 → 2 measured) unless `:alltk` is given | Destructive default; not a candidate |
| ffmpeg re-mux | No option to set the field; a remux re-timestamps/re-packages — the heaviest tool for a 2-byte field | Not a candidate |

## Why qt-groups.sh patches bytes instead

The surgical route wins on **proof strength, not necessity**: after walking the
real box tree (top-level → `moov` → per-`trak` `tkhd`+`hdlr`; never a byte
scan, which would false-positive inside `mdat`) and writing the 16-bit field in
a full copy, the script can *prove* losslessness rather than trust it —
`cmp -l` must show **every** differing byte inside the patched 2-byte fields
and none elsewhere. No remux tool can make that statement; MP4Box's own
working recipe rewrites the whole moov.

The five proofs, all inside the `.part` before it is blessed (the WO 5.3
contract — a binary edit is acceptable **only** carrying its proofs):

1. **byte-diff bound** — `cmp -l` source vs part: ≥1 and ≤2·patched bytes
   differ, all inside patched fields; `mdat` untouched by construction;
2. **video essence** — `ffmpeg -map 0:v -c copy -f md5` identical;
3. **audio essence** — per-stream `-f streamhash -hash md5` identical;
4. **independent parse** — `MP4Box -info` exits clean AND prints
   `Alternate Group ID <G>` on exactly the audio-track count (an independent
   reader sees the semantics, not just our bytes);
5. **verify.sh** source-vs-output green (its REVIEW propagates as exit 10).

Enabled flags are **reported, never flipped** — movenc already writes exactly
one enabled audio track, and changing enablement is a mapping decision this
pass has no mandate for. Two-enabled inputs still get grouped, then exit 10
(REVIEW) with `enabled=2` in the summary. If a non-audio track already claims
group 1, the audio group becomes `max(existing)+1` (collision-free by
construction).

## Operating it

```
scripts/qt-groups.sh INPUT.mov OUTPUT.mov
```

**Opt-in, operator-invoked** — not wired into mov.sh's default path (fresh
builds on this bench don't need it). Source never touched; output atomic
(`.part` → `mv`); exit 0 grouped-and-proven **or** honestly nothing to do
(writes nothing), 10 REVIEW, 1 FAIL (proof failed — evidence `.part` kept),
2 usage/environment (needs MP4Box for proof 4). Machine line:

```
QTG_SUMMARY date=… macos=… mp4box=… audio=N enabled=N group=G patched=N out=PATH|none
```

Pinned by `tests/regression.d/53-qt-groups.sh` (no-op on fresh builds,
retrofit with all proofs, idempotence, REVIEW honesty, guards).

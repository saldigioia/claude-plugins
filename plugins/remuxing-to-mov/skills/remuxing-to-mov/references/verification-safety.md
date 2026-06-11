# Multi-Track, Verification & Workflow Safety

Selecting tracks, proving losslessness, and not destroying source material.
`verify.sh` automates the verification below.

## Track selection & mapping

- Keep everything: `-map 0:v:0 -map 0:a` (video + all audio). Add `-map 0:s` only
  to carry subtitles.
- Keep one: `-map 0:v:0 -map 0:a:0`. Drop SAP/secondary by not mapping it.
- Audioless or uncertain sources: use optional maps (`-map "0:a?"`) so the mux
  doesn't fail when a stream is absent.
- The first mapped audio becomes the default track — map the primary (e.g.
  English 5.1) first.

## Language tags

- Copy preserves existing tags. PS (`.mpg`) carries none — add
  `-metadata:s:a:0 language=eng`. Repair junk tags (e.g. `aaa`) the same way.
- For PCM-decoded audio, set the language explicitly (the decode may not carry it).

## Per-track delays

AC-3/E-AC-3 captures often carry a small `Delay relative to video`. It's in the
timestamps and **preserved by `-c copy`** — leave it. Only the Rung-3 rebuild
rezeros it; reapply a real offset with `-itsoffset` there.

## Verifying a lossless remux (run before trusting output)

`scripts/verify.sh SOURCE OUTPUT` runs the cheap tier; add `--full` for the
exhaustive one. **Do not default to whole-file decoding** — two full decodes
cost roughly the video's runtime in CPU and are almost never needed.

**Cheap tier (demux + ~30 s of decode, regardless of file length):**

```
# (a) packet-hash identity — demux only, ZERO decode. A match PROVES lossless.
ffmpeg -v error -i IN  -map 0:v:0 -c copy -f streamhash -hash md5 -
ffmpeg -v error -i OUT -map 0:v:0 -c copy -f streamhash -hash md5 -
# A MISMATCH here is INCONCLUSIVE, not a failure: TS sources get SPS/PPS
# re-placed and Rung-3 rebuilds repacketize, so identical video can hash
# differently at the packet level. Fall through to (b).
# (b) decoded spot-identity: first ~300 frames, hash column only
ffmpeg -v error -i F -map 0:v:0 -frames:v 300 -f framemd5 - \
  | grep -v '^#' | awk -F', *' '{print $NF}'        # must match IN vs OUT
# ...plus video packet-count parity (ffprobe -count_packets; demux only).
# (c) output decode spot-checks: 10 s windows at middle and tail (-f null)
# (d) timeline clean
ffprobe -v error -select_streams v:0 -read_intervals "%+#3000" -show_entries packet=dts -of csv=p=0 OUT \
  | awk -F, 'NR>1 && $1!="N/A" && p!="N/A" && $1<p {b++} {p=$1} END{print b+0" backward-DTS (want 0)"}'
# (e) if the SOURCE failed the MKV strict-mux test, confirm OUT now passes it
# (f) scrub by eye at start / middle / end
```

**Exhaustive tier (`--full`) — whole-file decoded-pixel identity:**

```
ffmpeg -v error -i IN  -map 0:v:0 -c:v rawvideo -f md5 -
ffmpeg -v error -i OUT -map 0:v:0 -c:v rawvideo -f md5 -   # must match
```

Reserve `--full` for: final archival sign-off, settling a REVIEW verdict from
the cheap tier (e.g. packet counts differ and no Rung-3 rebuild explains it),
or once per new pipeline/source type to validate the recipe — then trust the
cheap tier for the rest of the batch.

**Hash the right thing.** Decoded comparisons must be timestamp-agnostic: do
NOT md5 full `framemd5` lines — they include dts/pts/duration columns and
FALSE-mismatch after any re-timing rebuild (rebuild-paff.sh changes the
timeline). Compare only the hash column. Likewise raw-bitstream MD5
false-mismatches on TS sources (SPS/PPS re-placement) — that is why a
streamhash mismatch only escalates, never fails.

## Container-valid ≠ QuickTime-playable

A correct mux can still fail to play; don't chase a phantom "bad mux".

| Content | Validly in MOV? | Plays in QuickTime Player? |
|---------|-----------------|----------------------------|
| HEVC tagged `hev1` | Yes | No — needs `-tag:v hvc1` |
| MPEG-2 4:2:0 | Yes | Yes |
| MPEG-2 4:2:2 (422@HL) | Yes | Generally no |
| Dolby Vision HEVC | Yes (ffmpeg ≥5.0, single-layer) | Device/app-dependent |
| AC-3 / E-AC-3 | Yes | Unverified (historically not native) |
| DTS / DTS-HD MA | Yes | No |
| MP2 | Yes (non-standard) | Not expected |

For genuine playback of the "no/unverified" rows you're at Rung 4 (transcode —
see `delivery-encode.md`), or keep the original container for archival.

## Workflow safety (lessons that cost real files)

- **Gate every step** (`set -e` / `&&`) so a failed step aborts *before* cleanup.
- **Never auto-delete** temp/elementary files — remove by hand after verification.
- **Atomic output**: write `OUT.part` (with `-f mov`), `mv` to the final name only
  on success.
- **The source is the master** — original `.ts`/`.mkv` is immutable; PCM/MOV
  derivatives are regenerable.
- **`-nostdin`** in every batch call so a loop can't be consumed by a prompt.

## Synthesizing test files

Known-good vectors for exercising a pipeline step without touching real
captures (the same technique used to verify this skill's facts):

```
# H.264 + AAC in MP4
ffmpeg -f lavfi -i testsrc2=size=1280x720:rate=25 -f lavfi -i sine=frequency=1000:sample_rate=48000 \
  -t 5 -c:v libx264 -pix_fmt yuv420p -c:a aac -b:a 128k -movflags +faststart t_h264_aac.mp4
# ProRes 422 HQ + PCM in MOV
ffmpeg -f lavfi -i testsrc2=s=1280x720:r=24 -f lavfi -i sine=1000 -t 5 \
  -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le -c:a pcm_s16le t_prores_pcm.mov
# HEVC (hvc1) + AAC in MP4
ffmpeg -f lavfi -i testsrc2=s=1280x720:r=30 -f lavfi -i sine=1000 -t 5 \
  -c:v libx265 -tag:v hvc1 -pix_fmt yuv420p10le -profile:v main10 -c:a aac t_hevc_hvc1.mp4
```

## Version-dependent behavior (probe.sh surfaces these)

Tested ffmpeg 6.1.1: MP2 muxes into MOV but is non-standard (decode for
playback); no `fiel` atom on copy (field order via bitstream); `colr` written by
default; HDR10 `mdcv`/`clli` in SEI only; Dolby Vision survives copy on ffmpeg
≥5.0 (single-layer). Confirm on your ffmpeg and on the target QuickTime.

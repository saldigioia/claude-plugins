# Dual-track delivery: QuickTime-ready + minimal loss (DEFAULT)

**Governing goal:** every delivered `.mov` should *just play* in stock QuickTime/macOS,
while losing as little as possible from the source. The way to get both at once is a
**dual-track MOV**:

- **Track 1 — PCM "access" (default/enabled):** decoded to LPCM, which QuickTime always
  plays. This is the track that plays by default.
- **Track 2 — original audio, copied bit-exact:** the source bitstream (AC-3, DTS-HD MA,
  E-AC-3, MP2, …) preserved untouched for provenance and future re-derivation.

This is **non-destructive** and should be the **default deliverable in most cases**. It
never overwrites the source; the originals are always kept. Video is always `-c:v copy`
(bit-identical). Use `scripts/dual-track.sh`.

> When a single track is enough: if the source audio is *already* QuickTime-playable AND
> you don't need a separate access/preservation split (e.g. AAC/ALAC), a plain
> `remux.sh` copy is fine. Reach for dual-track whenever the original is *not* QuickTime-
> playable (DTS-HD MA, MP2) or whenever you want a guaranteed-playable PCM track alongside
> a preserved original. When unsure, default to dual-track.

## Audio handling rules (what track 1 should be)

| Source audio | Lossy? | Track 1 (PCM access) | DRC | Notes |
|---|---|---|---|---|
| DTS-HD MA, TrueHD, ALAC, FLAC, LPCM | lossless | PCM at **native** depth (16→`s16le`, 24→`s24le`) | n/a | PCM is a *bit-exact* reconstruction of the original. |
| AC-3 / E-AC-3 | lossy | **`pcm_s24le`** (decoder emits float; 24-bit captures it) | **`-drc_scale 0`** (full dynamic range) | PCM can't beat a lossy source; goal is the most faithful decode. |
| MP2 / MP1 / MP3 / AAC / DTS core | lossy | `pcm_s24le` (or native depth) | — | Decode faithfully; keep original as track 2. |

`dual-track.sh --pcm auto` picks depth from the decoder's native `sample_fmt`
(`s16`→16, `flt/fltp`→24, `s32`→32). `--drc auto` disables AC-3/E-AC-3 DRC by default.

## The two-pass rule (alignment-safe cutting) — IMPORTANT

When you also need to **cut** a slice, do **not** build the dual-track in one pass with
`-ss` before `-i` while mapping the same audio twice (one decoded to PCM, one copied):
ffmpeg trims the *decoded* PCM to the exact seek time but keeps *whole frames* on the
*copied* track, so the two audio tracks end up offset by up to ~0.5 s (one AC-3/codec
frame or a GOP). Instead:

1. **Pass 1 — lossless copy-cut:** `-ss START [-to END] -i SRC -map 0:v:0 -map 0:a:0 -c copy
   -avoid_negative_ts make_zero` → a clean video+original-audio slice.
2. **Pass 2 — decode + copy, NO `-ss`:** from that cut, `-map 0:v -map 0:a:0 -map 0:a:0
   -c:v copy -c:a:0 pcm_… -c:a:1 copy`. Both audio tracks now derive from identical frames
   → guaranteed aligned.

`dual-track.sh --ss/--to` does this automatically.

> A MPEG-2 lossless cut legitimately shows video `start_time` ≈ 0.45 s while audio is 0 —
> that's the keyframe/edit-list offset, identical to a plain single-pass copy cut, and it's
> honored by players. It is **not** a sync defect (verify by comparing to a plain copy cut).

## Verification (always)

1. **Alignment / content identity (the key one):** decode **track 2** with the *same*
   parameters used to build track 1; its md5 must equal **track 1**. This proves both
   tracks are present, aligned, and content-identical.
   ```bash
   a=$(ffmpeg -v error [-drc_scale 0] -i OUT.mov -map 0:a:0 -f s24le - | md5sum)
   b=$(ffmpeg -v error [-drc_scale 0] -i OUT.mov -map 0:a:1 -c:a pcm_s24le -f s24le - | md5sum)
   [ "$a" = "$b" ] && echo ALIGNED
   ```
2. **Video lossless:** packet-level `streamhash` of source vs output video (timestamp-immune;
   preferred over framemd5, which false-FAILs on field-coded/PAFF streams across seek paths).
3. **Dispositions:** track 1 = `default`; ffprobe `disposition:default` → `1,0`.
4. **Clean decode:** `ffmpeg -xerror -i OUT -map 0 -f null -` → 0 errors. **astats** for
   peak/clipping. Durations preserved.
5. **Source AC-3/decode integrity:** decode-to-null and report any source dropouts honestly
   (they live in the source and carry through; PCM can't be cleaner than its source).

## Two hard-won safety rules

- **Probe the actual input right before building — never assume its codec.** Files get
  renamed/replaced out from under you. Run `ffprobe` on the input first; if it isn't what
  you expect (e.g. a PCM file where you expected the DTS original), STOP.
- **Lossy → PCM is a faithful decode, not added fidelity.** Keep the original (track 2) so
  nothing is truly lost; and keep the untouched source file too — a re-containerized copy is
  not a substitute for the original capture.

## Quick examples

```bash
# Full-file dual-track from a TS with AC-3 (24-bit PCM access, full dynamic range, AC-3 kept)
dual-track.sh "feed.ts" "feed.mov"

# Lossless source (DTS-HD MA): PCM at native depth, original DTS kept
dual-track.sh "video.mov" "video.dual.mov"          # --pcm auto picks 16/24

# Cut a scene (alignment-safe two-pass), keep original as track 2
dual-track.sh "feed.ts" "01.mov" --ss 00:35:00.165 --to 00:41:44.235
```

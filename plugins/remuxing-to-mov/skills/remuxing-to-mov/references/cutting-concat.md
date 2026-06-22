# Lossless Cutting, Trimming & Concatenation

Copy edits obey one hard constraint: a copy cut can only land on a keyframe.
Everything here stays in `-c copy` except the one marked exception.

## Keyframe-bound reality

`-c copy` cannot split a GOP. An input seek (`-ss` before `-i`) snaps to the
keyframe at or before the requested time. Copy cuts are **GOP-accurate, not
frame-accurate**.

List valid cut points (keyframes) in the head of a file:
```
ffprobe -v error -select_streams v:0 -read_intervals "%+20" \
  -show_entries packet=pts_time,flags -of csv=p=0 IN | awk -F, '$2 ~ /K/ {print $1}'
```
Measure against the file you will actually cut (a trimmed file has different
keyframe positions than its source).

## Open-GOP seam glitch — not every keyframe is safe to cut in front of

The keyframe rule has a sharp edge. **QuickTime distinguishes two kinds of
random-access frame** (verified against the QuickTime File Format spec):

- A **full sync sample** (`stss`) — the spec's words: *"self-contained … 
  independent of preceding frames."* A **closed-GOP / IDR** keyframe. Safe to
  start a segment on.
- A **partial sync sample** (`stps`) — an **open-GOP** I-frame. A random-access
  point, but the frames around it display *earlier* (`ctts` composition offsets)
  and depend on the **previous** GOP (`sdtp` flag *EarlierDisplayTimesAllowed*).
  **Not** self-contained at a join.

If a segment **starts on an open-GOP (partial-sync) I-frame**, its leading
B-frames still carry motion + residual that point into the GOP you deleted.
Decoded **alone**, the decoder fills the missing reference with black → looks
fine. Decoded **after another segment**, it applies that leftover prediction to
the *previous segment's last frame* → **one garbage frame at the seam**. The
artifact exists *only* in the join — neither segment shows it alone — which is
the tell that it is a *seam* (prediction) problem, not a *content* problem.

> Bites any keyframe-accurate copy-cut/concat at an open-GOP / non-IDR boundary —
> MPEG-2 **or** H.264, not show- or codec-specific.

- **Tell, before cutting:** in display (PTS) order at the intended start, a `B`
  frame appears *before* the first `I`. `scripts/gop-probe.sh INPUT CUT_TIME`
  automates this and prints the nearest **closed-GOP** keyframe to use instead.
- **Check, after concat:** `scripts/seam-check.sh JOINED.mov SEAM_TIME` decodes
  continuously **through** the join (never seeking onto it — that hides the
  artifact) and flags a one-frame flash by continuity (the frames before and
  after match each other but not the spike). `--png DIR` exports the straddling
  frames; eyeballing them is the final word (a glitch can be valid bitstream).
- **Fix, stay lossless:** restart the segment on the next **closed-GOP** keyframe
  (`gop-probe.sh` prints it), input-seek so audio+video cut together, and confirm
  the skipped span holds no wanted content. If an *exact* open-GOP timestamp is
  required, **smart-cut** the boundary GOP (below) — re-encode ~1 s to close it,
  copy the rest.

## Order of operations (critical for field-coded H.264)

**Fix the timeline first, then trim the clean file.** Never input-`-ss` a broken
or field-coded TS for a copy cut — the seek lands mid-GOP/mid-field-pair and
shatters the reference chain. Repair to a clean MOV (see `timeline-repair.md`),
verify, then cut that.

## The `-map 0` trap on broadcast/MKV sources

The recipes below use `-map 0` for brevity, but `-map 0` also pulls subtitle and
data streams — and MOV refuses many of them **at header write** (`Could not find
tag for codec subrip in stream …`; verified 8.1.1; DVB subs/teletext/SCTE data
have no MOV mapping either). On sources carrying subs or data streams, map
explicitly (`-map 0:v:0 -map 0:a`) and sidecar the subtitles
(`color-hdr-subs.md`). Embedded 608/708 captions are unaffected — they ride
inside the video stream.

## Head-trim (drop a dead opening)

```
ffmpeg -nostdin -ss KEYFRAME_TIME -i IN -map 0 -c copy \
  -avoid_negative_ts make_zero -movflags +faststart -f mov OUT.mov
```
If the content start isn't on a keyframe, cut to the keyframe just before (keep
a little lead-in — the archival-safe direction), or accept a smart-cut below.

## Cut out interior segments + rejoin (concat demuxer, one copy pass)

List keep-segments as in/out points (absolute seconds in the source):
```
cat > cuts.txt <<'LIST'
file 'IN.mkv'
inpoint 0
outpoint 12043
file 'IN.mkv'
inpoint 15865
outpoint 18838
file 'IN.mkv'
inpoint 27281
LIST
ffmpeg -nostdin -f concat -safe 0 -i cuts.txt -map 0 -c copy \
  -avoid_negative_ts make_zero -movflags +faststart -f mov OUT.mov
```
Last entry with only `inpoint` runs to end. Boundaries still snap to keyframes.
If the audio is anything MOV can't carry, keep the edit in MKV, then remux to MOV
after (see `ingest-compatibility.md`).

## Join same-source parts

Segmented captures with identical codec parameters concat cleanly **when each
part starts on a closed-GOP I-frame** — verify that assumption with
`scripts/gop-probe.sh PART` (open-GOP parts will flash at the joins, above):
```
printf "file '01.mpg'\nfile '02.mpg'\n" > parts.txt
ffmpeg -nostdin -f concat -safe 0 -i parts.txt -map 0:v:0 -map 0:a:0 -c copy \
  -avoid_negative_ts make_zero -movflags +faststart -f mov joined.mov
```

## The hard limit — frame-exact at a non-IDR boundary (Rung 4)

A frame-exact cut where the target is mid-GOP cannot be done by copy. The only
lossless-for-the-rest option is **smart-cut**: re-encode just the opening partial
GOP (cut point → next keyframe) to match the stream, then copy from that keyframe
on. Touches ~1–2 s of video; the bulk stays bit-identical. This is the single
editing case that forces any re-encode.

## PAFF / concat caveats

- Copy-concatenating PAFF H.264 at non-IDR joins can glitch at the seams; if it
  does, smart-cut the seam GOPs or run the `timeline-repair.md` rebuild first.
  (This is the open-GOP seam glitch above, compounded by field coding — the cut
  lands on a partial-sync sample *and* mid-field-pair.)
- The concat demuxer requires consistent codec parameters across all entries;
  mixed resolutions/codecs won't copy-concat.
- **Always run `scripts/seam-check.sh JOINED.mov <seam_times>` after a copy-cut
  concat.** A clean error scan does not clear the join — the open-GOP flash is
  valid bitstream; the continuity/eyeball test is what catches it.

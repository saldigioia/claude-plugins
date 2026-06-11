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

Segmented captures with identical codec parameters concat cleanly (each part
starts on a closed-GOP I-frame):
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
- The concat demuxer requires consistent codec parameters across all entries;
  mixed resolutions/codecs won't copy-concat.

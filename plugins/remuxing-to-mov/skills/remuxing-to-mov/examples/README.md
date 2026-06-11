# Worked examples (job-specific, kept for the cut-point data)

Driver scripts from real sessions using this skill. Paths and START/END
timestamps are hardcoded to specific SNL broadcast captures — not generic
tools, but the cut points are hard-won and the scripts double as worked
examples of the skill's patterns:

- `slice.sh` — Rung 0/1 lossless keyframe-bound copy-cuts (`-c:v copy`,
  per-task audio, atomic `.part` → `mv`).
- `verify-slices.sh` — per-slice QC: framemd5 range-vs-output, clean decode,
  keyframe-start, duration.
- `verify-remux.sh` — full-remux QC: timestamp-immune `streamhash` video/audio
  compare, duration, backward-DTS count, stream layout. The `verify()`
  function is generic; only the bottom invocations are job-specific.

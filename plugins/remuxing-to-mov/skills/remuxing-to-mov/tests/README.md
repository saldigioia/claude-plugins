# Regression tests

`regression.sh` pins the field-coded (PAFF) safeguards that were added after a
genpts'd field-coded remux passed the mux tests, shipped, and tore on scrub.

```
bash tests/regression.sh        # needs ffmpeg + ffprobe built with libx264
```

Exit 0 = every assertion passed. It synthesizes its own fixtures in a temp dir
(cleaned up on exit) and runs the real `scripts/` against them.

## What it covers

1. **No false positive** — a clean H.264 copy verifies `OK`.
2. **Fix 3 (lossless arbiter)** — the VCL-payload hash is equal across a re-timed
   lossless copy while decoded `framemd5` diverges, i.e. the check that would
   false-FAIL field-coded streams is no longer the one deciding losslessness.
3. **Real loss still fails** — a re-encode trips the VCL mismatch → `FAIL`.
4. **Fix 2 (seekability)** — a single-GOP file passes the mux, lossless and
   backward-DTS checks yet is flagged `REVIEW` by the scrub gate's keyframe
   sanity (it is effectively not seekable).
5. **Coverage gap closed** — the old keyframe-accurate spot decode is shown
   *blind* to that single-GOP file (0 errors), and `verify.sh` is shown to run
   accurate off-keyframe (`-ss` after `-i`) seeks.
6. **Broken timeline** — a lossless copy on a degenerate timebase never gets a
   clean `OK`.
7. **Fix 1 (detector)** — the coded-picture-rate PAFF test fires at ~2× cadence
   (59.94/29.97, 50/25), stays quiet at 1×, and maps to the right field rate.
8. **Phase 0** — `doctor.sh` reports a usable env; `verify.sh` degrades without a
   false-FAIL when the VCL bitstream filters are absent (`RTM_FORCE_NO_VCL=1`).
9. **Phase 1** — `probe.sh --kv/--json` emits the structured block and the right
   recommended rung (clean H.264 → 0, MP2 audio → 1).
10. **Phase 2** — `auto.sh` routes the ladder, is verify-gated, refuses
    source==output, writes nothing on `--dry-run`, escalates on a non-OK verdict,
    and never auto re-encodes or falsely reports DONE.
11. **Phase 3** — `--audio` proves the dual-track original bit-exact (FAIL if a
    re-encode) and the access track aligned; `--signaling` flags an HEVC `hev1`
    tag as drift → REVIEW.
12. **Phase 4** — `batch.sh` writes verified outputs + provenance sidecars,
    never deletes sources, and resumes idempotently (skips already-OK, unchanged).
13. **Phase 5** — `playable-check.sh` skips cleanly on non-macOS (exit 3) and
    `auto.sh --playable` keeps OK when playability is unknown.
14. **Review fix #4** — `rebuild-paff.sh` preserves real per-track audio language
    (fra/spa), not a hard-coded `eng`.
15. **Open-GOP seam glitch** — `gop-probe.sh` flags an open-GOP (partial-sync) cut
    point and names the nearest closed-GOP keyframe (exit 10), clears a closed one,
    and false-positives on neither real H.264 IDR media; `seam-check.sh` catches a
    one-frame flash (by before/after continuity), does NOT flag a legitimate hard
    cut, and passes a clean continuous join.

## Synthesis limit (why some things aren't tested directly)

`libx264` cannot mint true broadcast PAFF (separate field pictures), and the
specific failure — *decodes clean but tears on an off-keyframe scrub* — cannot be
reproduced synthetically: ffmpeg discards pre-seek frames before any decoder/
muxer sees them, so a faked non-monotonic timeline simply does not error on a
seek. The harness therefore validates the surrounding machinery (seekability
sanity, gate execution, hash invariance, detector math) rather than re-creating
the corruption. A **real capture played in a real player** remains the final
arbiter — the skill's standing "playable ≠ valid" rule.

The same applies to the **open-GOP seam glitch**: libx264/x265 won't emit true
leading B-frames on synthetic content, so `gop-probe.sh`'s detector is unit-tested
against a crafted frame table (`GOP_PROBE_CSV`) plus a real-media no-false-positive
check, and `seam-check.sh` is tested against a synthesized one-frame flash, a
legitimate hard cut, and a clean join. A real capture + eyeballing the seam frames
remains the decisive test.

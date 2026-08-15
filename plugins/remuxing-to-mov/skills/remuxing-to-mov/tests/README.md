# Regression tests

`regression.sh` pins the field-coded (PAFF) safeguards that were added after a
genpts'd field-coded remux passed the mux tests, shipped, and tore on scrub.

```
bash tests/regression.sh        # needs ffmpeg + ffprobe built with libx264
```

`make-fixtures.sh` mints the on-disk fixture corpus the v1.11 phases test
against — see [Fixture corpus](#fixture-corpus-make-fixturessh) below.

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
14. **Rebuild scope limit + review fix #4** — `rebuild-paff.sh` REFUSES a
    reordered (B-frame) source (exit 3; the constant-rate restamp would play it
    in decode order), `--force` bypasses only the refusal while the output
    timeline gates still decide blessing, and on a legit no-reorder source it
    preserves real per-track audio language (fra/spa), not a hard-coded `eng`.
15. **Open-GOP seam glitch** — `gop-probe.sh` flags an open-GOP (partial-sync) cut
    point and names the nearest closed-GOP keyframe (exit 10), clears a closed one,
    and false-positives on neither real H.264 IDR media; `seam-check.sh` catches a
    one-frame flash (by before/after continuity), does NOT flag a legitimate hard
    cut, and passes a clean continuous join.
19. **Post-mortem 2026-07-25 safeguards** — the coded-picture-rate detector
    counts untimestamped packets (a half-timestamped window reads ~2×, not the
    old false-negative ~1×) and the ~0.5 missing fraction reads as the pair
    signature; `pf_reorder_scan` fires on B-pyramid tick tables and stays quiet
    on flat PTS==DTS; `mux_confessions` counts the three muxer confession
    classes; `remux.sh` HARD-STOPs (exit 1, output not blessed) on a confessing
    mux log; `pairfill-paff.sh` refuses non-matching streams (exit 3), builds a
    fully-timestamped source end-to-end, and keeps the source presentation
    order; `probe.sh --kv` carries the routing profile (PF_HALF_TS/PF_REORDER).
24. **Backhaul gates, demoted (1.11)** — `disc_scan` counts whole-file DTS rot
    (backward/duplicate) alongside forward gaps; a 4:2:2 source (MPEG-2 and
    H.264 Hi422) **builds** (rc 0/10) with the shared
    `contribution profile <codec>/<pix_fmt>` advisory and the post-build
    `MOV_PLAYABILITY` check — no `MOV_REFUSED profile=qt-undecodable` remains;
    mpegts/MPEG-2 gap-plus-rot timelines **warn + build** (`MOV_ROT_WARN`, the
    refusal's three routes, and *no* `MOV_REFUSED` — nothing may print a
    refusal and then build); gaps alone pass clean; `--force-backhaul` stays
    accepted as API; `diagnose.sh` prints the shared advisory (the stale
    "refuses early, exit 11" banner is asserted gone); `resync.sh` still
    refuses mid-stream channel-layout changes (exit 11, the silence-injection
    class) while single-layout sources build; `verify.sh --silence` FAILs
    injected silence that duration parity cannot see and passes a clean copy.
25. **ts-health.sh** — the consolidated demux-only capture scan: a clean file
    reads CLEAN (exit 0); injected packet tables prove missing-timestamp
    routing (genpts/pairfill) with gap counts across the holes annotated
    unreliable, 33-bit PTS wraparound classified as wrap (never backward-DTS
    rot), and mid-GOP start routed to the lossless first-IDR trim; injected
    transport logs prove small continuity loss reads FINDINGS (stated
    permanent) while a flood reads DAMAGED (exit 1, re-capture); `--kv` emits
    the machine block.
26. **Gate at every entry point (1.10.0 mechanism, 1.11 semantics)** — the
    shared `backhaul_gate` runs on EVERY route that writes a `.mov`, not just
    the `mov.sh` front door (the 2017-feed bypass: a direct/batch build once
    produced a doomed MOV the front door would have caught): `auto.sh`,
    `remux.sh`, `rebuild-paff.sh`, `dual-track.sh`, and `pairfill-paff.sh` all
    consult it — since 1.11 **neither arm refuses anywhere**: rot warns +
    builds and 4:2:2 is announced + proven post-build (standalone builders
    print the prove-it-yourself advisory); routes name `ts-health.sh` (TS/MKV
    custody is health-checked, not assumed); `RTM_FORCE_BACKHAUL=1` reaches
    children and silences only the rot scan/warning; `batch.sh` still
    classifies a propagated exit 11 (e.g. resync's layout guard) as its own
    `REFUSED` verdict class, never a batch failure.
27. **Per-work-order suites (`tests/regression.d/`)** — every executable
    `regression.d/*.sh` runs in sorted order as one test each of this run:
    probe defaults + the 1G retry line (11/12), the `--ss` origin guard (13),
    exit-code contract incl. the legacy 3s (14), mid-GOP diagnose + trim-to-idr
    (21/22), gate-(f)-only escalation + source gap budget (23/24), seam-check
    on ffmpeg 9 (25), pcm_bluray routing (31), per-track `auto` + keep-all
    default + language dedupe/curation (32–35), verify gate (g) (36), `--drc`
    (37), the 4:2:2 empirical demotion (41), rot demotion (42), the 1.12
    fidelity↔retag pair (43), the native-codec matrix (51), unroutable-codec
    refusals (52), qt-groups (53), and the WO 5.4 probe advisory surfaces
    (54: the multi-program-TS NOTE with its measured PAT-order routing basis,
    and the >24 h / 33-bit PTS-wrap horizon NOTE; the mid-stream SPS-change
    class from the same 5.4 pass has **no warning surface to pin** —
    known-limits.md records it as detect-and-warn candidate, not
    implemented), and the 1.11 adversarial-review fix round (60: qt-groups
    maps verify's TEXT verdict so REVIEW propagates as 10; verify `--audio`
    tolerates the automatic ADTS→ASC reframing on a dual-track AAC original
    with a wrong-source negative control; unroutable-codec refusal parity at
    auto.sh/remux.sh/batch.sh — exit 11, `MOV_REFUSED`, no `.part` litter,
    batch REFUSED row; batch sidecar `PROV_RUNG=S` for uppercase rungs; the
    non-audio-drop WARN + `RMX_PLAN unmapped=`; the >16-bit PCM-access depth
    WARN). Corpus discipline (6.3): before the sub-suites run, every member
    of `make-fixtures.sh`'s ALL list that is missing is healed in ONE
    up-front call, so the sub-suites' own self-heal blocks (kept for
    standalone invocation) are no-ops inside a suite run and regeneration
    happens exactly once per run.
28. **The fidelity↔retag pair (1.12, `regression.d/43-fidelity-retag.sh`)** —
    one synthetic MPEG-2 4:2:2 clip, two stream-copy builds (`-c copy` → stsd
    `m2v1`; `-c copy -tag:v xd5b` → the XDCAM HD422 entry), pinning WO-A (the
    retag route) and WO-B (the fidelity gate) against each other so neither
    silently regresses: the tags land as built and the video packet hash is
    identical across source/m2v1/xd5b (the retag is provably lossless);
    `probe.sh` fires `PR_TAG_ADVICE=xd5b` (kv) / `tag_advice` (json) on the
    m2v1 build only — NOT on the already-retagged xd5b build (idempotent, no
    advisory loop) and NOT on a 4:2:0 MOV carrying the very same `m2v1` stsd
    (the pix_fmt discriminator is pinned, not assumed); the
    `playable-check.sh --fidelity` flag surface never exits 2/unknown-option
    and always announces its `PLAYCHECK_FIDELITY` machine line. On a macOS
    bench the xd5b build proves `verdict=ok` with SSIM ≥ threshold, the m2v1
    build is asserted *verdict-following* (exit code follows whatever verdict
    this macOS measures — drift-proof), and `RTM_FIDELITY_SSIM=0.99` over the
    healthy build forces the documented `verdict=fail reason=fidelity` exit 1
    (the gate CAN fail); off-macOS those halves are announced SKIPs naming
    what was not proven. SYNTHESIS LIMIT: the synthetic clip does NOT
    reproduce the consumer-decoder corruption (evidence bench macOS 26.6.1 /
    ffmpeg 9.0.1, 2026-08-15: SSIM ~0.95 as m2v1, fidelity=ok) — the
    destroyed-render half is operator-verified (2026-08-15, two real
    1080i59.94 broadcast masters, off-repo) and recorded as a residual on the
    sub-suite's closing line, never faked into a green.

29. **The container axis (1.13, `regression.d/44-container-axis.sh`)** — the
    1.12 round shipped "retag fixes the class"; the same day a real 21 GB
    MPEG-2 4:2:2 capture proved otherwise (five MOV retags, identical
    corruption) and the CONTAINER turned out to be the axis. This suite pins
    the mechanism halves that ARE synthesizable: `-tag:v mp4v -f mov` dies at
    header write with the documented tag-table message while `-f mp4` writes
    `mp4v`+`esds` **by default**; `mp4-swap.sh` builds, verifies, and is
    provably lossless (one video packet hash across source → `.mov` → `.mp4`,
    so the A/B really is the same bitstream); the swap's `ipcm` access track
    passes gate (g) instead of being condemned; `--container mp4` scopes the
    "unroutable" refusal correctly (VP9 → MOV still exit 11, VP9 → MP4
    builds); `PR_TAG_ADVICE` now fires on a **.ts source** (D7 — it was dead
    on every TS before, because `STSD_ENTRY` only exists for MP4-family
    containers) while staying silent on the 4:2:0 control and on an
    already-retagged `xd5b` MOV; and every fidelity-FAIL route names the swap
    before Rung 4. SYNTHESIS LIMIT: the corruption itself needs real broadcast
    content — the MOV-destroyed/MP4-correct A/B is operator-verified
    (2026-08-15, SSIM 0.81–0.85 vs 0.9175+) and rides the closing line.
30. **Census + part names (1.13, `regression.d/45-census-partnames.sh`)** —
    D5: `mux_census` is asserted on both arms directly (match, dropped stream,
    right-count-wrong-codec, `?` wildcard, count-only `codecs=na`) and every
    builder is asserted to emit `RMX_CENSUS … match=ok` on a real build, with
    `planned=` cross-checked against the streams actually in the file. D6:
    `rtm_part`/`rtm_sidecar` unit cases (including an extensionless target and
    a dotted directory), a code-level sweep proving no builder still writes
    `$OUT.part` (comments stripped first — these files *document* the shape
    they replaced), and a functional check that the mux-confession hard stop
    leaves `hs.part.mov`, not `hs.mov.part`. On macOS it additionally proves a
    `.part`-named healthy build now PASSES `playable-check.sh` and
    **re-measures C105** on the spot: the same payload through `qlmanage` as a
    `.mov` symlink (no thumbnail, deadline) vs a `.mov` hardlink (renders) —
    which is why the guard hardlinks. SYNTHESIS LIMIT: the silent stream drop
    itself is operator-measured, not reproducible here; what is pinned is that
    the assertion works.
31. **Scan + alignment (1.13, `regression.d/46-scan-align.sh`)** — D1: the new
    `m2v422i.mov` interlaced fixture is proven interlaced, then shown to score
    **below** the 0.90 progressive default through a perfectly healthy
    AVFoundation render (0.867 on the evidence bench) and to PASS anyway on
    the interlaced floor, with `scan=`/`thresh=`/`y=`/`u=`/`v=` on the machine
    line and Y asserted above All (the deficit is chroma, not field
    structure); the progressive control keeps 0.90 and its 1.12 verdict; and
    `RTM_FIDELITY_SSIM_INTERLACED=0.999` proves the interlaced gate can still
    fail, the documented way, with a named plane signature and the container
    swap routed first. Off-macOS all of that is an announced SKIP. D4: the
    dual-track gate is asserted to either take the fast path or to MEASURE
    (start_pts, common window) rather than assert, that the word "misaligned"
    no longer appears on content that matches, and that a genuinely wrong
    access track (half-volume decode) is still caught. D3: an MP2-only build
    now REVIEWs ("no PCM access track") while the dual-track pair does not,
    and the dead-HDMV-track class still FAILs — the allowlist demotion did not
    weaken it.

## Synthesis limit (why some things aren't tested directly)

`libx264` cannot mint true broadcast PAFF (separate field pictures), and the
specific failure — *decodes clean but tears on an off-keyframe scrub* — cannot be
reproduced synthetically: ffmpeg discards pre-seek frames before any decoder/
muxer sees them, so a faked non-monotonic timeline simply does not error on a
seek. The harness therefore validates the surrounding machinery (seekability
sanity, gate execution, hash invariance, detector math) rather than re-creating
the corruption. A **real capture played in a real player** remains the final
arbiter — the skill's standing "playable ≠ valid" rule.

Likewise a **pair-timestamped PAFF capture** (PES timestamps only on the first
field of each pair) cannot be minted — encoders and muxers stamp every packet.
Section 19 pins its mechanisms through the same injection-hook style the other
un-mintable classes use (`PF_PKT_FILE`, `PF_PKT_TICKS_FILE`,
`RTM_MUX_LOG_APPEND`), and the pairfill E2E run uses a fully-timestamped source
(where the fill is a no-op by design) to prove the plumbing and gates.

The **destroyed consumer-decoder render** of real 4:2:2 broadcast masters (the
1.12 fidelity motive) is likewise un-mintable: the synthetic `m2v1` 4:2:2 clip
decodes cleanly through the consumer path (SSIM ~0.95 on the 2026-08-15
bench), so `regression.d/43-fidelity-retag.sh` asserts the synthesizable
mechanism halves (lossless retag, advisory surface, flag surface, healthy
`verdict=ok`, threshold-forced `verdict=fail reason=fidelity`) and records the
destroyed-render half as an operator-verified residual (2026-08-15, two real
1080i59.94 masters), never a fake pass.

The same applies to the **open-GOP seam glitch**: libx264/x265 won't emit true
leading B-frames on synthetic content, so `gop-probe.sh`'s detector is unit-tested
against a crafted frame table (`GOP_PROBE_CSV`) plus a real-media no-false-positive
check, and `seam-check.sh` is tested against a synthesized one-frame flash, a
legitimate hard cut, and a clean join. A real capture + eyeballing the seam frames
remains the decisive test.

## Fixture corpus (make-fixtures.sh)

Three post-mortems happened because a failure class had no fixture. This script
mints every class the v1.11 phases exercise into `tests/fixtures/` (gitignored
at the repo root; media never ships in git) — deterministic, offline, idempotent,
atomic (`.part` → `mv`), ~9 s and ~80 MB for the full set on the reference bench.
Every fixture ends with a self-check of its stated property; a property that does
not hold fails the run naming the fixture (exit 1; unknown selector = exit 2).

```
bash tests/make-fixtures.sh                 # build/refresh everything
bash tests/make-fixtures.sh gap.ts m2v422   # subset: filename or stem
```

| Fixture | What it encodes | WHY (failure class pinned) | Consumed by |
|---|---|---|---|
| `multilang.ts` | H.264 + 3× AC-3: EN stereo, ES stereo, EN 5.1, languages tagged | "grab the first audio stream" is provably wrong here; selection must be language/layout-aware and every DROP must WARN | Phase 3 (audio policy) |
| `mixed.ts` | AAC-eng + AC-3-spa stereo pair | the per-track `auto` split (WO 3.2): one mux where copy AND PCM access are each the right answer for a different track | Phase 3 |
| `dupe_lang.ts` | MP2-eng + AC-3-eng stereo pair | the SAME-key duplicate for layout+language curation (WO 3.5): codec rank must decide (AC-3 lossy-high beats MP2 lossy-low), not track order | Phase 3 |
| `late-sps.ts` | ~20 Mbit/s H.264+MP2 TS, head sliced mid-GOP; first SPS ~8 MB in | mid-GOP joins hide the SPS from ffprobe's default 5 MB window: default probe reports the stream with **no dimensions**, `-probesize 500M` sees 1280x720 — probe code that trusts the first answer mis-routes | Phase 1 (probe layer) |
| `gap.ts` | byte-clean TS, one ~4 s forward PTS/DTS gap at t=10 | the "present + monotonic, the mux will succeed" desync class: only the timeline is dirty (CC/TEI/PES all 0) | Phase 2 (ts-health/diagnose routing) |
| `corrupt.ts` | `gap.ts` recipe + real transport damage (TEI ×6, one PES length clobbered) | scanners must keep timeline dirt (routable) apart from transport damage (permanent); `ts-health.sh` reads corrupt=7, PES=1 deterministically | Phase 2 |
| `rot.ts` | mpegts/mpeg2video with a forward gap AND a backward DTS step | the backhaul timeline-rot class — the WO 4.2 demoted gate: warn + build + verify judges, never a pre-build exit 11 | Phase 4 (rot demotion) |
| `m2v422.mov` / `m2v422.ts` | mpeg2video yuv422p (TS variant + MP2) | the 4:2:2 contribution family — refused 1.8.0–1.10.0, demoted 1.11 (WO 4.1) to advisory + post-build playability proof; since 1.13 also the container-axis A/B (`.mov` `m2v1`+glbl vs `.mp4` `mp4v`+esds) | Phase 4 (gates), Phase 2 (banners), 1.13 D2/D7 |
| `m2v422i.mov` | mpeg2video yuv422p **interlaced** (field_order tb; `interlace`+`+ilme+ildct`) | the scan-keyed-threshold fixture (1.13 D1): a perfectly healthy interlaced 4:2:2 render scores ~0.867 — **below** the progressive-tuned 0.90 default — so without this clip the false-FAIL half of D1 is unpinnable | 1.13 D1 (`46-scan-align.sh`) |
| `h264_422.ts` / `h264_422_10.ts` | H.264 High 4:2:2 8-bit / 10-bit + MP2 | the 2017-feed class, plus the 10-bit AVC-Intra shape the old exact 8-bit gate missed — both now announced + proven post-build | Phase 4 |
| `hevc_422_10.mov` | HEVC Rext yuv422p10le tagged `hvc1` | Rext 4:2:2 with correct signaling — the tag alone doesn't decide decodability; the post-build check does | Phase 4 |
| `m2v420.ts` | mpeg2video yuv420p + MP2 | verified-good 4:2:0 control: must KEEP passing every gate | Phases 2/4 (no-false-positive) |
| `aac.ts` | H.264 + ADTS AAC | working control: ffmpeg auto-inserts `aac_adtstoasc` on TS→MOV; pinned so nobody "fixes" it | Phase 5 |
| `mp4v.mov`, `mjpeg.mov`, `dv.mov`, `prores.mov` | mpeg4/`mp4v`, MJPEG 4:2:0, DV PAL 720x576@25, ProRes `apcn` | the native-QuickTime matrix (already-fine inputs must stay fine and be described honestly) | Phase 5 (coverage/messaging) |
| `pcm_bluray.m2ts` | H.264 + Blu-ray LPCM in BDAV `.m2ts` | the class entry 1 validated only against an operator-held 18.5 GB real source — now mintable at fixture size | Phase 3 (PCM handling) |
| `vp9.webm` | VP9 in WebM | the un-muxable-into-MOV class (WO 5.2): `mov.sh` must refuse with routes (`MOV_REFUSED profile=unroutable-vcodec`), never a raw muxer error | Phase 5 (unroutable codecs) |

**Construction notes (deviations from the naive recipes, and why):**

- `gap.ts` is one encode with a `setpts`/`asetpts` +4 s jump — **not** a dd
  middle-carve or a two-segment concat. Carving TS packets out breaks
  continuity counters (1/16 odds per PID of lining back up) and usually tears
  a PES packet; independently muxed segments restart CC at the byte-concat
  join. The single-encode jump is the only construction whose *only* defect is
  the forward gap, which is exactly the class being pinned.
- `corrupt.ts` damage is surgical, not random scribbling: the TEI bit
  (`byte1|0x80`) on six evenly spaced mid-file video payload packets, plus one
  audio PES packet-length field clobbered. Blind garbage writes would hit sync
  bytes/PAT/PMT and make the counters nondeterministic — and video PES can't
  produce a size mismatch at all (ffmpeg writes video PES with length 0 =
  unbounded), which is why the audio stream takes the PES hit.
- `late-sps.ts` cuts **8 MiB before the surviving IDR**, not "just after the
  first IDR": the slice must beat the default 5 MB `probesize` (default probe
  stays dimension-blind) while staying inside the default 5 s
  `analyzeduration` (~3 s of ~20 Mbit/s stream), so that `-probesize 500M`
  *alone* recovers the dimensions — the exact acceptance property. The cut
  rides the TS muxer's own 188-aligned PES starts, so `dd bs=188` keeps
  packetization valid.
- The 4:2:2 TS fixtures carry MP2 audio (the real backhaul shape);
  `m2v422.mov` is video-only.
- `pcm_bluray.m2ts` needs `-mpegts_m2ts_mode 1`: LPCM's 0x80 stream type only
  exists in the BDAV mapping. On an ffmpeg build that cannot mux it, the
  script prints `SKIP` with the provenance note instead of failing the corpus.

**Bench facts (self-dated, the `playable-check.sh` rule: verdicts are a
property of the macOS they ran on).** The corpus is **twenty** fixtures
(`make-fixtures.sh` with no args builds all; see `ALL` in the script for the
authoritative list). Originally measured 2026-08-13 on macOS 26.6.1 /
ffmpeg 8.1.2 (homebrew ffmpeg-full) and re-validated after the bench moved to
ffmpeg 9.0.1 on 2026-08-14 (ffmpeg 9 removed `-vsync`; the scripts use
`-fps_mode`): the full set builds and self-checks in seconds; `mp4v.mov`,
`mjpeg.mov`, `dv.mov`, `prores.mov` all measure playable via
`scripts/playable-check.sh`. Recipes are deterministic (fixed lavfi sources,
fixed `noise` seed); encoder threading may flip bits run-to-run, but every
stated property is invariant.

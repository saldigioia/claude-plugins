# Environment Knobs & Test Hooks

The complete inventory of environment variables the scripts honor (the orphaned
1.14 Phase-6 item, shipped 1.15.0 Phase 0; greped from the scripts on this
bench 2026-08-26 — defaults are quoted from the code, not from memory). Two
tables: **operator knobs** (tunables a human might legitimately set) and **test
hooks** (injection points for the regression suite — never set these on real
jobs). Machine-line *output* fields (`PF_*`, `TSH_*`, `DISC_*`, `RMX_*`, …) are
documented in SKILL.md's machine-lines table, not here.

## Operator knobs

| Knob | Default | Honored by | What it does |
|---|---|---|---|
| `RTM_PROBESIZE` | `200M` | every input open (`lib-probe.sh`) | ffprobe/ffmpeg `-probesize` ceiling (SI suffixes). The stock 5 MB window is dimension-blind on real broadcast TS (WO 1.2). |
| `RTM_ANALYZEDURATION` | `200M` (µs) | every input open (`lib-probe.sh`) | `-analyzeduration` ceiling, same rationale. |
| `RTM_IDR_WINDOW` | `5000` | `trim-to-idr.sh` | Video packets scanned for the first keyframe before declaring none in reach. |
| `RTM_FIDELITY_SSIM` | `0.90` | `playable-check.sh --fidelity` | Progressive fidelity floor (SSIM vs the ffmpeg reference decode). |
| `RTM_FIDELITY_SSIM_INTERLACED` | `0.86` | `playable-check.sh --fidelity` | Interlaced fidelity floor (0.90 false-FAILs healthy interlaced material — measured 2026-08-15; the deficit is chroma-plane). |
| `RTM_QL_TIMEOUT` | `60` (s) | `playable-check.sh` | qlmanage render deadline; a hang counts as no frame = FAIL (WO 1.4). |
| `RTM_AVC_TIMEOUT` | `120` (s) | `playable-check.sh --fidelity` | Per-window avconvert deadline; a hang is a fidelity verdict. |
| `RTM_SYNC_TOL` | `0.25` (s) | `verify.sh` gate (f) | Base A/V duration-parity tolerance, widened only by the source's *measured* gap seconds. |
| `RTM_SOURCE_GAP_BUDGET` | unset | `verify.sh` gate (f) | Caller-supplied gap budget (seconds) when SOURCE is an intermediate whose own scan can't stand in for the original (WO 2.4). |
| `RTM_SIL_MIN` | `5` (s) | `verify.sh --silence` | Minimum window length counted as silence. |
| `RTM_SIL_DB` | `-50dB` | `verify.sh --silence` | Silence threshold. |
| `RTM_SIL_TOL` | `2.0` (s) | `verify.sh --silence` | Allowed output-silence excess beyond source total + measured gap-fill budget. |
| `RTM_CHAPTER_TS_WARN_SECS` | `2900` | `mov.sh`, `resync.sh` | Chaptered movie-timescale overflow pre-announce onset (true onset 2^31/movie_timescale; lower it for finer movie timescales). |
| `RTM_CHAPTER_TS_DROP_SECS` | `5965` | `mov.sh`, `resync.sh` | Chapter-track silent-drop risk announce (conservative superset of the measured geometry gate). |
| `RTM_FORCE_BACKHAUL` | `0` | `mov.sh --force-backhaul`, `backhaul_gate` children | Operator has decided: short-circuits the whole shared backhaul gate (advisory included at child entry points — P1c). Human decision, never set by a session on its own. |
| `RTM_PRECOND_ATTEST` | unset | `lib-attest.sh` consumers (`derive-dts.sh`, `pairfill-paff.sh`) | Verbatim operator attestation string overriding ONE named precondition; writes a `.precond-waiver.txt` sidecar. Every output gate still runs. |
| `TSH_LOSS_FAIL` | `100` | `ts-health.sh`, `diagnose.sh` | Transport-error count where "proceed with eyes open" becomes "re-capture" — deliberately one knob so the two scanners cannot disagree. |
| `DISC_MULT` | `1.5` | `ts-health.sh`, `disc_scan` (`lib-paff.sh`) | Forward-gap threshold in frame durations. |

Added in 1.15.0 (source clinic):

| Knob | Default | Honored by | What it does |
|---|---|---|---|
| `RTM_SRCV_DUR_TOL` | `1.5` (s) | `verify-source.sh` | Duration-arithmetic tolerance (source − trim vs output). |
| `RTM_LEAD_WINDOW` | `8` (s) | `lead-check.sh` | Head window swept for the black-lead signature. |
| `RTM_LEAD_LUMA_BLACK` | `48` | `lead-check.sh` | Mean-luma ceiling under which a frame counts as black/near-black (the measured case ran 16–42 against program at ~150). |
| `RTM_CLOCK_WINDOW` | `3` (s) | `clock.sh` | Half-width of the decode window around the translated address. |

## Test hooks (suite injection — never on real jobs)

| Hook | Honored by | Injects |
|---|---|---|
| `TSH_PKT_FILE` | `ts-health.sh` | CSV packet table (idx,pts,dts,duration,flags in integer ticks) bypassing the packet probe; video stream index forced to 0. |
| `TSH_FDUR_TICKS` | `ts-health.sh` | Frame duration in ticks (pairs with `TSH_PKT_FILE`). |
| `TSH_LOG_FILE` | `ts-health.sh` | Lines appended to the transport-pass log. |
| `PF_PKT_TICKS_FILE` / `PF_PKT_FILE` / `PF_TRACE_FILE` / `PF_PPF_IN` / `PF_DECL_DEPTH_IN` / `PF_DTS_SOURCE_IN` | `lib-paff.sh` scanners | Synthetic timestamp shapes / trace_headers output / pre-measured sub-results into `pf_detect` / `pf_reorder_scan`. |
| `DISC_DTS_FILE` / `DISC_FRAMEDUR_IN` | `disc_scan` | Synthetic DTS column / frame duration. |
| `PP_SCAN_FILE` | `pairfill-paff.sh` | Synthetic pair-scan input. |
| `PF_HEAD_TRACE_FILE` | `pairfill-paff.sh` | Canned HEAD trace_headers log into the junction POC-capability pre-flight (`pf_poc_capability`, WO-1.15.3) — drives the pic_order_cnt_type refusal hermetically. When only `PF_TRACE_FILE` is set, the head probe stays skipped (the canned census carries no head log to judge). |
| `RTM_MUX_LOG_APPEND` | `remux.sh` | Lines appended to the mux log (confession-class tests). |
| `RTM_LAYOUTS_FILE` | `resync.sh` | "channels,layout" lines bypassing the frame-level layout probe. |
| `RTM_FORCE_NO_VCL` | `verify.sh` | Forces the degraded (no filter_units) essence path. |
| `RTM_TEST` | `mov.sh` | Sourced-classifier harness guard (suite sources mov.sh's classifiers without running it). |
| `RTM_BACKHAUL_GATED` | `backhaul_gate` (`lib-paff.sh`) | Caller already ran the gate — children skip the re-check. Set by drivers, not humans. |
| `PF_SCAN_WINDOW` | `lib-paff.sh` | The one named window constant for both windowed advisory scans (P1.1; default 5000). |
| `PF_SPS_NOISE_MAX`, `PF_PPF_WINDOW` | `lib-paff.sh` | SPS-parse noise ceiling / PPF probe window bounds. |

## Cost models (measured, so nobody re-pays to rediscover them)

**The junction POC-lattice gate (WO-1.15.3, field-recorded on the 23.68 GB
2022-VMA artifact):** the gate's pre-1.15.3 direct-output arm paid a
whole-file `trace_headers` parse of the OUTPUT — ~20 minutes of its 26m16s,
roughly a third of the total ladder runtime — while `pf_trace_census` had
already paid an identical whole-file pass over the same coded pictures on the
SOURCE. Since WO-1.15.3 the census emits the per-picture `idr,poc` table and
the SPS `log2_max` value as side files from that same pass (zero extra
reads), and the gate reuses them: the output then pays only its ffprobe PTS
list (I/O-bound, ~minutes on 24 GB). License: copy-by-construction within the
same run (pairfill's video is unconditionally `-c copy`; tables measured
byte-identical across ts → copy → mov, pinned by test 78). The
direct-extraction arm keeps the old cost and says so when it runs — it
remains the fallback (census without a POC table) and the standalone default
(`scripts/poc-gate.sh`, which has no census in scope). The capability
pre-flight (`pf_poc_capability`) is the other half of the same economy: a
40-frame head probe (seconds) refuses the `pic_order_cnt_type != 0` class
that pre-1.15.3 cost the entire build (~55 min mux + the 26-minute parse) to
reach a foregone UNPROVEN.

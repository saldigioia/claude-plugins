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
| `RTM_FASTSTART` | `1` | every `.mov`-writing route (`lib-mux.sh` `rtm_movflags`; `lib_faststart.py` for the PyAV rungs) | `0` writes `moov` LAST instead of relocating it to the front. Faststart is the default everywhere since 1.16.7 — archival masters included, per Apple's recommended creation order — and the opt-out is MANUAL and ANNOUNCED (`RTM_FASTSTART state=on\|off route=…`); nothing turns it off on the file's behalf. What you buy back is wall time: the relocation is a second full-file pass (~2x write I/O). What you do NOT save is disk — the pass is in-place, peak 1.000x the output (measured 2026-08-29), so the pre-flight budget is the same either way. Routes also accept `--no-faststart`. |
| `RTM_OVERWRITE` | `0` | every writer (`lib-mux.sh` `rtm_claim_out`) | `1` authorizes replacing an OUT that already exists — announced, never silent. The lock stops two builds racing; it does not stop today's build from quietly replacing yesterday's verified deliverable (T1.10). |
| `RTM_OWN_SCRATCH` | unset | every writer (`lib-mux.sh` `rtm_sibling_guard`) | Colon-separated canonical paths THIS RUN created and then handed on as an input. The derived-name arms of the sibling guard skip them — `mov.sh`'s IDR-trim intermediate matches its own scratch shape by construction. NOT an operator knob: a caller declares what it made, and `IN == OUT` is refused regardless. |
| `RTM_STRUCT_MAX_BYTES` | `4294967296` | `verify.sh` gates (h)/(k) | Output size above which the whole-file header parse those two gates share is DECLINED on budget. Since 1.18.0 a declined **copy-class** artifact settles by identity instead (payload bit-identical + equal packet counts + PTS column equal to the source, demux-only) and both gates PASS as identity-proven; only when the settle does not apply (authored timing — the repair rungs, genpts — or an unreadable column) do the gates report UNPROVEN → REVIEW, with the settle commands named cheapest-first (`poc-gate.sh` for (k) alone, `--full` for both). A budget-only REVIEW is reportable as done — settle on the operator's ask (FAST PATH). `--full` runs the parse regardless; `0` disables the budget. |
| `RTM_RATE_DEV_MAX` | `1.10` | `verify.sh` gate (h) | Ratio band between the declared `avg_frame_rate` and samples ÷ duration. The defect it catches is a 2× error (one sample per FIELD); container rounding and capture jitter live within a few percent, so 1.10 is the empty middle. |
| `PL_TOL` | `1` (tick) | `pf_poc_lattice` (`verify.sh` gate (k), `poc-gate.sh`) | Rounding tolerance when checking a picture against its POC lattice slot. A 30000/1001 stream in a 15360 timescale has a 512.512-tick frame, so the muxer rounds every value and an exact-integer test reports every picture off-slot. |
| `RTM_BATTERY_SECONDS` | `60` (s) | `attempt-battery.sh` | Head-slice length for the nine remux variants, so "does the mux fail?" costs seconds on a 25 GB source. `--whole-file` runs the real thing. |
| `RTM_BATTERY_KEEP` | `0` | `attempt-battery.sh` | `1` keeps the variants' artifacts instead of discarding them. |
| `RTM_SIL_DB` | `-50dB` | `verify.sh --silence` | Silence threshold. |
| `RTM_SIL_TOL` | `2.0` (s) | `verify.sh --silence` | Allowed output-silence excess beyond source total + measured gap-fill budget. |
| `RTM_CHAPTER_TS_WARN_SECS` | `2900` | `mov.sh`, `resync.sh` | Chaptered movie-timescale overflow pre-announce onset (true onset 2^31/movie_timescale; lower it for finer movie timescales). |
| `RTM_CHAPTER_TS_DROP_SECS` | `5965` | `mov.sh`, `resync.sh` | Chapter-track silent-drop risk announce (conservative superset of the measured geometry gate). |
| `RTM_FORCE_BACKHAUL` | `0` | `mov.sh --force-backhaul`, `backhaul_gate` children | Operator has decided: short-circuits the whole shared backhaul gate (advisory included at child entry points — P1c). Human decision, never set by a session on its own. |
| `RTM_POC_MIN_AGREE` | `0.999` | `h264poc.py` `resolve_min_agree` (the one writer); read by `poc-remux.py` and `derive-dts.py` | Class-unanimity bar for `k = POC + C`. **Since 1.17.0 this bar announces rather than refuses** (TIERS.md T3.4, Constitution I.3): unanimity is capped at 1 − f on a systematic mis-stamp, so a stream with 17.4 % of its pictures stamped one frame late tops out at 0.826 and can never reach 0.999 however exactly the bitstream states its own display positions — it refused precisely the class Rung 3-POC exists to repair. When no class clears it and every class carries its ≥100 votes, the modal C proceeds as PROVISIONAL with a warning naming the shortfall, and the **output** gates judge: the bijection onto the display lattice, the DTS asserts, and the full `verify.sh` suite. Setting this is only about how loud the warning is — it cannot make a bad artifact ship. A value that will not parse, or sits outside (0, 1], falls back to the default and says so. **There is deliberately no knob for the ≥100-vote sample floor**: unanimity is capped by the defect, evidence volume is not. |
| `RTM_SPARSE_NOPTS_MAX` | `0.01` | `derive-dts.py` (decides), `lib-paff.sh` `pf_sparse_nopts` (routes) | Largest fraction of unstamped video packets the Rung 3-DERIVE **sparse pre-pass** will consider reconstructing from pair-mates (1.15.20). A cut in the empty band between the two timeline rungs — 35x below pairfill's 0.35 pair-signature floor. Both halves must agree; test 99 §4 pins that. Raising it does NOT admit more files to a fill: every individual reconstruction is decided by whole-file evidence, and the whole file is refused if any hole lacks a timestamped mate. |
| `PF_PTS_COMPLETE_MAX` | `0` | `lib-paff.sh` `pf_pts_complete` | "PTS-complete" for the derive signature. **Structural, not a tolerance** — the derivation indexes the sorted PTS column and an unstamped packet has no position in it. Raising it only routes a file to a rung that must refuse it; the sparse class has its own bound above. |
| `PF_HALF_TS_LO` / `PF_HALF_TS_HI` | `0.35` / `0.65` | `lib-paff.sh` `pf_half_ts_frac` (`pf_detect`, `derive-dts.sh`) | The band that reads as pairfill's pair signature (~half the packets untimestamped). One writer since 1.15.20 — `derive-dts.sh` used to read an unset `PF_HALF_TS` and print `half_ts=no` whether or not anything had measured it. |
| `RTM_PRECOND_ATTEST` | unset | `lib-attest.sh` consumers (`derive-dts.sh`, `pairfill-paff.sh`) | Verbatim operator attestation string overriding ONE named precondition; writes a `.precond-waiver.txt` sidecar. Every output gate still runs. |
| `RTM_DISK_CHECK` | `1` | every builder's writer pre-flight (`rtm_disk_preflight`, `lib-mux.sh` — WO-1.15.6 F11; converted 1.17.2) | Free-disk pre-flight (free bytes on OUT's/staging volume vs source size). `1` (default): low space **warns + builds** (`RTM_DISK verdict=warn`; the ENOSPC cost and the macOS/APFS purgeable-space meter caveat named) — the pre-1.17.2 refusal had turned df's conservative reading into a hard size ceiling (TIERS.md, classification row (d)). `strict`: the old refusal (exit 2 pre-flight, nothing written) — for unattended batches where filling the volume is worse than skipping the file. `0` skips ANNOUNCED — the genuinely-smaller-output classes (cuts/trims) on a nearly-full disk. A resource heuristic, not an evidence gate — every output gate still judges the build. |
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
| `RTM_DISK_FREE_KB` | `rtm_free_bytes` (`lib-mux.sh`, WO-1.15.6) | Injected free-space reading in kilobytes (bypasses `df`); a non-numeric value simulates a broken meter (which must announce and proceed, never refuse). |
| `RTM_LOCK_HELD` | `rtm_lock` (`lib-mux.sh`, WO-1.15.6) | Set by the LOCK ITSELF when a driver acquires (exported lockdir path) so child builders on the same OUT re-enter instead of deadlocking. Driver-set, like `RTM_BACKHAUL_GATED` — never set by humans. |

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

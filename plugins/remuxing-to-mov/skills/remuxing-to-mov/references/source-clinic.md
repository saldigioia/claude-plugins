# The Source Clinic — checks and corrections in the source's own container

The storey BELOW the remux ladder (added 1.15.0; origin: the feed.ts case
file, a 26.8 GB 2019-VMA satellite backhaul cleaned by hand on 2026-08-26 and
then automated here). The ladder answers "how do I get this capture INTO a
QuickTime-ready .mov"; the clinic answers "is the capture itself right, and
can it be corrected WITHOUT remuxing" — the deliverable is a sibling in the
source's own container (`.ts` today; the recipes are measured on mpegts).

## Doctrine

**Re-wrap ≠ remux.** A *re-wrap* is a same-container-family rewrite whose
essence is byte-identical and whose structure is preserved — mpegts PID and
program layout ride through (`-streamid`, `-mpegts_pmt_start_pid`,
`-mpegts_service_id`). A *remux* changes container family and is the
ladder's business. The clinic never crosses a container boundary, never
re-encodes, and never touches the source — the output is always a new
sibling; the original remains the master.

The pair-timestamped PAFF shape is the measured exception (1.15.2 Item C):
the 2026-08-26 case file recorded a TS→TS plain copy preserving it
(untimestamped mates in → timestamp-less PES out), but on the 2022-08-28
field source the same copy made the mpegts muxer confess `Timestamps are
unset` — the invented-timing hard-stop class — after building all 23.68 GB,
and the run was correctly refused. That claim is therefore scoped to the case
file's bench and shape, not doctrine; since 1.15.2 `zero-base.sh` refuses
pair-timestamped PAFF at pre-flight (nothing built, `pairfill-paff.sh` named
as the route), because the only prize on such a source is a `start_time`
cosmetic every player rebases away.

**The two-tier consent model.**
- **Tier 1 — structural**: corrections that discard nothing any player could
  ever present. `zero-base.sh` (timeline rebase), `trim-to-idr.sh`
  (undecodable pre-roll). Drivers may run these announced.
- **Tier 2 — content-discarding**: any cut that removes DECODABLE media —
  the black-lead cut discards real black video and, typically, hot program
  audio under it. `surgical-cut.sh` refuses without the operator's explicit
  `--discard-content` and prints the exact loss statement first. Precedent:
  trim-to-idr's open-GOP refusal ("that trade is the operator's") — the same
  line, drawn at content instead of at re-encoding.

**The prediction contract.** A true-dry-run pre-pass — the build's own mpegts
mux with identical options and the bytes discarded — predicts exactly what
the real mux will hit (CLI-filled mate DTS colliding as equals and taking a
+1-tick nudge; presentation timestamps untouched). Clinic builders announce
the expected artifact set BEFORE building and FAIL if the mux log observes
anything else — nothing unexplained ships, enforced, not aspired to.
HISTORY (1.15.2 Defect B): through 1.15.1 the pre-pass was `-f null` +
`-copyts` without the build's muxdelay/layout options — a different mux than
the one that ran. The case file's 9-predicted/9-observed agreement was a
coincidence of that source; the 2022-08-28 field source measured 0 predicted
against 11 observed, i.e. the old pre-pass had no predictive value there. The
pre-pass now mirrors the build by construction (`rewrap_predict`,
lib-rewrap.sh; pinned by test 74), so predicted == observed is a property of
the command, and any breach that remains is a real surprise in the source.

**The player-clock rule.** Users report PLAYER-clock time; ffprobe reports
CONTAINER time; they differ by `format.start_time`. Every "starts at X" /
"the glitch is at X" diagnosis converts first (`clock.sh` — in the case file
this one conversion turned a vague complaint into an exact packet address:
player 1.360 = container 1.560 on a 0.200 start).

**The zero-base floor.** The video track cannot start below its first frame's
reorder delay (MPEG-TS holds no negative DTS), and `format.start_time` lands
at the earliest stream start — never 0.000000 while B-frames are in flight.
`zero-base.sh` computes and states the floor BEFORE building; making ffprobe
print zero would require inventing DTS, refused on doctrine.

**The deterministic cut.** Both `-ss` forms are measured-unreliable for
frame-targeted cuts on TS (output-side waits for a keyframe by its own rules
and skipped past the target GOP; input-side binary-searches an index-less
container and overshot the same way). The sanctioned recipe is census →
packet-index/PTS `noise=drop=` selection → `-copyts` + `-output_ts_offset`
→ filtered-reference verification. Video selects by INDEX because PAFF mates
carry no timestamps (any pts-expression breaks on half the packets); index
stability requires the no-seek whole-file pass — constraint as feature.

**The leading-B rule.** At an open-GOP cut, leading B-pictures are
decoder-discarded (no visible glitch) but their PTS precede the target
keyframe and poison `format.start_time` (picture would report 0.12 instead
of 0.00 in the case). Drop them — and their untimestamped PAFF mates — by
index (`--video-drop-between`). The DTS-only hole they leave is the one
explained gap (`--expect-gaps-delta 1` in the battery).

**The verification battery** (`verify-source.sh`) is what makes any of this
trustworthy, and it closes a documented hole: verify.sh is QTFF-shaped by
design (gate (d) FAILs legitimate matroska outputs — known-limits.md), and
ts-health proves *health*, not *identity*. The battery proves identity:
(a) filtered-reference streamhash — the output vs the source demuxed through
the IDENTICAL bsf filters, so a cut is verified as rigorously as a straight
copy; (b) census arithmetic with the expectation MEASURED from the filtered
source (framecrc pass), never trusted; (c) head/duration arithmetic;
(d) nothing-unexplained — every defect counter inherited or an announced
consequence of the plan.

## The tools

| Tool | Job | Tier |
|---|---|---|
| `clean.sh IN [--deep]` | the driver: probe → ts-health → lead-check (→ dim-scan + full decode with `--deep`), findings with exact commands, report-only | — |
| `clock.sh IN PLAYER_TIME` | player-clock → container-address translation + luma context | report |
| `lead-check.sh IN` | black-lead detection: luma sweep + keyframe census + gop-probe boundary class + audio level; emits the cut address | report |
| `dim-scan.sh IN` | whole-file frame-dimension sweep (the mid-stream SPS-change detector) | report |
| `zero-base.sh IN OUT.ts` | timeline rebase to the floor, layout preserved, prediction-gated | 1 |
| `trim-to-idr.sh IN OUT.ts` | mid-GOP-start pre-roll trim (pre-dates the clinic; same family) | 1 |
| `surgical-cut.sh IN OUT.ts …` | the deterministic non-IDR cut; refuses without `--discard-content` | 2 |
| `verify-source.sh SRC OUT …` | the identity battery for same-container outputs | gate |

Machine lines (all additive API): `CLEAN_SUMMARY`, `CLOCK_SUMMARY`,
`LEADCHECK_SUMMARY`, `DIMSCAN_SUMMARY`, `ZB_SUMMARY`, `SCUT_SUMMARY`,
`SRCV_SUMMARY`; `RMX_CENSUS` gained the stage values `zero-base` and
`surgical-cut`. Knobs: `references/knobs.md` (RTM_SRCV_DUR_TOL,
RTM_LEAD_WINDOW, RTM_LEAD_LUMA_BLACK, RTM_CLOCK_WINDOW).

## Downstream contract

A clinic output is a **new master candidate**: run the remux ladder on IT,
and verify any downstream `.mov` against IT, not the original (the
trim-to-idr rule, generalized). The untouched original retains everything a
Tier-2 cut discarded.

## Scope, stated

- The recipes are **measured on mpegts**. Matroska gets the checks (ts-health
  pass 2, verify-source, dim-scan are container-agnostic) but no corrections:
  MKV timelines start at zero by construction, and the MKV timeline-repair
  lane is derive-dts (which writes `.mov` today — the same-container
  `--container mkv` variant is a recorded candidate below).
- Timeline defects (missing timestamps, DTS rot) are NOT clinic business —
  `clean.sh` routes them to `diagnose.sh` and the repair rungs, and
  `zero-base.sh` refuses rotten sources outright rather than letting the
  muxer rewrite the rot silently.
- Transport loss stays permanent and stays reported, never "repaired".

## Recorded candidates (named, not built — 1.15.0)

- **`wrap-split.sh`**: the ≥2-wrap 33-bit-PTS limitation says "split below
  the horizon first" with no tool — the same diagnose→apply gap trim-to-idr
  once closed for mid-GOP starts.
- **`derive-dts.sh --container mkv`**: the same-container lane for the
  2023-VMA class (reordered field-coded H.264 in a DTS-less container).
- **Bars-and-tone lead detection**: lead-check's luma sweep sees black only;
  SMPTE bars + 1 kHz tone at the head are the same editorial class with a
  different signature.
- **`clean.sh --apply-tier1`**: the driver currently prints Tier-1 commands
  rather than running them; an apply mode is a candidate once the clinic has
  field mileage.
- **PAFF-mate-aware index ranges in lead-check**: untimestamped mates inside
  a leading-B range currently ride on the operator's review (announced), not
  on automatic inclusion.

# Tier ledger — every refusal in the tree, classified

**Rule this document exists to enforce:** *gate the assertion, not the attempt.*
Refusing to **do** something and refusing to **claim success without proof**
both come out of the mouth as "no". They are different things, and only the
second one has ever caught a broken file here.

Written 2026-08-29 (1.16.0), from the 2026-08-28 feed.ts post-mortem: the
plugin refused to attempt `ffmpeg -c copy` on a 25 GB capture — every one of
nine plain remux variants returns rc=0 and writes every packet — while two
builds that were unusable (one MOV sample per coded **field**; a `.mp3` sample
entry over MPEG-1 Layer II payload) passed every check the plugin had, because
those checks are essence hashes and both builds were bit-identical to the
source. Nothing quiet was caught; something safe was stopped.

This file is the classification, and it is **mechanically enforced**: every
site that refuses carries a `# TIER n` comment naming its row here, and
`tests/regression.d/94-rot-sweep.sh` §11 fails the bench on a refusal site
that carries none. A classification you can forget to apply is not one.

---

## The three tiers

**Tier 1 — ABSOLUTE.** Irreversible or destructive acts, attended or not.
These block no legitimate attempt, so they cost nothing. Harden anything soft.

**Tier 2 — VERIFY THE OUTPUT, COMPREHENSIVELY.** Where the anti-hallucination
effort belongs. Includes what the container **declares**, not only what it
stores. A gate here judges an artifact that exists, using measurements taken
from it. It may withhold blessing; it never prevents building.

**Tier 3 — DO NOT GATE THE ATTEMPT.** Predictions about the input are not
evidence. A pre-flight refusal is legal only when it is a **cached attempt**:
the tool's own deterministic refusal, measured and re-verifiable (the MOV
muxer has no VC-1 sample entry — attempting reproduces the identical error
with a worse message). A prediction about output *quality* is never a cached
attempt and never blocks a build.

### The classification test

*If this gate is deleted and the pipeline runs, is the damage:*

| | Answer | Tier |
|---|---|---|
| (a) | irreversible before anyone can look | **1** |
| (b) | a bad artifact the verify suite must catch | **2** |
| (c) | nothing — the tool itself refuses deterministically | **3, cached-attempt exception** |
| (d) | a wasted build that verify then fails honestly | **3 — delete the gate** |

Answer (d) is the acceptable cost of never being wrong about (a)–(c).

### The rule scopes diagnosis too (1.17.1)

Front-loading a diagnostic battery on a file no measurement has accused is the
attempt-gating error in a lab coat: it spends the effort Tier 2 owns on a
prediction Tier 3 forbids. The trigger rule lives in SKILL.md's FAST PATH —
`clean.sh` / `ts-health.sh` / `diagnose.sh` / `attempt-battery.sh` /
`verify.sh --full` run only on an operator-reported symptom, a measurement's
own finding (probe advisory, mux confession, verify verdict, a child's
refusal), or an explicit request. On a clean probe the attempt IS the
diagnostic: streamcopy's documented failure mode is loud (ffmpeg.html §3.1),
the mux-confession stop catches invented timing, and the verify gates judge
the artifact. Test: `tests/regression.d/119-fast-path-doctrine.sh` pins this
paragraph and the FAST PATH preamble.

---

## Tier 1 — absolute

| # | Gate | Where | State |
|---|---|---|---|
| T1.1 | Video is never re-encoded; Rung 4 only via verbatim operator attestation + mdta provenance | Constitution I.1, `rung4.sh:58`, `lib-attest.sh` | KEEP |
| T1.2 | Source never modified/renamed/deleted; the clinic is report-only | Constitution I.2, every writer | KEEP |
| T1.3 | Refuse to remux a file onto itself | `remux.sh:94`, `auto.sh:66`, `mov.sh`, `zero-base.sh` | KEEP |
| T1.4 | Atomic `.part` staging, real extension kept, temps never auto-deleted, artifacts kept on failure | `lib-mux.sh` (`rtm_part`) | KEEP |
| T1.5 | One writer per OUT | `lib-mux.sh` (`rtm_lock`) | KEEP |
| T1.6 | Disk pre-flight — a resource check, not a content prediction | `lib-mux.sh` (`rtm_disk_preflight`) | KEEP |
| T1.7 | Content-discarding cuts require the operator's own `--discard-content`; never supplied by the session | `surgical-cut.sh:128`, `lead-check.sh` (emits the command, never runs it) | KEEP |
| T1.8 | Unwaivable FAIL on a shipped dead audio track | `verify.sh` gate (g) | KEEP |
| T1.9 | `trim-to-idr.sh` open-GOP refusal — the trade is the operator's | `trim-to-idr.sh:93` | KEEP (consent gate) |
| T1.10 | **Final-OUT no-clobber** | `lib-mux.sh` (`rtm_bless`) | **HARDENED 1.16.0** — the lock protects against *concurrent* writers only; a sequential run silently replaced an existing verified deliverable. `rtm_bless` refuses when OUT exists and differs, unless `--overwrite` (announced). Test 103. |
| T1.11 | **Sibling-writes-only** | every writer | **HARDENED 1.16.0** — mechanical sweep (94 §12): no writer's OUT/part/sidecar path can resolve onto the source's own name. Test 94 §12. |

Tier 1 rows are mutation-tested: `tests/mutation-audit.sh`.

---

## Tier 2 — output verification

A Tier-2 gate judges an artifact that exists. It may withhold blessing; it
never prevents building. **Strictly more of these is the point of 1.16.0.**

### Standing (all KEEP)

`verify.sh` (a) streamhash identity · (b) VCL-payload essence hash ·
(c) decode spot-checks · (d) output timeline (N/A stamps, DTS monotone,
duration histogram) · (e) scrub gate · (f) A/V duration parity (source-aware) ·
(g) audio playability. Plus `verify-source.sh`, `playable-check.sh --fidelity`,
`seam-check.sh`, `poc-gate.sh`, the `RMX_CENSUS` plan-vs-file reconciliation,
and the `zero-base`/`surgical-cut` prediction contracts (predicted ≠ observed
never ships).

The **mux-confession hard stop** (`RTM_CONFESSION_RE`: `pts has no value` and
its siblings) is *compliant* with this doctrine and stays: the run happened,
and the muxer's log is a measurement of it. Its report says "built, kept as
`.part`, timeline unproven — gates X/Y pending", never a bare job-FAIL.

### The 2026-08-28 lesson

The essence hash stays. It is necessary. It is **nowhere near sufficient**:
both broken builds hashed bit-identical to the source, because the defect was
in what the container *declared*.

### Added in 1.16.0

| Gate | Measures | Catches |
|---|---|---|
| **(h)** declared-vs-stored structure | MOV sample count vs the whole-file coded-picture census with fields paired per ISO/IEC 14496-15 (both fields of a complementary pair = ONE sample); declared frame rate vs samples ÷ duration | the field-per-sample build: 433k samples / ~50 fps declared over 216,631 frames / ~25 fps decoded — bit-perfect, stutters everywhere |
| **(i)** codec-tag-vs-payload identity | audio: MPEG frame-header version/layer bits vs the stsd sample entry; video: stsd fourcc vs the bitstream's actual codec | the `.mp3`-entry-over-Layer-II build — gate (g) passes it: `.mp3` is allowlisted and ffmpeg's `mp3float` decoder decodes Layer II happily, so the decode probe is blind to the mislabel |
| **(j)** whole-file duplicate-PTS census + DTS ≤ PTS, in the OUTPUT | extends (d), which checked N/A + monotone DTS + durations but never PTS uniqueness | the plain-copy timeline: an unstamped packet gets `pts=dts` — wrong display slot *and* a collision with a rung another packet holds |
| **(k)** presentation-order-vs-POC | output PTS order must agree with `pic_order_cnt_lsb` order (§8.2.1.1 unwrap), generalizing `poc-gate.sh` beyond the junction lane to any H.264 output | constant-rate restamps of reordered streams; any timeline whose order contradicts what the bitstream itself declares |
| **(l)** edit-list / first-frame anchor | min output PTS maps to 0; the edit list does not silently trim the first displayed frame | the earliest-displayed-frame trap |
| **(m)** essence arbiter | NAL-payload hash, start-code-length agnostic — the arbiter for an (a)/(b) mismatch | merging two field AUs turns a 4-byte start code into 3 bytes; a raw byte hash false-mismatches a *correct* build by exactly one byte per merged pair |
| **(n)** the UNPROVEN ledger | every gate's verdict including the ones that could not run, and what each leaves unproven | quiet assumption itself |

---

## Tier 3 — attempt gates

| # | Gate | Where | Disposition |
|---|---|---|---|
| T3.1 | **PAFF copy-rung skip** — `auto.sh` routed field-coded sources straight to the rebuild; Rungs 0/1 never executed | `auto.sh` PAFF arm | **CUT (1.16.0).** The ladder always executes Rung 0 (and 1 when audio requires). The mux-confession stop and gates (d)/(j)/(e) judge the artifact. On feed.ts this yields *"built; FAILed gates (j)/(d): 10 duplicate PTS — escalating"* — evidence instead of an untested prediction. The exemplar case. Test 104. |
| T3.2 | Constitution **I.3** "never build to a foregone refusal" | `CONSTITUTION.md` | **REWRITTEN (1.16.0)** as *"Gate the assertion, not the attempt"*. A pre-flight refusal is legal only as a cached deterministic attempt or a Tier-1/resource condition. Cost of a doomed big build is handled by announcing the cost and the prediction, then proceeding (`--preflight-only` when the operator asks). The session may warn; it may not refuse. |
| T3.3 | `zero-base.sh` PAFF pre-flight refusal | `zero-base.sh:133,:147` | **CONVERTED (1.16.0)**: warns (prediction stated with its measurement), builds, and lets the confession stop + `verify-source.sh` judge. `--preflight-only` still returns the old verdict without building. Test 75 rewritten to assert warn + build + verdict. |
| T3.4 | derive-dts `_pair_parity` evidence rule — "fields are coded-adjacent one **field duration** apart", 99% bar | `derive-dts.py`, `h264poc.py`, `poc-remux.py` | **EVIDENCE REPLACED 1.16.0; THE UNANIMITY BAR CONVERTED 1.17.0.** The original rule measured *timestamp deltas* and inferred *structure* — a proxy, while the direct evidence sat unread in every slice header. Pairing is structural (`field_pic_flag=1`, `bottom_field_flag` 0→1, same `frame_num`, coded-adjacent) and timestamps come from POC (`k = POC + C`, C per `(IDR-epoch, bottom_field_flag)`). 1.17.0 splits the bar in two, because its halves are not the same kind of claim. **The sample floor (≥100 votes) still refuses** and has no env override: too little evidence is too little evidence. **The ≥99.9% unanimity bar is now announced, not fatal** — it is a prediction about output QUALITY (Constitution I.3), and it is capped at 1 − f on a systematic mis-stamp, so a stream where a fraction f of pictures carry a wrong timestamp *cannot* reach it however exactly its repair is evidenced. Measured 2026-08-30: f = 0.174, ceiling 0.826, bar 0.999 — structurally unreachable on exactly the class the rung exists to repair. When no class clears the bar and every class carries ≥100 votes, the modal C proceeds as PROVISIONAL with a loud warning naming the shortfall, and the OUTPUT gates judge: `poc-remux.py` refuses unless every frame lands on its own slot (a wrong C cannot survive a bijection onto the lattice), then asserts DTS monotonic and DTS ≤ PTS, then runs the whole `verify.sh` suite. That is strictly stronger evidence than the bar it replaces. `RTM_POC_MIN_AGREE` overrides the bar, announced with its value. Tests 100, 105, 118 §3/§5. |
| T3.5 | derive-dts duplicate-PTS refusal | `derive-dts.sh:113,:167`, `derive-dts.py` | **CONVERTED (1.16.0)**: each duplicate is adjudicated by POC — exactly one holder fits its local lattice, and `adjudicate_duplicates` measures which. Refuses only a duplicate POC cannot adjudicate, naming the per-duplicate evidence. Every windowed number is scoped at the point of print. **Prose corrected (1.17.0):** this row used to say *"the later holder never fits its local lattice, the earlier always does"*. That generalised from one capture. The code was always general — it measures `fits` and does not care which holder wins — and the 2026-08-30 field file splits roughly 550 second-lower / 509 first-lower. The true statement is: **exactly one holder fits its local lattice; which one is not fixed.** Tests 101, 106. |
| T3.6 | pairfill-paff junction refusal (runs > 2 untimestamped → exit 3) | `pairfill-paff.sh:228` | **SUPERSEDED** by Rung 3-POC. pairfill keeps the simply-paired class it actually fits, with its jurisdiction stated in its header and in `references/timeline-repair.md`. |
| T3.7 | rebuild-paff refuses reordered streams | `rebuild-paff.sh:56` | **KEEP as default + announced `--force`.** PTS=DTS on a reordered stream is arithmetic about the transform, not a prediction about the input — but the override exists, and gate (k) is the judge either way. |
| T3.8 | Unroutable-codec exit 11 (VC-1/VP9/AV1 video, Dolby E audio) | `lib-paff.sh:975,:1005`; `remux.sh:119,:122,:318`; `mov.sh:210,:234`; `auto.sh:95,:102`; `mp4-swap.sh:117`; `dual-track.sh` FLAC/Opus/Vorbis/TrueHD exit 2 | **KEEP, reclassified** as *cached deterministic attempts* — the muxer's own rejection, measured and version-pinned. `doctor.sh --cache-check` re-verifies the cache against the installed ffmpeg (a measurement you re-run, not a document you go find). |
| T3.9 | genpts "guilty-until-proven" on PAFF | routing prose + `auto.sh` | **CONVERTED to guidance.** The claim (mux-valid ≠ seekable) is true and stays doctrine; enforcement moved entirely to gates (d)/(e)/(j)/(k). No path is blocked. |
| T3.10 | `diagnose.sh` printing routes whose only outcome is exit 3; verdicts resting on windowed counts | `diagnose.sh` | **CONVERTED (1.16.0)**: diagnose gains whole-file duplicate-PTS and unstamped-packet censuses and a POC-capability probe; it *reports and recommends* with measurements. "Predetermined" language is banned. It may say "Rung 0 will likely FAIL gate (j) — here is the census"; it runs the rung anyway when asked. |
| T3.11 | `resync.sh` mid-stream audio-layout-change refusal | `resync.sh:144` | **KEEP as default** (the injected-silence class is invisible to duration parity) + announced `--force` that mandates `verify.sh --silence` on the result. |
| T3.12 | `auto.sh` flattening a child's exit 3 into `>> FAIL` | `auto.sh` | **FIXED (1.16.0).** REFUSED and FAIL are the two different "no"s this whole ledger is about; the vocabulary must not collapse them. Test 102. |

### Legitimate non-predictions found by the Phase-1 sweep

These refuse, and are **not** attempt gates. Each carries its `# TIER` comment.

| Site | Class | Why it stands |
|---|---|---|
| `auto.sh:76`, `mov.sh:192,:451` — probe failed → refuse to plan | Tier 1 (instrumentation) | EMPTY ≠ ABSENT (Constitution III.1). A failed probe is not a measurement of the source; planning from it is the fabricated-manifest class. |
| `mov.sh:495` — `--audio-keep` unhonored on this path | Tier 1 (config honesty) | Refusing to silently ignore an operator flag. No build is prevented that the operator asked for. |
| `derive-dts.sh:176,:202,:209` — no-reorder / depth-class signature | Tier 3, routing | Named routes exist and `--force` overrides; jurisdiction stated at the point of refusal. |
| `pairfill-paff.sh:119,:161,:168,:200,:201` — not H.264, unusable timebase, no packets, unanchorable first packet | Tier 3, cached deterministic | The tool cannot express the operation at all; attempting reproduces the same refusal with a worse message. |
| `playable-check.sh:234–239,:362` — no `avconvert`/`ffmpeg`/`ffprobe`, unreadable geometry | Tier 2 (UNPROVEN) | Reports REVIEW/SKIP, never damage. Constitution II.1. |
| `rung4.sh:58` — no valid attestation | Tier 1 | The re-encode consent gate. |
| `lib-mux.sh` — disk pre-flight | Tier 3 — **CONVERTED (1.17.2)** | Run the classification test honestly and the damage-if-deleted is row (d): ENOSPC is loud, the `.part` is kept, the census FAILs, the source is untouched. The old Tier-1 filing ("a resource check") let a refusal ride on a meter that under-reads — macOS/APFS `df` excludes purgeable space, so the gate became a hard size ceiling at whatever df happened to show (field report 2026-08-31). Default now WARNS + builds (`RTM_DISK verdict=warn`, meter caveat named); `RTM_DISK_CHECK=strict` restores the refusal for unattended batches; `=0` skips announced. Test 87. |
| `zero-base.sh` source-rot refusals (scrambled; backward/duplicate DTS) | Tier 3, routing | Zero-base is not a timeline repair; the named routes are the repair. Not a quality prediction about zero-base's own output. |

---

## Amending this ledger

A new refusal site needs: a `# TIER n` comment naming its row, a row here, and
the classification test's answer written out. A refusal without a row fails
`94-rot-sweep.sh` §11 — which is the point: the classification is permanent,
not a one-time cleanup.

**Fewer refusals to attempt; strictly more refusals to assert.**

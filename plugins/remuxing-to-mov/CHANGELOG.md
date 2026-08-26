# Changelog — remuxing-to-mov

History moved here from the `plugin.json` description in 1.15.0 (the orphaned
1.14 Phase-6 packaging item). Detailed doctrine lives in `skills/remuxing-to-mov/
SKILL.md` and `references/`; every empirical claim below is dated in the docs.

## 1.15.1 — topline-semantics round (2026-08-26)

Cross-ref against the live plugins reference (code.claude.com/docs/en/
plugins-reference + plugin-marketplaces, fetched 2026-08-26):

- **`$schema` added to both manifests** — the docs now name official schemas
  (`json.schemastore.org/claude-code-plugin-manifest.json` and
  `…/claude-code-marketplace.json`; both verified live, HTTP 200
  application/json). This REVERSES the 1.15.0 Phase-0 decision below, which
  was correct on its evidence at the time (no URL was then verifiable on
  this bench) — the reversal is recorded, not hidden.
- `description` tightened to the docs' "brief, concise for marketplace
  display" guidance (~360 chars, history pointed at CHANGELOG.md);
  marketplace entry description aligned to match.
- `displayName` → **"Remux to MOV & Source Clinic"** (free-form per docs,
  not used for lookup) — the picker now names both storeys.
- Marketplace entry enriched with the recognized optional fields
  (`displayName`, `author`, `homepage`, `repository`, `license`).
- **`name` kept as `remuxing-to-mov`, deliberately**: it keys
  `enabledPlugins`, the install identity, and the `/remuxing-to-mov:*`
  command namespace. The docs' `renames` map (v2.1.193+) makes a rename
  *possible*, but identity stability is house doctrine (machine lines never
  rename) and the name still names the plugin's center of gravity; the wider
  scope lives in displayName/description/keywords, the surfaces built for it.
- `claude plugin validate` passes clean (plugin `--strict` and the whole
  marketplace — entry-level plugin.json checks included).

## 1.15.0 — the source-clinic round (2026-08-26)

The storey below the ladder: integrity checks and corrections **to the source
file in its own container** (.ts/.mkv) — re-wrap, never remux, never in place,
never touching the original. Origin: the 2019-VMA `feed.ts` cleanup case file.

- **Phase 0 (the orphaned 1.14 Phase 6):** `CHANGELOG.md` (this file);
  `plugin.json` description shrunk to two sentences; `.bak`/`.DS_Store` strays
  removed; `allowed-tools` comma-separated in both SKILL frontmatters; CI
  resurrected at the monorepo root (the plugin-level workflow never ran there —
  GitHub only reads `.github/workflows/` at the repo root); `references/knobs.md`
  env-knob table; SKILL.md path-convention note (`scripts/…` resolves under
  `${CLAUDE_PLUGIN_ROOT}/skills/remuxing-to-mov/`). Decision recorded: no
  `$schema` added — no verified schema URL exists on this bench and no sibling
  plugin carries one; inventing an unverifiable URL fails house doctrine.
  **[REVERSED in 1.15.1, same day: the live docs name the official
  schemastore URLs; verified and added — see the 1.15.1 entry.]**
- **verify-source.sh** — the source-domain verification battery as a unit:
  filtered-reference streamhash (per-stream identity of a *cut* proven as
  rigorously as a straight copy), census arithmetic vs the plan, head/tail
  decode checks, duration arithmetic, and the nothing-unexplained gate.
  Closes the "no lossless-identity prover for non-MOV outputs" hole
  (known-limits: verify.sh gate (d) is QTFF-shaped by design).
- **clock.sh** — the player-clock translator: player-clock time = container
  time − `format.start_time`; translates a "video starts at X" report into a
  raw timestamp address with bracketing keyframes and per-frame luma means.
- **zero-base.sh** — Tier-1 structural re-wrap: mpegts timeline zero-base
  (`-muxdelay 0 -muxpreload 0`) with PID/program layout preserved, the
  minimum-start floor stated up front (first-frame reorder delay; exact 0 is
  impossible with B-frames without inventing timing), and a null-muxer
  prediction pre-pass whose expected artifact set (equal-DTS +1-tick nudges)
  is announced before the build and reconciled after it.
- **lead-check.sh** — black-lead detection: luma-mean sweep + keyframe map +
  H.264 NAL-type census (IDR vs open-GOP I) + audio level across the candidate
  splice; names the exact cut address and what a cut would discard.
- **surgical-cut.sh** — the sanctioned non-IDR cut on MPEG-TS: deterministic
  packet selection (`noise=drop=` by video packet index / audio PTS,
  `-copyts` + `-output_ts_offset`, no seeking — both `-ss` forms are
  measured-unreliable on TS), leading-B rule applied, PID layout preserved.
  **Tier 2 consent:** refuses without `--discard-content` and prints the exact
  decodable-media loss statement.
- **dim-scan.sh** — whole-file frame-dimension sweep; the mid-stream
  SPS/resolution-change named limitation gains its detection half.
- **clean.sh + `/remuxing-to-mov:clean`** — the clinic driver: cheapest-first
  analysis battery, findings where every route stays in the source container,
  Tier-1 offered / Tier-2 named for the operator.
- Recorded candidates (named, not built): `wrap-split.sh` (≥2-wrap horizon),
  `derive-dts.sh --container mkv` (same-container MKV lane), bars-and-tone
  lead detection.
- **First-ever CI run, and what it taught (2026-08-26):** the resurrected
  workflow's maiden run failed on every leg — none of it from this round's
  code. Test 61 (1.14) had pinned exact decoder-chatter counts measured on
  the macOS bench ("2 decode lines") that Linux static builds count
  differently — re-pinned as build-measured *relationships* (count registers
  and equals the most-forgiving candidate at delta 0; decisive delta positive),
  never as constants. The ms-timebase alternation pin is now gated on the
  fixture's own minted shape (ffmpeg 6.1/7.1 mint it with uniform durations —
  nothing to preserve there, announced skip). And the **4.4 matrix leg was
  dropped: the supported floor is 6.1** — 4.4 failed 20 assertions across a
  dozen sub-suites because that 2021 build predates surfaces the plugin
  legitimately depends on; below the floor the claims are benched for, green
  would have meant papering over, not proving. One real behavioral finding
  came out of the same run: **ffmpeg 6.1/7.1 movenc rounds a ms-quantized
  source's alternating 41/42 ms deltas into a uniform duration table on a
  `--timescale` remux** — the C68 "alternation survives, source-baked, not
  smoothed" claim holds on ≥8.x only, and the suite now says so per version
  instead of asserting one bench's truth everywhere.

## 1.14.0 — the reorder-DTS round (2026-08-16..24)

The 54.6 GB 2023-VMA MKV incident: reordered field-coded H.264 in a DTS-less
container — ffmpeg reconstructs DTS with a frame-unit reorder depth applied as
a packet delay, short by exactly 2× on field packets. Essentially every 1080i
North-American HD feed muxed to MKV.

- **Rung 3-DERIVE (`derive-dts.sh` + vendored `derive-dts.py`, PyAV):**
  whole-file DTS derivation from the sorted PTS column (DTS[i] = (i−D)-th
  smallest PTS) — codec-agnostic, packets copied byte-for-byte; refuses outside
  its signature (exit 3, family-consistent); `--force` as announced operator
  override; attested precondition overrides via `lib-attest.sh`.
- **Measure right:** unit-aware reorder depth (`PF_DEPTH_*`, `PF_PPF`,
  `PF_DTS_SOURCE=carried|reconstructed` with printer annotations); both
  coded-rate ratio hypotheses tested and announced; modal sorted-PTS delta
  coded rate; presentation-order gap census (`DISC_P_*`) carries every
  dropped-time claim (the ~1000× overstatement fix).
- **Judge right:** `mux_census` three-verdict (missing=FAIL / expected
  surplus=announced PASS / unexpected surplus=REVIEW, never "missing");
  mux-confessions split video (hard stop verbatim) vs audio/subtitle nudges
  (announced REVIEW); gate (g) source-baseline subtraction.
- **Route right:** rungs chosen by measured profile, every verdict printing the
  measurements that drove it; junction fill model + POC-lattice gate in
  pairfill (max-run-2 displaced-timestamp class).

## 1.13.0 — the container axis (2026-08-15)

- **Rung 3-SWAP (`mp4-swap.sh`):** the same MPEG-2 4:2:2 bitstream AVFoundation
  destroys as `.mov` (`m2v1`+`glbl`) renders correctly as `.mp4` (`mp4v`+`esds`)
  — SSIM 0.9175+ on the exact failing timestamps, where all five MOV retags
  corrupted identically (movenc writes one generic sample-description body for
  every MPEG-2 fourcc). A fidelity FAIL routes here before Rung 4, ever.
- **Post-mux census (`RMX_CENSUS`)** at every mux site — ffmpeg was measured
  dropping 1 of 3 mapped streams at `-v warning`, silently, shipping green.
- **Scan-keyed fidelity:** 0.90 was progressive-tuned and false-FAILed healthy
  interlaced material; interlaced judged at 0.86 with per-plane Y/U/V split
  (the deficit is chroma-plane — field normalization measured and rejected).
- Audio gate corrected both directions: `ipcm` allowlisted; allowlist demoted
  from verdict to prior (off-list tags get the decode probe); MP2 with no PCM
  access track finally REVIEWs. Extension-keeping part files (`x.part.mov`).

## 1.12.0 — fidelity storey (2026-08-15)

- `playable-check.sh --fidelity`: renders ≠ renders correctly — bounded
  avconvert ProRes windows SSIM-compared against the ffmpeg reference decode.
- m2v1→xd5* decoder-dispatch retag advisory (advisory-only; auto-apply
  deferred pending bench). Movie-timescale overflow truth (2^31-tick warning
  onset; geometry-gated silent chapter-track drop past 2^32, warning
  suppressed on exactly the dangerous geometries — pre-announced).
- Post-hoc gap-collapse repair route for an already-collapsed MOV.

## 1.11.0 — keep-all audio, evidence-demoted gates (2026-08-13/14)

- `--audio-keep all` default (dropping buys no playability — TN3177); per-track
  `--audio auto`; DRC `-drc_scale 0` default on AC-3/E-AC-3 decodes.
- The categorical 4:2:2 refusal **falsified on macOS 26.6.1** and demoted to
  announce + build + post-build empirical playability proof. Backhaul timeline
  rot demoted from refusal to warn+build (the measured gates judge the artifact).
- VC-1/VP9/AV1 video and Dolby E audio refused pre-flight with routes (exit 11,
  `MOV_REFUSED`) at every entry point. `pcm_bluray`/`pcm_dvd` routed to PCM
  access (the copy-muxed HDMV track is undecodable). Mid-GOP starts auto-trimmed
  (`trim-to-idr.sh`). 200M probe windows with announced 1G retry. SOURCE DAMAGED
  keyed to transport evidence, never decode noise.

## 1.10.0 — backhaul gate at every entry point (2026-08-01)

- The 1.8.0 refusal gate enforced at every `.mov`-writing entry point (closed
  after a direct build produced a doomed 2017-feed MOV the front door would
  have refused).

## 1.9.0 — H.264 High 4:2:2 (2026-07-31)

- QT-undecodable gate widened to H.264 High 4:2:2 (both classes later
  re-measured and demoted in 1.11.0 — the registry records the reversal).

## 1.8.0 — ts-health (2026-07-30)

- `ts-health.sh` one-command capture scan (transport loss, missing timestamps,
  DTS rot, forward gaps, 33-bit PTS wrap, mid-GOP start, single-GOP,
  audio drift — every finding routed). Backhaul refusal gate (since demoted).
  `verify.sh --silence` content parity (the ~17-min injected-silence class).

## 1.7.0 — QTFF audit round 5 complete (2026-07-26)

- `rung4.sh` — the only sanctioned re-encode path (verbatim operator
  attestation + mdta provenance); verify.sh master-purity scan; waiver
  sidecars (`waiver.sh`); track-set-aware audio policy; Tahoe decode-set
  drift documented; ms-timebase doctrine.

## 1.6.0 — QTFF spec audit rounds 1–4 (2026-07-26)

- 62-claim registry (`qtff-claims.md`) with dated verdicts; pairfill
  boundedness gates; `--signaling` pasp check; VFR-safe duration gate.

## 1.5.0 — post-mortem teeth (2026-07-25)

- The pair-timestamped PAFF class (PES timestamps only on the first field of
  each pair; a straight copy makes the MOV muxer INVENT timing): `pairfill-paff.sh`
  keeps every real PTS; `rebuild-paff.sh` refuses reordered streams; the
  muxer-confession hard stop; whole-file output-timeline gate (d); scrub gate.

## 1.4.0 (2026-07-24)

- `/mov` one-command shortcut; discontinuity resync (`resync.sh`); E-AC-3
  recognized QT-native (copied single-track); opt-in QuickTime `mdta` metadata
  (`metadata.sh`); capability doctor (`doctor.sh`).

## 1.1.0 (2026-07-23)

- `/mov` command added; verify decode check hardened.

## 1.0.0 (2026-07-22)

- Initial release: lossless-first remux ladder, dual-track audio deliverable,
  verification gates, references.

# 1.15.7 Work Order — A Scanner States Its Jurisdiction

> **Status (2026-08-27): filed and executed in the same session.** The checkup
> round packaged as "jurisdiction" (CHECKUP-2026-08-27: **B1–B4, F1, F12,
> A3 leftovers**; the checkup's rule 5: *a scanner states its jurisdiction
> instead of printing an unscoped CLEAN*). Tests **88–89**, red-verified
> against 0d225ad first (88: 26 red of 35; 89: 4 red of 8 — and both bench
> preconditions minted: the wrap fixture produced the negative start, the AVI
> muxer wrote tb 1001/30000).

## What landed

- **B1 — no video stream.** `ts-health.sh` no longer scans stream 0 as
  "video" when no video stream exists (the old `-v vidx="${vidx:-0}"`
  fallback; measured: an MP2-only TS read `video packets=1532 … CLEAN`).
  `vidx=-1` matches nothing; a `[scope]` finding names the missing
  jurisdiction (verdict FINDINGS rc=10, never an unscoped CLEAN); the bogus
  single-GOP finding is video-gated; `TSH_VIDEO=yes|none` in `--kv`
  (additive). `zero-base.sh` refuses audio-only at PRE-FLIGHT, exit 2,
  nothing written (pre-round: the full re-wrap was built only to die at
  verify-source's "no video stream" — the 1.15.2 Item-C shape on a new
  axis). `clean.sh` gates the Tier-1 zero-base route on `TSH_VIDEO` and adds
  its own scope finding.
- **B2 — transport vocabulary.** The transport counters grep mpegts
  confession strings; program streams have none (measured: 4000 random bytes
  mid-.vob read "no transport loss"). `TSH_SCOPE=mpegts|demux-only`
  (additive), a scope line in the transport section for every non-mpegts
  container, and the CLEAN verdict is scoped there ("demux-only … payload
  corruption demuxes silently; a DECODE proves content: clean.sh --deep /
  verify gate (b)"). rc semantics unchanged — the harm was the DEFINITIVE
  wording, and that is what changed.
- **B3 — timebase numerator.** `tickrate=${tb##*/}` kept the denominator
  only; on tb 1001/30000 the expected frame duration computed as ~1001 ticks
  against a 1-tick cadence and a measured 15-frame drop read `gaps=0`. Both
  scanners (`ts-health.sh`, `lead-check.sh`) now parse num/den and work in
  real ticks-per-second (den/num, fractional allowed; all consumers are
  awk). mkv 1/1000 and mpegts 1/90000 unchanged by construction. Test 89's
  A/B: the same drop reads ~0.5 s through both containers.
- **B4 — the unwrapped wrap.** On this ffmpeg the demuxer hands back an
  already-unwrapped timeline: a minted mid-capture 2^33 crossing yields
  `start_time=-7.317689`, `V_WRAP=0`, CLEAN (measured). The symptom —
  NEGATIVE start_time — is now a named finding in both `ts-health.sh`
  (`TSH_START` additive; the wrap counter documented as guarding the old
  representation, kept for demuxers that still hand it) and `clean.sh`
  (which checked the positive direction only). Test 88 §5 guards on the
  minted start actually being negative (demuxer-version-dependent; announced
  SKIP otherwise). The half-wrap −2^32 threshold question stays SUSPECTED
  (needs a two-segment concat fixture) — recorded, not fixed blind.
- **F1 — zero-base's PAFF diagnosis.** The single `half_ts || paff` refusal
  arm labeled a FULLY-TIMESTAMPED PAFF source "pair-timestamped", claimed
  untimestamped mates it does not have, and routed it to `pairfill-paff.sh`
  — which exits 3 on exactly that file. Split: the half_ts arm keeps its
  1.15.2 message verbatim (test 75's pins); the full-TS arm refuses as
  stated POLICY (the TS→TS-preserves-PAFF claim is case-file-scoped and
  unproven) with the honest profile (`half_ts=no`), the statement that
  pairfill would refuse this very file, and a route that accepts it
  (`mov.sh` copy ladder; diagnose.sh for timestamp work). Pinned via the
  measured `pf_detect` injection (full timestamps at 2× nominal →
  `paff=yes half_ts=no`).
- **F12 — multi-program reaches machines.** `probe.sh` computes `nprog`
  inside `probe_struct` and emits `PR_NPROG=` in `--kv` and `"nprog":` in
  `--json` (append-only; 0 = container carries no program concept, mpegts
  is ≥1). `clean.sh` gates the zero-base ready-to-run on `PR_NPROG <= 1`
  and names the topology in the else-arm (pre-round: it printed a command
  that refuses exit 2 — measured). Fixture: the test-68 two-program mint.
- **A3 sweep.** Test 88 §8 pins the invariant the one-liner round
  established: every entry point (scripts/*.sh minus lib-*) either sources
  lib-probe.sh or exports LC_ALL=C directly. Green at execution (the
  one-liner round had closed it); the pin keeps it closed.

## Gates

Suite **287/287** (285 carried + 2 new); high-risk neighbors
re-run individually first (11/21/54/64/66/67/68/69/72/75/81 — all green);
`claude plugin validate --strict` green on plugin and marketplace.

## Residuals (recorded)

- B4 secondary: the −2^32 half-wrap threshold can label a >13.26 h backward
  epoch reset "wraparound" — SUSPECTED, needs a two-segment concat fixture.
- B2 is scoped wording, not new detection: a corrupt .vob still demuxes
  silently — the decode that catches it remains `clean.sh --deep` / verify
  gate (b), now named at the verdict.
- ts-health's FINDINGS/DAMAGED verdict texts are unscoped (only CLEAN was
  the measured harm); their findings carry per-finding routes already.

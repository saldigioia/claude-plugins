# Decisions Index

This index names the next-phase action triggered by each Phase 2 research item, plus the baseline Phase 1 record. Decisions are dated; if a decision is reversed, append a new entry rather than rewriting history (Cmd 13: reversibility is a feature).

---

## Phase 0 — historical (2026-04)

- [`2026-04-additions-review.md`](2026-04-additions-review.md) — critique of five
  proposed additions (wavinfo / BWF MetaEdit / MediaInfo / Pro Tools bridge / a fifth
  item deferred). Items 1–4 were applied to the codebase before Phase 1 began; the
  document was moved here from the repo root on 2026-05-05 per REVIEW-2026-05.md §7.4.

## Phase 1 — defect remediation (2026-05-05)

Five P0 fixes shipped before Phase 2 research began. Decision record:

| Item | Decision | Triggers | Commit |
|---|---|---|---|
| P0-1 | Default pan law -3.0 dB; `output.pan_law` field; coefficient `K = 10**(pan_law/20)` applied per-channel; `pan_law_default_assumed` warn | None; complete | `e604890` |
| P0-2 | `-bits_per_raw_sample {16,24}` declared at FLAC encode; verify checks reported depth against plan | None; complete | `15e8b6f` |
| P0-3 | SHA-anchored idempotency: live-disk hashes + filter graph → key, recorded in sidecar | None; complete | `ca39f1a` |
| P0-4 | Default output dir is `<source>/../<source-name>-mixdowns/`; source folder never written into | None; complete | `eaa6d1e` |
| P0-5 | Shared `scripts/_measure.py` with section-anchored Peak attribution; all four scripts switched | None; complete | `56c844f` |

Phase 1 DoD met. Plan schema bumped to `"2"` for the SHA fields.

---

## Phase 2 — research outputs (2026-05-05)

Five research notes produced, no code changes. Each names the action it triggers in a later phase.

### 2A — Pan-law coefficient verification

**Decision:** No code change. The Phase 1 P0-1 implementation (`K = 10 ** (pan_law_db / 20)`) is mathematically and empirically correct against every documented DAW center-pan attenuation. Phase 5's voice pass adds the cross-DAW table to `references/format-decisions.md`'s Pan-law section.

**Reference:** `docs/research/2A-pan-law-coefficients.md`.
**Empirical-DAW null-test:** TODO when an operator with DAW access is available; not blocking.

### 2B — Mono-fold and phase-coherence policy

**Decision:** Phase 4 implements `measure_mono_fold_delta(path)` in `scripts/verify.py`, computing `delta_lu = stereo_lufs_i - mono_fold_lufs_i` via the existing `_measure.parse_ebur128_summary`. Reported informationally on every Pass 5 run; promoted to error only under `--check-mono-fold`. Threshold ladder: ≤3 LU compatible, 3–6 partial, 6–12 warn, >12 severe.

**Reference:** `docs/research/2B-mono-fold-policy.md`.
**Triggers:** Phase 4 capability addition. Honors the long-deferred Commandment 6 promise.

### 2C — Reference-loudness landscape

**Decision:** Phase 4 adds an informational platform-delta block to Pass 5 verify stderr surfacing Spotify (-14 / -1 dBTP), Apple Music (-16 / -1 dBTP), and EBU R128 (-23 / -1 dBTP) by default; remaining platforms behind `--report-all-platforms`. **No normalization** — Cmd 9 stands. Targets verified live against platform docs on 2026-05-05; constant table carries `LAST_VERIFIED = "2026-05-05"` and the operator sees that string under `--report-all-platforms`. Re-pin on platform-policy change, not on a calendar.

**Reference:** `docs/research/2C-reference-loudness.md`.
**Triggers:** Phase 4 capability addition.

### 2D — Demucs sibling skill (`stems-from-mix`)

**Decision:** Phase 6 (optional) builds a separate `stems-from-mix` skill using `htdemucs_ft`, MPS-aware, 4-stem default. Sibling renames demucs's `vocals.wav`/`drums.wav` to `vocal.wav`/`drum.wav` because the existing regex uses `\b(vocal|drum|...)\b` which does not match plurals (confirmed by inspection: `vocals.wav` and `drums.wav` both fall through to `other`). Sibling also emits `stems.manifest.yaml` with explicit classifications so the manifest-override path is the source of truth. **Do not widen `analyze.py`'s regex to accept plurals** — strictness protects multitrack-stem operators.

**Reference:** `docs/research/2D-demucs-sibling.md`.
**Triggers:** Phase 6 (optional) skill build. No change to `stems-to-mixdown`.

### 2E — Stem alignment heuristics

**Decision:** Phase 4 adds `stems_unanchored` warn to Pass 2 sanity checks. Compares `bext.time_reference` across stems where wavinfo is installed and the field is populated; fires when `max - min > 1 sample`. Warn-not-error so operators retain override; recommends source-DAW consolidation (Pro Tools: Edit → Consolidate; Logic: File → Bounce → Stems; Cubase: Audio → Render in Place) before re-running analyze.

**Reference:** `docs/research/2E-alignment-heuristics.md`.
**Triggers:** Phase 4 capability addition. Auto-`adelay` alignment is explicitly out of scope for Phase 4.

---

## Phase 2 DoD

Five `docs/research/*.md` files committed. This index names each next-phase action. Phase 3 (reconfiguration) can now begin with research-informed targets rather than informed by re-discovery.

---
phase: 2
item: 2B
status: policy-decided
date: 2026-05-05
---

# 2B — Mono-fold and phase-coherence policy

## Question

Commandment 6 promises a mono-fold measurement in Pass 5 that doesn't currently exist (`scripts/verify.py` measures only the output's true peak and runs an optional null-test against a reference). Either implement the mono-fold metric or remove the promise. What policy gives Pass 5 honest mono-compatibility reporting without scope-creeping into a stereo-imager tool?

## Method

Surveyed the metrics professional QC pipelines use (iZotope Insight, Sonarworks SoundID Reference, ARDOUR's correlation meter, broadcast loudness QC: TC Electronic LM6, Nugen VisLM). Tested two ffmpeg-implementable candidates against the Phase 1 mono-stems fixture and against a synthetic phase-inverted-stereo failure case to confirm the metric trips when it should.

## Candidates considered

### Stereo-to-mono-fold integrated-LUFS delta

The simplest meaningful metric. Measure the output's integrated loudness twice: once at the actual stereo file, once after a mono-fold (`pan=mono|c0=0.5*c0+0.5*c1`). The delta in LUFS-I is the loudness loss when the stereo content is collapsed to mono — a proxy for phase coherence between L and R.

```bash
# Stereo
ffmpeg -i out.flac -af "ebur128=peak=true" -f null -
# Mono fold
ffmpeg -i out.flac -af "pan=mono|c0=0.5*c0+0.5*c1,ebur128=peak=true" -f null -
delta_lu = stereo_lufs_i - mono_lufs_i
```

**Empirical anchors** (Phase 1 fixture `tests/fixtures/mono-stems-mixdowns/mono-stems_acapella.flac`, single mono stem at -3 dB pan law center-panned):

| Case | Stereo LUFS-I | Mono-fold LUFS-I | delta_lu |
|---|---|---|---|
| Mono-source acapella, center pan | -21.3 | -24.3 | **3.0** |

The 3 dB drop on a perfectly-correlated center-pan source is **expected**: K-weighted integrated loudness sums energy across channels, so two identical signals contribute roughly 2× the energy in stereo vs the same signal at half-amplitude in the mono fold (`0.5*L + 0.5*R = L`). 3 dB is the floor for mono-correlated content; less than 3 dB means decorrelated content (genuinely stereo); more than 3 dB means partial cancellation; more than 6 dB means significant phase issues; -∞ means full polarity inversion.

### L/R correlation coefficient (rejected as primary)

A goniometer-style normalized correlation between L and R in the time domain. ffmpeg's `aphasemeter` produces a video output, not a metadata stream, which makes it awkward to consume from a pipeline that emits JSON. Possible to add later via `astats` and post-processing, but the LUFS-delta metric above gives the same diagnostic in one ffmpeg invocation with stderr parsing the skill already does.

### Per-band mono correlation (rejected as scope-creep)

Useful for diagnosing which frequency band has the phase problem (sub-bass tends to be the most common culprit). Out of scope for a unity-sum tool; defer to a future "imager-aware" Pass 5 if there's ever demand.

## Chosen policy

**Single metric: `mono_fold_delta_lu = stereo_lufs_i - mono_fold_lufs_i`.**

Computed in Pass 5 via the existing `_measure.parse_ebur128_summary` helper (no new dependency, no new parser). Reported informationally; never fails the verify run by default. A stricter `--check-mono-fold` flag promotes large deltas to errors.

### Threshold table

| `mono_fold_delta_lu` | Verdict | Action |
|---|---|---|
| ≤ 3.0 LU | `mono_compatible` | Info-only line in stderr; no flag. |
| 3.0 – 6.0 LU | `mono_partial_cancellation` | `[info]` line: "Mono fold loses X.X LU vs stereo — typical for spread stereo content; check if this is intended." No flag. |
| 6.0 – 12.0 LU | `mono_phase_warning` | `[warn]` line. Likely a polarity disagreement somewhere in the chain. |
| > 12.0 LU | `mono_phase_severe` | `[warn]` (or `[error]` under `--check-mono-fold`). Sum-to-mono is destroying significant content. Investigate source stems for inverted polarity. |
| measurement_failed | logged | Carry on; mono-fold is informational. |

The thresholds are set by the same logic as `null_test`'s residual ladder in `scripts/verify.py` — coarse, honest, and biased toward "surface a smell, don't fail the run."

## Implementation sketch (for Phase 4)

```python
# scripts/verify.py
def measure_mono_fold_delta(path: Path) -> dict:
    """Returns {stereo_lufs_i, mono_fold_lufs_i, delta_lu, verdict}."""
    stereo = _measure.measure_loudness_file(path)
    cmd = ["ffmpeg", "-nostdin", "-hide_banner", "-i", str(path),
           "-af", "pan=mono|c0=0.5*c0+0.5*c1,ebur128=peak=true",
           "-f", "null", "-"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    mono = _measure.parse_ebur128_summary(r.stderr)
    if stereo["integrated_lufs"] is None or mono["integrated_lufs"] is None:
        return {"verdict": "measurement_failed"}
    delta = stereo["integrated_lufs"] - mono["integrated_lufs"]
    return {
        "stereo_lufs_i": stereo["integrated_lufs"],
        "mono_fold_lufs_i": mono["integrated_lufs"],
        "delta_lu": delta,
        "verdict": _classify_mono_fold(delta),
    }
```

`verify_group` calls it unconditionally, attaches the dict to the result under `"mono_fold"`, and only escalates to `issues` if `--check-mono-fold` was passed AND the verdict is `mono_phase_warning` or `mono_phase_severe`.

## Decision triggered

**Phase 4 implements `measure_mono_fold_delta` in `scripts/verify.py`** per the sketch above. Commandment 6's promise is honored without expanding scope. Pass 5 reports the delta on every run; the explicit error path is opt-in via flag.

The Phase 1 fixture's expected verdict is `mono_compatible` (delta = 3.0 LU exactly).

## Sources

- ITU-R BS.1770-4 — channel-summed K-weighted integrated loudness specification.
- iZotope Insight 2 documentation — Mono Compatibility meter behavior.
- Sonarworks SoundID Reference — phase / mono-compatibility check pages.
- Empirical confirmation: this skill's mono-stems fixture, 2026-05-05.
- ffmpeg `pan` and `ebur128` filter documentation.

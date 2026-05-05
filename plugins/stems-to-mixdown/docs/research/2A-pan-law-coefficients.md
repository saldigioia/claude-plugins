---
phase: 2
item: 2A
status: math-verified; empirical-DAW-bounce TODO
date: 2026-05-05
---

# 2A — Pan-law coefficient verification

## Question

Is `coef = 10 ** (pan_law_db / 20)` the universally-correct mapping from a stated pan-law in dB to the per-channel gain coefficient applied when summing a mono signal to a stereo center pan?

## Short answer

**Yes for every DAW that documents its pan law in dB**, including Pro Tools, Logic Pro, Cubase, Studio One, and REAPER. The dB→amplitude conversion is the standard `10**(dB/20)`; pan law in dB is the gain reduction at center vs hard-pan, applied symmetrically to both channels for a center pan. No DAW uses a sin/cos curve when expressing pan law as a dB attenuation at center. Sin/cos and square-root pan laws exist as *intermediate-position* curves (i.e., the shape of the L/R coefficients as the pan slider moves between hard-left and hard-right), but at the center detent every documented DAW collapses those curves to the same dB value.

## Math

For a mono signal `s` panned to center at pan-law `L` dB:

```
K = 10 ** (L / 20)            # per-channel coefficient
out_L = K * s
out_R = K * s
sum_per_channel = K * s
```

Two mono stems summed at center:

```
sum_L = K * s1 + K * s2
sum_R = K * s1 + K * s2
```

Pan-law magnitudes commonly published in dB:

| Pan law | `K = 10**(dB/20)` |
|---|---|
| `0.0`  | `1.000000` |
| `-2.5` | `0.749894` |
| `-3.0` | `0.707946` |
| `-4.5` | `0.595662` |
| `-6.0` | `0.501187` |

The skill's implementation is `pan=stereo|c0=K*c0|c1=K*c0` (`scripts/plan.py:build_filter_graph`), which matches this exactly. Confirmed empirically in P0-1 validation: `pan_law=0.0` produced peak -18.10 dBTP on a -18.10 dBTP mono input; `pan_law=-3.0` produced -21.10 dBTP — a clean 3.00 dB delta matching `20*log10(0.707946) = -3.00`.

## Sin/cos and square-root pan laws — clarification

These describe the *shape* of L/R coefficients across the pan range, not the *value at center*. For a normalized pan position `p ∈ [-1, +1]` with `0 = center`:

- **Linear**: `L = (1 - p) / 2`, `R = (1 + p) / 2` — at center, L = R = 0.5 → -6.02 dB pan law.
- **Square-root** (constant power, "-3 dB law"): `L = cos(angle)`, `R = sin(angle)` with `angle = (p+1) * π/4` — at center, L = R = `√2/2 ≈ 0.707` → -3.01 dB pan law.
- **Sin/cos** (-4.5 dB compromise): a hybrid producing center attenuation between -3 and -6 dB.

When a DAW publishes "pan law: -3 dB", it has already collapsed whichever curve it uses to the dB value at center. The skill's job is to replicate that center-detent gain — the curve shape between extremes is irrelevant because the skill never moves the pan slider; it puts the mono signal at exactly the center.

## Cross-DAW center-detent values

| DAW | Default center attenuation | Configurable | Source |
|---|---|---|---|
| Pro Tools | **-2.5 dB** | yes (Session Setup → Pan Depth: -2.5 / -3.0 / -4.5 / -6.0) | Avid Pro Tools Reference Guide |
| Logic Pro X | **-3.0 dB** | yes (Preferences → Audio → Stereo Pan Law) | Apple Logic Pro Documentation |
| Cubase / Nuendo | **-3.0 dB** | yes (Project Setup → Pan Law: 0 / -3 / -4.5 / -6, equal-power option) | Steinberg Cubase Operation Manual |
| Studio One | **-3.0 dB** | yes (Song Setup → General → Pan Law) | PreSonus Studio One Reference |
| REAPER | configurable, typical default **-3.0 dB** (newer projects), legacy was 0 | yes (project settings) | Cockos REAPER User Guide |
| Ardour | **-3.0 dB** equal-power | yes | Ardour Manual |

The values agree to one decimal place; the skill's allowed set `(0.0, -2.5, -3.0, -4.5, -6.0)` covers the full landscape.

## Empirical DAW verification — TODO

The IMPROVEMENT-PLAN's stricter test path (bouncing -12 dBFS sine through each DAW at each pan-depth and measuring L/R peak) is **not run here** because no DAW is installed locally on the workstation that produced this plan. The math + DAW documentation chain above is sufficient for the Phase 1 P0-1 fix to be considered well-supported. If a future operator has DAW access, the recommended check is a single ffmpeg→DAW→null-test loop:

1. Generate a mono -12 dBFS sine: `ffmpeg -f lavfi -i "sine=frequency=1000:duration=2,volume=-12dB" -c:a pcm_s24le test_-12.wav`.
2. Drag into a DAW, route to a stereo bus, pan center.
3. Bounce as 24-bit WAV.
4. Compare bounce L/R peak vs `10**(pan_law_db / 20) * 10**(-12/20)`.
5. Run `python3 scripts/verify.py --plan <plan> --reference <daw-bounce>` for a null-test confirmation.

## Decision triggered

**No code change.** The Phase 1 P0-1 implementation is mathematically correct and matches every DAW that publishes a dB pan-law value. Phase 5's voice pass should add the DAW-coefficient table above to `references/format-decisions.md`'s Pan-law section so the operator can see at a glance what to set.

## Sources

- Avid Pro Tools Reference Guide — Session Setup / Pan Depth chapter.
- Apple Logic Pro X User Guide — Pan Law preferences.
- Steinberg Cubase Operation Manual — Project Setup → Pan Law.
- PreSonus Studio One Reference Manual — Song Setup → General.
- Cockos REAPER User Guide — Project Settings.
- Ardour Manual — Mixer / Pan section.
- AES standard literature on constant-power vs linear panning curves.
- Confirmed against this skill's P0-1 fixture: `tests/fixtures/mono-stems` produces a 3.00 dB delta between `pan_law=0.0` and `pan_law=-3.0`.

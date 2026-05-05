---
phase: 2
item: 2C
status: final
date: 2026-05-05
last_verified: 2026-05-05
---

# 2C — Reference-loudness landscape

## Question

The skill refuses to normalize (Commandment 9). But operators want to know how the unity-sum output compares to streaming-platform reference targets. Which platforms should Pass 5 surface as informational deltas, and at what target values?

## Method

Live web verification against each platform's published normalization documentation on 2026-05-05. Cross-referenced against EBU R128 and ATSC A/85 standards (stable specifications, not platform policy, no drift). The 2026 landscape has converged: every major streaming platform except Apple Music targets -14 LUFS-I; Apple Music alone follows AES TD1008's quieter -16 LUFS-I; broadcast standards (EBU R128 / ATSC A/85) remain at their long-standing values. **Re-pin the table at next confirmed change**, not on a calendar.

## Platform targets

| Platform | Integrated LUFS target (Normal/default) | Max true peak | Boost or attenuate? | Notes |
|---|---|---|---|---|
| **Spotify** | **-14 LUFS-I** | -1 dBTP (-2 if track is louder than -14) | both (boosts quiet, attenuates loud) | Loud preset -11; Quiet -19; Normal -14 is the listener default. |
| **Apple Music (Sound Check)** | **-16 LUFS-I** | -1 dBTP | both | Follows AES TD1008. Sound Check on by default since iOS 15. |
| **YouTube** | **-14 LUFS-I** | -1 dBTP | attenuate-only (loud → -14) | Quiet content not boosted; -14 is the cap. |
| **Tidal** | **-14 LUFS-I** | -1 dBTP | attenuate-only | Normalizes at the **album** level — preserves intra-album dynamics. |
| **SoundCloud** | **-14 LUFS-I** | -1 dBTP | attenuate-only | Default since 2024; matches the streaming consensus. |
| **Amazon Music** | **-14 LUFS-I** | **-2 dBTP** | attenuate-only | Strictest true-peak ceiling on the list. |
| **EBU R128** (broadcast) | **-23 LUFS-I** | -1 dBTP | hard spec | EBU Tech 3343. Absolute target, not normalization. |
| **ATSC A/85** (US broadcast) | **-24 LKFS** | -2 dBTP | hard spec | LKFS == LUFS for practical purposes; CALM Act compliance. |

The spread between most-aggressive (Spotify -14) and most-conservative (ATSC -24) is **10 LU** — a meaningful number for an operator deciding whether the unity sum is heading "for streaming" or "for broadcast." The streaming consensus on -14 LUFS / -1 dBTP means *one* well-prepared mix sits acceptably across Spotify, YouTube, Tidal, SoundCloud, and Amazon; only Apple Music (-16) and the broadcast tier (-23/-24) need separate consideration.

## Recommendation

**Surface three platforms in Pass 5 stderr by default**, plus EBU R128 because it's the broadcast reference and is stable:

- **Spotify (-14 LUFS-I, -1 dBTP)** — most common consumer destination, doubles as a general-streaming proxy.
- **Apple Music (-16 LUFS-I, -1 dBTP)** — second-most-common consumer; slightly different target tells the operator how much room the master will get.
- **EBU R128 (-23 LUFS-I, -1 dBTP)** — broadcast / archival reference; stable.

Skip per-platform clutter for Tidal, SoundCloud, Amazon Music, and YouTube unless the operator passes `--report-all-platforms`. They mostly converge to the Spotify -14 line; redundant in the default report.

## Suggested report format

Pass 5 verify stderr, after each output:

```
acapella.flac — output LUFS-I: -18.3 / true peak: -3.1 dBTP
  vs Spotify (-14 / -1):     Δ -4.3 LU loudness, Δ +2.1 dB headroom
  vs Apple Music (-16 / -1): Δ -2.3 LU loudness, Δ +2.1 dB headroom
  vs EBU R128 (-23 / -1):    Δ +4.7 LU loudness, Δ +2.1 dB headroom
```

Negative LU = quieter than target; positive = hotter. Headroom delta is `target_tp - actual_tp`; positive = comfortable. The lines are **informational**; the unity-sum output is unchanged. Mastering decisions remain a separate stage (Cmd 9).

`--report-all-platforms` adds Tidal, SoundCloud, Amazon Music, YouTube as additional rows.

## Why no normalization

Commandment 9: loudness normalization is not mastering. The skill measures; mastering decides. A unity-sum that lands at -18 LUFS-I and ships to a mastering pass is a clean canvas; a unity-sum that has been pre-normalized to -14 has already locked in a creative decision the mastering engineer didn't make. Do not normalize even if the deltas tempt the operator. The deltas are diagnostic, not aspirational.

## Decision triggered

**Phase 4 adds a `report_loudness_deltas` block to `scripts/verify.py`'s output**, surfacing Spotify / Apple Music / EBU R128 by default and the rest behind `--report-all-platforms`. Targets are encoded as a constant table inside `scripts/verify.py` (or `scripts/_loudness_targets.py` if the table grows past a few entries). Phase 1's `scripts/_measure.py` already returns integrated LUFS and true peak from `parse_ebur128_summary`; no new measurement is needed.

The Phase 4 task should also add a one-line `[note]` to plan.py's plan markdown calling out the relevant platform delta the operator should anticipate after their preferred mastering pass.

## Maintenance

Re-verify on platform-policy change, not on a calendar. The 2026 landscape is stable enough that pinning the table at the current values and bumping `last_verified` only when a target moves is the archival-correct move. If Phase 4's implementation hardcodes the table, encode `LAST_VERIFIED = "2026-05-05"` next to it and surface that string in `--report-all-platforms` output so the operator can see how stale the constants are.

## Sources

- [Spotify — Loudness normalization on Spotify](https://support.spotify.com/us/artists/article/loudness-normalization/) (-14 LUFS-I, -1 dBTP / -2 if hotter; Loud -11, Normal -14, Quiet -19).
- [Production Expert — Apple Choose -16 LUFS Loudness Level For Apple Music](https://www.production-expert.com/production-expert-1/apple-choose-16lufs-loudness-level-for-apple-music-heres-why) (Sound Check; AES TD1008 alignment).
- [Sean Kim — Loudness Mastering Streaming Platforms 2026](https://blog.imseankim.com/loudness-mastering-lufs-streaming-platforms-spotify-apple-music-2026/) (cross-platform table).
- [Critical Listening Lab — YouTube Loudness Normalization](https://www.criticallisteninglab.com/en/learn/loudness/youtube) (-14 LUFS-I, attenuate-only).
- [Sage Audio — Mastering for Streaming: Platform Loudness and Normalization Explained](https://www.sageaudio.com/articles/mastering-for-streaming-platform-loudness-and-normalization-explained) (Tidal album-level; SoundCloud -14; Amazon -14 / -2 dBTP).
- [iZotope — How to master for streaming platforms](https://www.izotope.com/en/learn/mastering-for-streaming-platforms) (cross-platform LUFS / TP table).
- EBU R128 / EBU Tech 3343 — Loudness normalisation and permitted maximum level of audio signals.
- ATSC A/85 — Techniques for Establishing and Maintaining Audio Loudness for Digital Television.

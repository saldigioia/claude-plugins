# Production-company portfolios (Simian DAM) — the site's own file is not the master

**A production company's own site is a portfolio, not a DAM.** Its file is a web encode, and it can
be **worse than the public release** in ways a resolution check alone will not catch.

## Surface

A Next.js SSG portfolio puts asset URLs in `__NEXT_DATA__` → `pageProps.project` (`film`, `preview`,
`cover`), also readable without the HTML at
`/_next/data/<buildId>/<locale>/videos/<handle>.json`. Assets sit on a **Simian** (gosimian.com)
portfolio/DAM instance.

**No ladder exists on that host.** Directory listing 403s; every miss — extension swaps
(`.mov`/`.mxf`/`.webm`) and suffixes (`_4K`, `_UHD`, `_2160`, `_Master`, `_ProRes`, `_Original`, …)
— **302s to `/admin_login`.** The three URLs in the CMS record are all there is. All locale domains
serve the identical file.

## The trap — a pillarboxed "1080p"

Measured on one music video: the `film` MP4 is **1920×1080** h264 ~5 Mbps / 114 MB — but
`cropdetect` returns `crop=1620:1080:150:0`. **It is pillarboxed**: the real picture is only
**1620×1080** with 150px of black on each side.

The official YouTube upload carries the same framing un-boxed at **3240×2160** — exactly 2× the
linear resolution, with genuinely resolved detail (individual hair strands, intact grain) where a 2×
Lanczos upscale of the site's file is soft mush.

> **Always `cropdetect` a "1080p" file before calling it the master. A 16:9 container can be hiding
> a 3:2 picture.**

## Ceiling for that title (public)

- **Video** — YouTube fmt `313` VP9 3240×2160 @ 11.8 Mbps (`401` = AV1).
- **Audio** — the Apple Music rip (AAC-LC 265k @ **48 kHz**) beats YouTube's Opus 127k and the
  site's AAC 318k @ 44.1 kHz (a resample). All three share an identical **15.36 kHz** source band
  limit, so bandwidth is a wash and the bitrate/sample-rate chain decides.

## Alignment gotchas (cost several passes)

Apple's file had a 1.000 s silent black lead that YouTube trimmed.

- Video↔video PSNR sweep gives exactly **1.000 s** (25 frames, 37–40 dB, no drift).
- Audio↔audio cross-correlation gives **1.044 s**.
- The 44 ms delta is exactly **2112 samples = AAC encoder priming**, which ffmpeg does not trim on
  decode. **Trust the video measurement for content offset.**

Two failed lossless approaches, both **silent**:

- `-ss` before `-i` with `-c copy` on an MP4 **will not trim ~1 s of audio** — MP4 audio seeks at
  chunk granularity, so it no-ops (a 10 s seek works; a 1 s seek does not).
- ffmpeg then expressed the offset as a **container start-time delay on the video**
  (`start_time=1.045`), which players ignore from t=0 — leaving a full **1044 ms sync error** that
  only appeared when measured **with no `-ss` anywhere.** Never verify sync with a seek on a
  delay-offset stream.

**What worked:** `atrim=start_sample=50112` (1.000 s content + 2112 priming) on the decoded audio →
FLAC (lossless w.r.t. the decode, so no second lossy generation) muxed with the stream-copied VP9
video. Verified 0 frames / 0 samples off.

Note ffmpeg's **mov muxer refuses VP9**, so a QuickTime-playable `.mov` would require a full
re-encode — MKV is the honest container.

Related: [[asa-dts]], [[vimeo]], [[youtube-embeds]].

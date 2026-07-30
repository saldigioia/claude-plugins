# Vimeo — embed-only clips and the download-permission gate

- **Engine:** `app.sh --vimeo` (the former standalone `vimeo.sh` was merged in; Vimeo lives behind
  that flag).

## Lever — pass the unlisted hash

For clips that are **embed-only on a third-party page**, the bare-ID player-config path is
unreliable. The fix is to pass the **unlisted hash** from the iframe `src=…?h=<hash>`:

```bash
bash app.sh --vimeo "https://player.vimeo.com/video/<id>?h=<hash>"
```

No cookies are needed when `embed_permission: public`. Verified live: this recovered a full
**4K UHD 3840×2160 24fps HEVC DASH ladder** from a portfolio page that exposed only an iframe.

## Where the renditions live

In `window.playerConfig` at `player.vimeo.com/video/<id>`:

| field | meaning |
|---|---|
| `request.files.dash` / `hls` | adaptive only; **caps at the source resolution** |
| `request.files.progressive` | often absent |
| `video.download` | `None` + `privacy: disable` ⇒ public/embed download disabled |

## The ProRes / original master is NOT in the embed surface

It is reachable only through the **authenticated** `api.vimeo.com/videos/<id>?fields=download` path
(the `quality: source` entry), and `download[]` is populated **only if your account has download
rights on that clip** — typically the owner. An empty array for a non-owner is a **permission gate,
not a pipeline bug.** Report it as such instead of hunting for a lever.

## Trap

**Signed CDN URLs captured in a HAR expire ~1 hour after capture.** Always re-fetch the player
config live rather than replaying HAR URLs.

## Vimeo as the upstream master

When a locked DAM serves only a web proxy, **the creator's own Vimeo is often the real route** —
see [[asa-dts]], where a 720p agency proxy was beaten 4.7× by the director's own 1440p Vimeo upload,
matched by identical duration, upload date, and an unusual aspect-ratio ladder.

Related: [[youtube-embeds]], [[division-simian]].

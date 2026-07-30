# ASA DAM (`*.asadts.com` / `asa.media`) — talent-agency portfolio video

- **Signature:** streaming/CDN on `*.asadts.com`, thumbnails on `thumbnails.asa.media`. Used by
  talent-agency portfolio sites (Laravel/Inertia + React SPA).

## Surface

Per-film, the Inertia page props (`page.data.film`) carry `video_url` (the streaming proxy),
`loop_video_url` (`FILM_<id>_LOOPx_hd.mp4`), `thumb_url`, and a `download_url`.

**Streaming proxy naming:** `https://dts<NNNN>.asadts.com/_v/2ei/046_MEDIAS/<P>_<H>_<rest>.mp4`,
where a film id like `FILM_944620260310111926` splits into prefix `944` + `_<height>_` +
`620260310111926`.

**Only the 720 height exists** — 360/480/540/1080/1440/2160 all 404. And the 720 file is a
**libx264 web proxy** (948×720, ~2.1 Mbps, `encoder Lavc…libx264`), **not a master.**

Infrastructure: `dts<N>` is the Apache origin; `cdn<N>` is a BunnyCDN pullzone over a Google Cloud
Storage backend (`x-goog-meta-frames` leaks). `_v/2ei/` is the tenant mount.

## Dead end (with disproving evidence)

**`Down_Film_GET.php` never serves the file.** It returns `Content-Length: 0` for any valid id — via
GET, POST, or HEAD, on any host, with any extra params — and a 2-byte `"53"` with no params.
Anti-leech or simply broken.

The `client` md5 in that URL is a **fixed account id, not session-bound**, so token freshness is
irrelevant — there is nothing to refresh your way past.

## The lever is off-platform

**The best findable version is not on ASA at all — it is the artist's own Vimeo.**

Trace it by searching `"<brand> <director> <DOP>"`. One verified case matched on three independent
signals: **identical 66 s duration, the same upload date, and the same unusual aspect-ratio ladder**
(948×720 → 1422×1080 → **1896×1440**, DAR 320:243). Vimeo served up to **1440p "2K"** at 10.6 Mbps —
**4.7× the pixels** of the ASA proxy.

No 4K/source download there either (owner download disabled), and the title was shot on film, so the
true camera master is not public. Record that as the honest ceiling.

> **Lesson:** for agency-portfolio reels behind a locked DAM proxy, the **upstream creator's**
> Vimeo/portfolio is the master route. `yt-dlp -f "bv*[height<=1440]+ba/best"` grabs it.

Related: [[vimeo]], [[division-simian]] (same lesson, opposite direction — there the *public*
release beat the production company's own file).

# YouTube embeds hidden by Squarespace / Embedly

- **Engine:** `youtube_ids_from_html()` + `handle_youtube()`, in the video-intercept stage.

## The failure shape

Squarespace — and any Embedly-based CMS — **never emits a plain
`<iframe src="youtube.com/embed/…">`.** The iframe HTML is stored **HTML-escaped inside a
`data-block-json` attribute**, wrapped in a `cdn.embedly.com/widgets/media.html?src=…` URL.

So the video id appears **only URL-encoded**:

```
youtube.com%2Fembed%2F<id>
watch%3Fv%3D<id>
i.ytimg.com%2Fvi%2F<id>
```

No ordinary extractor matches, the page falls through to the image pipeline, and it dies on "no
valid media format found". **Diagnostic:** grep the page or HAR for `cdn.embedly.com` plus
`%2Fembed%2F` — that combination is this pattern.

## The parser

Match the plain forms (`embed/`, `shorts/`, `live/`, `v/`, `watch?v=`, `youtu.be/`, and
`ytimg.com/vi/` lazyload thumbnails) **and** their `%2F`/`%3F`/`%3D` encoded copies at **one to two
encoding levels**.

**Exclude `videoseries`** — a playlist path token that is, awkwardly, exactly 11 characters of the
id charset and will otherwise match as a false id.

## Honest containers

Use yt-dlp `bestvideo+bestaudio/best` with output template `%(ext)s` and **no
`--merge-output-format`**. VP9/AV1 + opus then lands honestly as `.webm`/`.mkv`, and h264+aac as
`.mp4`. Forcing mp4 would either re-encode or produce a broken mux.

## Ceiling

**YouTube's top DASH rendition is the public ceiling for such pages** — there is no self-hosted
master behind a pure YouTube embed. And per [[division-simian]], YouTube can genuinely **beat** the
site's own encode.

Related: [[vimeo]], [[squarespace]].

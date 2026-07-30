# s.hdnux.com — Hearst Newspapers photo DAM

- **Serves:** SFGate, SF Chronicle, Houston Chronicle, Times Union, and statesman.com (Austin
  American-Statesman, post-acquisition — it runs Hearst's Next.js platform now, not Gannett's).
- **Engine:** `cdn_resolve_hdnux` + a `basename_from_url` stem rule.

## URL anatomy

```
s.hdnux.com/photos/<aa>/<bb>/<cc>/<dd>/<photo_id>/<version>/<rendition>
```

## Lever

**Swap the rendition segment to the fixed name `rawImage.jpg`.** Every named rendition
(`ratio3x4_960.webp`, `square_small.jpg`, `landscape_*`, `NxM.jpg`, …) is a lossy derived
crop/downscale — the page-painted webp measured 118 KB against `rawImage`'s 617 KB (**5.2×**).
`rawImage`'s dimensions match the CMS-declared native width/height exactly.

**Naming gotcha:** every asset shares the same rendition filename, so bare basenames all collide on
`rawImage`. Stem downloads as `hdnux_<photo_id>`.

## Trap

- **Query params are ignored** — identical Content-Length with `?w=99999&q=100`.
- **Unknown rendition names 302 to version 3 of the same path** (`rawImage.png`, `original.jpg`,
  `master.jpg`, an oversize `NxM.jpg`). That is a canonical-version redirect, **not a fallback** —
  only genuinely generated renditions return 200. There is no ladder above `rawImage`.
- The version segment is an edit version, and `rawImage` bytes are version-stable (v3 == v5
  byte-identical). Keep whichever version the page references.
- No Accept-driven webp transcode on `rawImage` (`vary: Fastly-SSL, X-is-eu` only).

## Ceiling

`rawImage.jpg` is **EXIF-stripped** and the DAM **caps ingest at ~2048px long edge** — dozens of
staff photos land at exactly 2048×N. So `rawImage.jpg` *is* the public ceiling; there is no
higher-resolution tier to chase.

## Enumeration surface

Hearst article pages embed `__NEXT_DATA__`. Body image objects live at:

```
props.pageProps.page.zoneSets[].zones[].widgets[].items[].body[].params.image
```

carrying `url` (already `rawImage`), `width`, `height`, and `caption.plain`. The JSON-LD
`pageJsonLds[].image` also uses `rawImage`.

Related: [[arc-xp]] (the other newspaper-CMS resolver, same "page paints a lossy re-encode" family).

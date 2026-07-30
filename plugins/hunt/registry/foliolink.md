# FolioLink — photographer portfolio platform (IIS/ASP)

- **Recognise by:** `GalleryMain.asp`, `Artist.asp?ArtistID=<id>&AKey=<key>`, `Image.asp?ImageID=`,
  `Asset.asp?AssetID=`, `CommonFiles/`, `GBEntryAdd.asp`.

## Lever

The asset tree is **3-tier with a shared stem**:

```
Artists/<artistId>/Images/<stem>.jpg               ← top tier
Artists/<artistId>/Mediums/Medium_<stem>.jpg
Artists/<artistId>/Thumbnails/Thumbnail_<stem>.jpg
```

So a thumbnail URL derives the master by **dropping the `Thumbnail_` / `Medium_` prefix and swapping
the folder.**

## Dead end (with disproving evidence)

`foliolink.com` is still **live** (IIS/10.0) but was **rebuilt** — legacy `/Artists/**` and every
`*.asp` return 404 there. **Old accounts are not recoverable from the platform**, verified against a
known account id. If the photographer's own domain is gone too, the archive is the only route.

## Worked outcomes — two photographer hunts

These are useful as calibration for what "dead" actually means.

**Case A — old FolioLink site and its `video.` subdomain both gone; the domain is now a live
Squarespace rebuild.**
- Enumerate via `sitemap.xml` (`<image:loc>`) **plus** `<page-url>?format=json-pretty` — the JSON
  found **609 assets against the sitemap's 582**. Use both.
- `?format=original` with `Accept: */*` returns a **WebP transcode** — the no-webp Accept is
  mandatory. Ceiling is Squarespace's 2500px upload cap. See [[squarespace]].
- **Proven unrecoverable** via `{"archived_snapshots":{}}`: 12 FolioLink assets and 10 `.mov` films
  on the dead `video.` subdomain. Wayback took the HTML wrappers and **never the media**. That is
  the disproving evidence — record it so nobody re-runs the path.

**Case B — the site was NOT dead at all.** Live WordPress on shared hosting with **both** an open
`/wp-content/uploads/` directory index **and** an open WP REST API. The two surfaces agreed at
exactly 58 originals (`x-wp-total: 58`) — **agreement between two independent enumerations is a
completeness proof**, which is worth more than either count alone.
- But every image is **capped at 1000px on one axis** (the photographer's own export), and **no
  `-scaled.jpg` exists**, which proves nothing over 2560px was ever uploaded. **The origin has no
  master tier.** See [[wordpress-photon-pmc]].
- **Inversion worth remembering:** the pre-2020 galleries deleted from the live server are
  archive-only, and their frames go to **1814px — bigger than the live site.** The archive held the
  better copy.

## Trap

**archive.org rate-limit refusals silently corrupt the `archive.org/wayback/available` check**,
manufacturing false "never archived" verdicts. **Re-verify every negative after exponential
backoff** — doing so took one recovery from 84 assets to 122.

Related: [[squarespace]], [[wordpress-photon-pmc]].

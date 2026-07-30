# WordPress uploads + Jetpack Photon (PMC and any `i0.wp.com` site)

- **Signature:** on-domain `<site>/wp-content/uploads/<YYYY>/<MM>/<name>.jpg`, or the Photon proxy
  `i[0-2].wp.com/<origin>`. Confirmed PMC titles: rollingstone, variety, wwd, indiewire, sheknows.
- **Engine:** `cdn_resolve_pmc` (runs **before** the generic `cdn_resolve_wp_uploads`),
  `is_pmc_photon()`, and the shared `wants_original_accept()` predicate.

## Lever

**Bare upload URL + no params + a non-webp `Accept` header.**

```
Accept: image/png,image/*;q=0.8,*/*;q=0.5     → image/jpeg, full EXIF/IPTC intact
```

The page paints the bare upload URL, but the browser sends `Accept: image/webp`, so Photon
transcodes to a lossy webp at the *same pixel dimensions* (~30% smaller, EXIF stripped). Verified
on the recovered master: Photoshop Software tag, capture DateTime and `Copyright` byline all
survive; `x-cache: HIT`, `server: nginx`, no Photon.

**Adding ANY param re-invokes Photon.** `?w=99999`, `?quality=100`, `?strip=none`, `?crop=`,
`?resize=` all return a smaller re-encoded/stripped file. Bare + no-param + no-webp is the ceiling.

Photon ignores `avif` in that Accept header and serves JPEG, so one header covers this and
[[squarespace]] both.

## Trap

- **No hidden larger original in most cases.** WordPress only creates a `-scaled.jpg` (and keeps
  the true original) when the upload's long edge exceeds 2560px. Check `media_details.original_image`
  in the REST API — **`null` means the bare `<name>.jpg` IS the original upload.** The
  `media_details.sizes` ladder tops out at registered sizes (1600×900 / 2048), all derivatives.
- **Duplicate uploads:** a `<name>-1.jpg` sibling can be byte-identical to `<name>.jpg` (same md5).
  Dedupe by hash before counting "distinct masters".

### Climbing the WP filename ladder (generic `wp_uploads`)

Strip order: `-WxH` → `-e<unix-ts>` → `-scaled` → `-N`.

- **Rank candidates by ladder position, not Content-Length.** WordPress guarantees
  `original ⊇ -scaled ⊇ -WxH`, so the most-stripped stem has the most pixels — but `-scaled` is a
  fresh q82 re-encode that routinely **outweighs** a well-compressed original (3089×2048 @ 432 KB
  vs its own 2560×1697 `-scaled` @ 626 KB). A byte-size tiebreaker returns the downscaled derivative.
- **`-e<unix-ts>`** is WP's image-editor "save as edited" marker. Lineage is guaranteed, but a
  *crop* edit changes aspect ratio (2560×1697 → 1506×1694), so a same-image check would reject it
  and make the strip a permanent no-op. Treat it as a safe candidate: the parent is a superset, so
  climbing returns the uncropped master.

## Enumeration surface

Open WP REST API, no key:

```
/wp-json/wp/v2/posts/<id>
/wp-json/wp/v2/media?parent=<id>&per_page=100      → width/height/file/source_url/original_image
/wp-json/wp/v2/media?search=<term>&per_page=100    → other frames from the same shoot
/wp-json/wp/v2/posts?per_page=100&page=N&search=   → whole-site walk (X-WP-Total header)
```

A `search=` by photographer surname or subject is the cheap way to test whether unpublished frames
exist. On one verified job it surfaced none, proving the published set was the complete public
collection.

## Notes

Untested but very likely the same stack: billboard, THR, deadline, robbreport. Verify before
adding to the host list.

Related: [[squarespace]] (the same no-webp Accept lever), [[arc-xp]] and [[sanity]] (the same
"bare looks full-res but is a lossy re-encode" family), [[playboy]] (a WP site whose editorial
masters live off-site).

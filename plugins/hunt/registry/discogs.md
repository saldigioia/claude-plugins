# i.discogs.com — Discogs (signed imgproxy)

- **Signature:** `https://i.discogs.com/<sig>/rs:fit/g:sm/q:90/h:H/w:W/<payload>.jpeg`
- **Engine:** `cdn_resolve_discogs` + `is_discogs_image_url` (suppresses the probe ladder).

## URL anatomy

`<payload>` is **base64url, unpadded, split every 16 characters**, decoding to
`s3://discogs-database-images/<file>` where `<file>` = `<R|A|L|M>-<id>-<unixts>-<n>.<ext>`
(R = release, A = artist, L = label, M = master).

## Lever

**Re-source a fresh signed URL from the unauthenticated API** — you cannot forge one.

1. Decode the base64url payload → get the prefix letter and numeric id.
2. Map prefix → endpoint: `api.discogs.com/{releases,artists,labels,masters}/<id>`.
3. Return the `images[].uri` whose payload matches. That is the full-size signed URL at stored
   dimensions.

A `User-Agent` header is **required** (~25 req/min). Grep for `"uri":` specifically — `"uri150"`
is the 150px thumbnail and must not match. Stem downloads from the *decoded* filename
(`R-6682162-1424536760-8982`), not the base64 garbage.

Already-full input round-trips as a dispatcher no-op; thumbnails get upgraded.

## Trap

- **The signature covers the whole path.** Bumping `h:`/`w:`, swapping `.jpeg`→`.png`, or
  substituting `unsafe` all return **403**. No rendition can be forged — this is the "signed-params
  resizer" family where neither stripping nor param probing works.
- **Query params are NOT covered by the signature** — they are silently ignored and byte-identical,
  so param probing only manufactures duplicate candidates. Suppress the ladder.
- **Ceiling: Discogs stores every upload at max 600px long edge.** Verified on 2025-era releases
  still at 600×600. The API `uri` **is** the platform maximum; no higher tier exists anywhere.
  Do not go hunting for one.
- **Cloudflare Polish rides on top of imgproxy.** A plain GET returned 116,340 B polished; the
  cache-buster bypass recovers 124,449 B of un-Polished imgproxy output (~7% more real data).
  See [[cloudflare-polish]].

## Enumeration surface

One auth-free API call per entity returns all its images:
`api.discogs.com/{releases,artists,labels,masters}/<id>` → `images[]` with `uri`, `uri150`, and
true `width`/`height`.

Search and paginated discovery require a token — deliberately not wired.

## Dead ends (with disproving evidence)

- `discogs-database-images` S3 bucket → 403 (private).
- `www.discogs.com` release pages → Cloudflare 403 **even with `curl_cffi` chrome**.
- Legacy hosts: raw `img.discogs.com` → 500; `api.discogs.com/images` → 404; `pixogs` → NXDOMAIN.
- Wayback holds nothing for the raw filenames.

Kinship: [[reddit]] — same "signed resizer, re-source via the platform's own surface" shape, except
Reddit's fix is a host swap and Discogs' must come from the API.

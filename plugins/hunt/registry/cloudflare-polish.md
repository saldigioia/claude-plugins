# Cloudflare Polish (lossy) — cache-buster bypass

**Orthogonal lever: combine it with any host-specific rule.** Applies to any Cloudflare zone
running Polish in lossy mode — common on small/mid e-commerce on CF's image-optimisation tier.

## What it does

Polish in **lossy** mode silently re-encodes images at quality 85 when serving from cache. The
recompressed bytes are often **5–8× smaller** than the upload but pixel-equivalent enough that a
casual look sees nothing wrong.

Crucially, **Polish never runs at origin-fetch time** — it is a background job (`cf-bgj: imgq:85`)
that rewrites the *cached* response, and the rewritten copy is what every subsequent HIT gets.

## Detection

HEAD the URL and look for these together:

```
cf-polished: ok, orig_size=2018100     ← Polish ran AND this is the unmodified upload size
cf-bgj: h2pri,imgq:85                  ← lossy mode (not lossless)
cf-cache-status: HIT                   ← Polish only applies on HITs; a MISS is always origin-fresh
```

`orig_size=N` is a **built-in validator**: it tells you exactly how many bytes the master should be
*before* you fetch it.

## Bypass

Append any unique query string the proxy has not seen (`?cfbust=<rand>` / `?v=<rand>`). That changes
the cache key, forces a MISS, and the response comes straight from origin without Polish.

Verified on one campaign host:

| file | polished | busted (MISS) | ratio |
|---|---|---|---|
| A | 241 KB | 2,018,100 B | **8.4×** |
| B | 361 KB | 1,996,996 B | 5.5× |
| C | 476 KB | 2,310,529 B | 4.9× |
| D | 363 KB | 710,072 B | 2.0× |

Busted Content-Length matched the advertised `orig_size` exactly in every case.

## Traps

- **Race condition.** The background job may rewrite the cache entry between your HEAD probe and
  the bulk GET. **Use a fresh bust id per network phase** — one at probe time, a new one at download
  time — so each phase rides its own MISS. Parallel download connections all share one cache key, so
  they either all hit the same origin response or all hit the same poisoned entry; the
  fresh-per-phase rule keeps them on origin.
- **Accept-header tricks do not help.** Polish ignores `Accept`; the cache key is URL + query, not
  headers. Cache-busting is the only reliable lever short of an admin-level Polish disable.
- Polish can ride **on top of** another transform layer — see [[discogs]], where busting recovered
  ~7% more real data from the imgproxy output underneath.
- It can also defeat a no-webp `Accept`: one legacy commerce host returned `image/webp` 28,336 B
  *regardless of Accept*, and only `?cfbust=` produced the original `image/jpeg` 47,387 B. See
  [[pacsun-sfcc-scene7]].

## Where to hook it

When any HEAD-style probe sees `cf-polished: ok` on a cache HIT, retry with a fresh bust query, then
validate that the retry has **no** `cf-polished` header **and** a Content-Length equal to the parsed
`orig_size`. Mark the URL as needing bypass and regenerate a fresh bust at download time.

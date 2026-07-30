# Dotdash Meredith / "People Inc" — signed Thumbor `/thmb/`

- **Signature:**
  `www.<brand>.com/thmb/<hmac-sig>=/<WxH>/filters:no_upscale():max_bytes(N):strip_icc()[:focal(…)]:format(webp)/<slug>-<32hex-guid>.jpg`
- **Brands sharing the CMS:** instyle.com, people.com, byrdie.com, verywell*.com, bhg.com,
  foodandwine.com, travelandleisure.com, realsimple.com, …
- **Status:** **no resolver — the master is unreachable, so there is no rewrite that beats the page
  URL.** The engine already downloads the signed rendition correctly.

## The wall

**The Thumbor signature is HMAC-SHA1 over the ENTIRE path after `/thmb/`.** Any change to
geometry, filters, `max_bytes`, or format → **HTTP 400** (verified). `unsafe` mode is off
(`/thmb/unsafe/…` → 400; `/unsafe/…` → 404).

So you **cannot forge** a larger geometry or a non-webp/uncapped rendition. Each
(geometry, filters, file) combination the CMS emits has its own precomputed signature, and the page
carries only the renditions it needs.

## What the ceiling actually is

**The true master is the `<img width= height=>` attribute — the source upload dimensions** (7000×9333,
8349×5273, 8000×6001 camera originals are typical). Thumbor delivers at most what the publisher
signed:

- typically **3000x0** for feature/body images,
- but only **1500x0** (or 750x0) for some — and those images have **no 3000x0 signature anywhere
  public**. AMP (`?amp=1`) carries the same geometries; an `/amp` suffix 404s. **That degraded
  ceiling is final for those images.**

Delivered format is lossy webp under `max_bytes()` (which is not strictly enforced — a 3000px file
can exceed the stated cap).

## Where the masters live (all private for modern assets)

- Modern hashed-filename editorial assets (`<slug>-<32hex>.jpg`) are **never linked publicly** —
  Wayback only ever captured `/thmb/` URLs, never a raw origin.
- **`static.onecms.io/wp-content/uploads/sites/<N>/<YYYY>/<MM>/<DD>/<file>` serves LEGACY assets
  publicly** (one brand is site 14; verified 200 on a 2013 cover). Modern (2024+) dropped the
  `sites/N/` segment, but only marketing/sweepstakes imagery lives there — **hashed editorial
  masters do not.**
- **`imagesvc.meredithcorp.io/v3/mm/image?url=<origin>&q=100&w=10000`** is a legacy image proxy with
  an **origin allowlist**:
  - arbitrary host → `{"msg":"…url is not allowed"}`
  - allowlisted host + upstream miss → `{"ProbeError: bad status code"}`
  - allowlisted + found → **serves the image UNCAPPED** (delivered a 2013 cover at full res via
    `w=10000`).
  It is useless for modern masters **only because you cannot construct the origin URL** — if you
  ever recover a modern onecms path, this proxy will deliver it uncapped. Worth remembering.

## Trap

**Blind brute-forcing gives no gradient.** Every guessed onecms path returns **500** (a Cloudflare
error page is this host's 404-equivalent) — `static.onecms.io` 500s for *any* missing file, so you
cannot distinguish "wrong date" from "wrong scheme". Don't run the sweep.

## Access wall

The article HTML is behind a **Cloudflare managed challenge** — plain curl/aria2c get a 403 "Just a
moment" interstitial; `curl_cffi --impersonate chrome` clears it. The `/thmb/` image host itself
does **not** challenge. See [[waf-and-bot-walls]].

## Enumeration surface

Parse all `/thmb/…/<slug>-<hash>.jpg` URLs from the article HTML, keeping the **maximum geometry
per file**. There is no public REST/GROQ API (`/wp-json/` 404s — it is a custom CMS, not exposed
WP). Syndication RSS at `feeds-api.dotdashmeredith.com/v1/rss/google/<uuid>` lists other posts but
still only `/thmb/` URLs.

Related: [[cims-camart]] (the other honest "public tier is the ceiling, master is walled" case).

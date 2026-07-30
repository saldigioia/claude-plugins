# Fourthwall — creator storefronts, `imgproxy.fourthwall.com`

- **Hosts:** `imgproxy.fourthwall.com/…`
- **Engine:** no resolver yet. `cdn_resolve_generic` handles it; the ladder below is
  **unverified** — see Open questions.
- **Detection:** `imgproxy.fourthwall.com` in page HTML; checkout subdomains are a second signal.

## Lever

The host name is the tell: **[imgproxy](https://imgproxy.net/) is a known open-source transform
proxy**, and its URL grammar is `/<signature>/<processing-options>/<encoded-source-url>`. Where
the source URL is plain- or base64-encoded rather than signed-opaque, the origin asset can be
read straight out of the path — which is the whole ballgame, since the origin is not
Fourthwall's resizer.

**Verify before believing it.** A signed deployment (`FOURTHWALL`-side `IMGPROXY_KEY`) makes the
path opaque and the source unrecoverable, and imgproxy's `/unsafe/` prefix is only accepted when
the deployment explicitly allows unsigned URLs. Decode what you have; do not assume the shape.

## Trap — slugs do not match across platforms

Sites migrate. Fourthwall slugs frequently need matching back to Shopify or Swell slugs **by
product name**, not by slug string. Joining on slug alone silently splits one product into two
records across eras.

## Enumeration surface

The Fourthwall API. No open directory listing on `imgproxy.fourthwall.com` has been confirmed.

## Open questions (unverified — do not assume)

- Whether Fourthwall signs its imgproxy URLs, and if so whether any tenant leaves them unsigned.
- Whether a processing-options segment can be stripped or replaced (imgproxy's own
  `/rs:fit:0:0/` no-op form) to obtain the unresized source.
- Whether the CDN outlives a closed storefront (see [[dead-shopify-storefronts]]).
  **Confirm per store; record the negative with its evidence.**

Once verified, promote the transform to `cdn_resolve_fourthwall()` in `tools/cdn/app.sh` with
fixtures in `tools/cdn/tests/run.sh`.

## Pipeline

The `wayback-archive` plugin ships a Fourthwall config template and handles the catalog end to
end; its `references/platform-support.md` owns the template/stage mapping. This entry owns the
lever and the traps.

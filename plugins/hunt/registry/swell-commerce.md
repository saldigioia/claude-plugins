# Swell Commerce — SvelteKit storefronts, `cdn.swell.store`

- **Hosts:** `cdn.swell.store/{store-id}/…`
- **Engine:** no resolver yet. `cdn_resolve_generic` handles it; the transform ladder below is
  **unverified** — see Open questions.
- **Detection:** `cdn.swell.store` in page HTML, plus `__data.json` and SvelteKit markers.

## Lever

**`__data.json` is the enumeration surface.** SvelteKit serves structured product data at
`__data.json` endpoints alongside each route. This is the catalog, and it survives in Wayback
captures where the rendered HTML does not.

## Trap — `__data.json` is not plain JSON

It is [`devalue`](https://github.com/Rich-Harris/devalue)-encoded: a flat array where values
reference other array indices by integer. **Manual flat-array parsing breaks on nested refs** and
will silently yield wrong or partial products rather than erroring. Parse it with the `devalue`
library, not `JSON.parse` plus hope.

## Trap — `-blank` slug variants

Products carry variant slugs such as `ts-01-black-blank` alongside the canonical `ts-01-black`.
Treated as distinct products, they inflate the catalog with duplicates; dropped blindly, they can
take the only surviving capture with them. Match to the canonical slug, keep the union of images.

## Enumeration surface

`__data.json` per route. No open directory listing on `cdn.swell.store` has been confirmed.

## Open questions (unverified — do not assume)

- Whether `cdn.swell.store` accepts size/format params, and whether stripping them yields the
  upload byte-for-byte. Nothing in the record confirms a transform layer either way.
- Whether the CDN outlives a closed storefront the way Shopify's does
  (see [[dead-shopify-storefronts]]). **Confirm per store; record the negative with its evidence.**

Once a string transform here is verified, promote it to `cdn_resolve_swell()` in
`tools/cdn/app.sh` with fixtures in `tools/cdn/tests/run.sh`.

## Pipeline

The `wayback-archive` plugin ships a Swell config template and handles the catalog end to end;
its `references/platform-support.md` owns the template/stage mapping. This entry owns the lever
and the traps.

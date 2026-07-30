# secondname.agency — portfolio CMS on Linode Object Storage

- **Signature:** images on `<tenant>.us-east-1.linodeobjects.com`, page is a Handlebars/jQuery SPA.
- **Engine:** `cdn_resolve_secondname`.

## Lever

**Strip the `/c/` cache segment AND the content hash:**

```
/media/c/i/<path>/<base>.<12hex-hash>.jpg   →   /media/i/<path>/<base>.jpg
```

That is the original upload. Its pixel dimensions match the feed's `width`/`height` fields exactly.

## Trap

Each image exposes three **resized** renditions under `/media/c/i/…`:

| key | size |
|---|---|
| `ssd_p` | small (320px tall) |
| `smd_p` | medium (800px tall) |
| `sld_p` | large (1800px tall) — **often an UPSCALE, not the master** |

For a small upload (e.g. 1274×800) the CMS upscales `sld_p` to 2867×1800 — fake interpolated
detail that beats the honest original on size. **The `/media/i/` original is the ceiling
regardless**; for genuinely large uploads (4032×2881) it dwarfs every rendition.

## Enumeration surface

**Image URLs are not in the HTML.** They come from a JSON feed at `/<viewtype>/<id>/` — story pages
use `/newsquickview/<id>/`, discoverable from the hidden field
`<input class="jsonUrl" value="…">`.

## Dead ends

Bucket `ListBucket` is `AccessDenied`; `/media/o/`, `/media/c/o/`, and bare `/media/` all 403.
**`/media/i/` is the only original path.**

Related: [[therealreal]] (same upscale-trap lesson), [[yesstud]] (another portfolio object store).

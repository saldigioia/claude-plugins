# RebelMouse — `*/media-library/…?id=N` → `assets.rbl.ms`

- **Signature:** path-keyed and **hostname-agnostic** — `*/media-library/<basename>.<ext>?id=<N>`
  is used by every RebelMouse-hosted publication (papermag, indy100, okayplayer, theweek, …).
- **Engine:** `cdn_resolve_rebelmouse` + the **P2 transcode rule**.

## Lever

```
<any-host>/media-library/<basename>.<ext>?id=<N>  →  https://assets.rbl.ms/<N>/origin.<ext>
```

The bucket holds **one file per id at the original upload format**, and the proxy URL's extension
reliably mirrors it (`image.png?id=…` ⇒ a PNG upload; `image.jpg?id=…` ⇒ a JPEG upload). Bare S3
access on `assets.rbl.ms` is public, no auth.

## Trap — the proxy default is LARGER than the source

This is the **inverse** of [[akamai-image-manager]], and it breaks the usual heuristic.

| | bytes | note |
|---|---|---|
| proxy default `image.jpg?id=N` | ~473 KB | silent re-encode at a *higher* JPEG quality |
| `assets.rbl.ms/N/origin.jpg` | ~436 KB | **the actual source upload** |
| proxy `&quality=100` | ~1.26 MB | ~3× source, still zero added information |

The proxy output is pixel-equivalent (**PSNR 56 dB**) but inflated. A naive "same format, larger =
better" size tiebreaker picks the bloat every time.

**Fix — the P2 same-format bloat rule:** in the post-selection transcode block, when the winner is
the pre-resolution original `O`, has the *same* format priority as the resolved baseline, **and**
the same dimensions as the baseline, demote it so the resolved-URL candidate wins on re-select.

The rule is generic: any proxy whose default output is a bloated re-encode of the resolved source
triggers it.

## Why this matters beyond RebelMouse

The prior architecture assumed "same format, larger = better" because that holds for the Akamai IM
family, where the source is stored behind a special path and the bare URL is the lossy one.
RebelMouse inverts it. **When adding any new resolver, check which direction the asymmetry runs:**

- proxy default **larger** than the resolved source → P2 handles it
- proxy default **smaller** than the resolved source → the ordinary size tiebreaker handles it

This asymmetry is invisible until you hit a counter-example, which is why it is written down.

Related: [[akamai-image-manager]], [[cloudinary]] (bloat traps of a different shape).

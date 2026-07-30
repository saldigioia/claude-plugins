# cdn.bfldr.com — Brandfolder DAM

- **Signature:** `cdn.bfldr.com/<TENANT>/at/<assethash>/<filename>.<ext>` — general across many
  brands.
- **Status:** manual (not wired into the engine).

## Lever

**Strip ALL query params.** The bare URL is the byte-honest full-res master.

Measured on a 5255×3934 asset:

| form | result |
|---|---|
| **bare** | **11.6 MB `image/jpeg` at native dims — the master** |
| `?auto=webp` (what pages paint) | 2.8 MB same-dims lossy re-encode (~4× smaller) |
| `?format=png` | 25.8 MB PNG **wrapping the same JPEG pixels** — wrapper-bloat trap |
| `?width=10000` | does **not** upscale (clamps to source) but routes through the optimised/lossy path, returning the 2.8 MB webp-path size |

So neither `format=png` nor an oversize `width` is a master lever here — only stripping.

## Trap

`?format=png` on an already-JPEG source is the familiar lossless-wrapper trap: it wins on **both**
format priority *and* size while adding zero fidelity. Same family as Cloudinary `f_tiff` and the
Sanity/SKIMS `fm=png` case.

`?width=N` clamping is a red herring — clamping proves it is not upscaling, but the response still
comes from the optimised path, so "it clamped" does not mean "it is the original".

The filename frequently carries `full_res` verbatim, which is a naming convention, **not** proof
that the bytes you received are the full-res original. Verify by comparing bare against what the
page painted.

Seen as a **secondary DAM** alongside a primary CMS — one site served most imagery from Sanity and
a subset of project/property photos from Brandfolder. When a site's images come from two hosts, run
the master rule for each independently. See [[sanity]].

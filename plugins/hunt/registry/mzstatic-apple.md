# mzstatic.com — Apple Music / iTunes artwork

- **Signature:** `is{N}-ssl.mzstatic.com/image/thumb/<PATH>/<SPEC>` (public resizer) and
  `a{N}.mzstatic.com/<cc>/r{N}/<part>/<PATH>/<file>` (legacy origin).
- **Engine:** `cdn_resolve_mzstatic` + the `extract_apple_artwork` page intercept.

## Lever

**Rewrite the spec segment to `10000x10000.png`.** The resizer clamps to the source (never
upscales) and re-encodes losslessly to PNG.

- `10000` is accepted; `20000` → HTTP 400. So `10000x10000.png` is the max-safe lossless spec.
- The three fit modes `10000x10000` / `10000x0w` / `10000x10000bb` return byte-identical output
  once clamped (9,639,083 B for a 2003×2003 source). Bare `10000x10000` never pads — use it.
- A **legacy URL with a real filename** resolves by stripping the `<cc>/r{N}/<part>/` prefix; the
  remaining `<PATH>/<file>` is the resizer's path key (verified 403 → 200).

Spec grammar: `{w}x{h}[crop][-quality].{fmt}`, e.g. `600x600bb.jpg`, `10000x0w-999.png`.

## Trap

- **The legacy origin `a{N}.mzstatic.com` hard-403s every public request, even with a browser
  UA** — only Apple clients carry the token. Route everything to the resizer instead.
- **A bare `a{N}…/source` alias is not recoverable**: the resizer has no `source` key (404) and
  the real filename is not derivable from that URL. Feed the named or thumb form instead.
- **Basename collision.** Every asset resolves to the same synthetic spec segment, so naming
  downloads after the URL's last path component collides them all on `10000x10000.png`. Stem from
  the real asset filename instead.
- Do **not** try `?impolicy=` or format params — mzstatic is its own resizer, not
  [[akamai-image-manager]].

## Enumeration surface — Apple Music pages

Given a `music.apple.com` / `itunes.apple.com` URL (album, song, artist, playlist, music-video),
fetch the HTML and read the **`og:image` meta tag**. It carries the canonical artwork asset path
(album `Music*/…/<id>.rgb.jpg`, artist `AMCArtistImages*/…/ami-identity-*.png`), which then flows
into the resolver — which discards the small cropped social-card spec (`1200x630wp` album /
`1200x630cw` artist) and pulls the full uncropped master.

Verified ceilings: **album → 3000×3000**, **artist → 5998×5998**.

**`og:image` beats the iTunes Lookup API.** `itunes.apple.com/lookup?id=N` returns artwork for
collections and tracks but **not for artists**, so `og:image` is the single tokenless code path
covering every entity type. The cropped `og:image` and the Lookup URL point at the same underlying
asset — the spec is only a transform; the path identifies the source.

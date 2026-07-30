# registry — per-host lore

One file per host, CDN, or platform family. This is where a cracked host is written down so the
next hunt is a lookup instead of a re-derivation.

Knowledge lives in three places, and they are not interchangeable:

| Where | What it holds | When it's used |
|---|---|---|
| `tools/cdn/app.sh` | executable resolvers — 48 host-specific + a generic fallback | automatic, runs first |
| `skills/master-image-hunt/CDN_TABLE.md` | one-line-per-CDN index of lever + trap | when a host looks familiar |
| **this directory** | full findings: lever, trap, enumeration surface, dead ends | when the one-liner isn't enough, or the host isn't wired |

`CDN_TABLE.md` cites `project_*_resolver` memory files. Those are personal auto-memory on one
machine and **do not travel with the plugin** — this directory is the portable equivalent.

## Index

### Image CDNs and CMS delivery

| Entry | Lever in one line |
|---|---|
| [sanity](sanity.md) | Decide bare vs `?q=100` per dataset; 8192px hard cap; open GROQ enumeration |
| [cloudinary](cloudinary.md) | Strip transform, then `fl_getinfo` to prove bare == `input.bytes`; `.tif`/`.png` are wrapper traps |
| [imgix](imgix.md) | Strip params; try `<source>.imgix.net` when the consumer host is locked; `fm=json` is the oracle |
| [substack](substack.md) | Peel the Cloudinary fetch proxy to the public S3 origin — the "false TIF" trap |
| [wordpress-photon-pmc](wordpress-photon-pmc.md) | Bare upload + **no params** + non-webp `Accept`; any param re-invokes Photon |
| [akamai-image-manager](akamai-image-manager.md) | `?impolicy=original` (NOT `?imformat=png`, which is silently ignored) |
| [squarespace](squarespace.md) | Format is decided by `Accept` alone; `?format=raw` is a 100w thumbnail trap |
| [arc-xp](arc-xp.md) | CloudFront origin, or resizer `width`≥source; the page default is a same-dims lossy re-encode |
| [hdnux-hearst](hdnux-hearst.md) | Swap the rendition to `rawImage.jpg`; ~2048px ingest cap is the ceiling |
| [rebelmouse](rebelmouse.md) | `→ assets.rbl.ms/<N>/origin.<ext>`; **proxy default is BLOATED**, the inverse asymmetry |
| [goat](goat.md) | Strip transform/prefix/sub-size to `original`; cold-cache HEAD returns a fake 404 |
| [mzstatic-apple](mzstatic-apple.md) | Rewrite the spec to `10000x10000.png` (clamps, lossless); `og:image` for page discovery |
| [discogs](discogs.md) | Signature covers the whole path — re-source `images[].uri` from the unauth API; 600px ceiling |
| [reddit](reddit.md) | Host-swap `preview.redd.it` → `i.redd.it`; content gate is IP-level, impersonation is useless |
| [fbsbx-meta](fbsbx-meta.md) | `transcode_extension=png` is the lossless master; `jpg` is a ~30 dB trap |
| [hypebeast](hypebeast.md) | Editorial caps at 1200px; the HBX shop's S3 is open and better than the proxy |
| [therealreal](therealreal.md) | Bare only — Fastly IO **upscales**, and its 7130px ceiling is a mirage |
| [brandfolder](brandfolder.md) | Strip all params; `?format=png` is a 25.8 MB wrapper of the same JPEG |
| [themaven-arena](themaven-arena.md) | Bare is the ceiling; strict-transform mode 404s everything else |
| [dotdash-onecms-thumbor](dotdash-onecms-thumbor.md) | Signed Thumbor — **cannot be forged**; the page rendition is the ceiling |
| [cims-camart](cims-camart.md) | `_PREVIEW` is the public ceiling; `_download` master is ACL-403 |
| [secondname-agency](secondname-agency.md) | Strip `/c/` + content hash → `/media/i/`; `sld_p` large is often an upscale |
| [yesstud](yesstud.md) | Fetch both `/image/` and the `h1440` cache key, keep the larger |
| [cloudflare-polish](cloudflare-polish.md) | `?cfbust=<rand>` forces a MISS; `orig_size=N` validates the result |
| [waf-and-bot-walls](waf-and-bot-walls.md) | Which bypass fits which wall — and when impersonation is the wrong tool |

### Commerce and marketplaces

| Entry | Lever in one line |
|---|---|
| [reseller-marketplaces](reseller-marketplaces.md) | Etsy `il_fullxfull` · Grailed bare · Depop `P0` · eBay `s-l1600` · Fril `/l/` |
| [skims-shopify](skims-shopify.md) | Bare (optimised uploads); Storefront GraphQL + Sanity GROQ are two separate layers |
| [gap](gap.md) | `?impolicy=original` on the Akamai host; the Cortex `/d/` assets are NOT the campaign photos |
| [pacsun-sfcc-scene7](pacsun-sfcc-scene7.md) | SFCC content library survives deploys; Scene7 403 vs `exists=0` discriminator |
| [dead-shopify-storefronts](dead-shopify-storefronts.md) | Probe the CDN, not the storefront — but confirm per store |

### Portfolios and DAMs

| Entry | Lever in one line |
|---|---|
| [format-cms](format-cms.md) | The page URL **is** the feed API via `?start_index&limit`; `data-media` carries the master |
| [foliolink](foliolink.md) | Drop `Thumbnail_`/`Medium_` and swap the folder; platform rebuilt, old accounts gone |
| [radicalmedia](radicalmedia.md) | Page embeds 12h presigned URLs; the download button gives a *worse* rendition |
| [asa-dts](asa-dts.md) | The DAM only has a 720p proxy — the master is the artist's own Vimeo |
| [division-simian](division-simian.md) | **`cropdetect` before believing "1080p"** — a 16:9 box can hide a 3:2 picture |

### Digital editions and flipbooks

| Entry | Lever in one line |
|---|---|
| [pugpig](pugpig.md) | The sibling PDF embeds a 300 dpi master — but the JPG and PDF hashes differ |
| [3dissue](3dissue.md) | `files/pages/large/` is the flipbook ceiling — **check for a print PDF first** |
| [emagazines](emagazines.md) | hires master = `base32(md5(thumbnail))`; the token gates only the manifest |
| [playboy](playboy.md) | Four layers, four ceilings; the centerfold has a much better public master |

### Video

| Entry | Lever in one line |
|---|---|
| [vimeo](vimeo.md) | Pass `?h=<hash>` from the iframe; ProRes is a permission gate, not a bug |
| [youtube-embeds](youtube-embeds.md) | Embedly hides the id URL-encoded inside `data-block-json` |

## Entry format

`scripts/recon.sh` drops a pre-filled `registry-stub.md` in its output directory. Fill in the prose
sections and move it here under the host's name.

```markdown
# <host, domain, or platform family>

- **Signature:** how to recognise it in a URL, a HAR, or a response header
- **Engine:** the resolver that handles it, or "manual" if it isn't wired

## Lever
The exact move that yields the master. A URL form, a header, an API path, an open index.
Concrete enough to paste.

## Trap
What looked right and wasn't — fake-200, upscale, lossless wrapper, bloat re-encode,
signed-path, cold-cache HEAD lie, deleted-but-archived.

## Enumeration surface
The API, feed, or index that lists everything.

## Dead ends (with disproving evidence)
What was tried and confirmed unrecoverable, plus the evidence that proves it.
```

A dead-site recon entry uses the same shape with a status header instead
(`LIVE | PARKED | REDIRECTED | SPA | DEAD`, recon date, live hosts, SPA catch-all, Wayback counts).

## Rules

1. **The trap section is not optional.** A lever without its trap is how a lossy re-encode gets
   filed as a master. If you didn't hit a trap, say what you ruled out and how.
2. **Dead ends need disproving evidence**, not an impression. `{"archived_snapshots":{}}` from
   `archive.org/wayback/available` is the only authoritative "never archived" — and note that
   archive.org rate-limit refusals *manufacture false negatives*, so re-verify after backoff.
   Recording a proven-dead path is as valuable as recording a live one.
3. **Record the ceiling honestly.** If the true original is unreachable — a source above Sanity's
   8192px cap, an ACL-gated `_download`, a stopped DAM app — write that down so nobody chases an
   `originals/` directory that never existed.
4. **If the lever is a pure string transform, promote it to code.** A `cdn_resolve_<name>()` in
   `tools/cdn/app.sh` runs automatically forever; a note here is read only when someone thinks to
   look. Keep the note for the trap and the enumeration surface, and add the resolver — ordered
   more-specific-before-generic, with fixtures in `tools/cdn/tests/run.sh`.
5. **One file per host, named after the host** — or per family when a single lever covers several
   (`akamai-image-manager.md`, `reseller-marketplaces.md`). Never a generic name like `notes.md`.
6. **No credentials.** Describe where a client-exposed token lives (site JS, a response header) and
   its shape. Don't paste the value — this is a public repo, and the value rotates anyway.

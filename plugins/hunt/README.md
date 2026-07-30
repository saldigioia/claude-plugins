# hunt

Claude Code plugin for two adjacent recovery problems:

- **Find the master.** Given a URL, a page, or a `.har`, recover the byte-exact
  highest-fidelity original hiding behind a CDN/CMS transform.
- **Rob the grave.** Given a dead, defunct, parked, redirected, or archive-only site, find what
  is still alive and where, then extract it exhaustively.

They share one premise: **more bytes is not more picture, and a 404 is not proof of absence.**
Most of what this plugin knows is a catalog of ways a candidate wins on size or format priority
while carrying *fewer real pixels*, and ways a dead end turns out to be a locked door.

## Install

```
/plugin marketplace add saldigioia/claude-plugins
/plugin install hunt@rare-data-club
```

Local development:

```bash
claude --plugin-dir ./plugins/hunt
```

**Requirements:** `curl`, `dig`. **Strongly recommended:** `aria2c` (parallel downloads),
`python3` (Vimeo JWT, crt.sh and CommonCrawl parsing, autoindex parsing), `jq` (HAR triage).
**Optional:** `yt-dlp` + `ffmpeg` (HLS video, PSNR comparison), `exiftool` (provenance),
`curl_cffi` (TLS-fingerprint bypass on WAF'd hosts), ImageMagick `identify`.

Nothing here is required for the skills to give correct guidance; missing tools degrade specific
probes, and the recon script reports what it skipped rather than failing silently.

## Commands

| Command | Does |
|---|---|
| `/hunt:master <url \| file.har>` | Resolve a URL to its master. Runs the engine, checks the trap catalog, verifies dimensions and pixel identity. |
| `/hunt:recon <domain>` | Phase-1 recon on a dead site: what is alive, where, and which recovery branch to run. Read-only. |

## Skills

Both auto-trigger on the relevant request; you don't have to invoke them by name.

- **`master-image-hunt`** — the procedure and trap catalog for CDN/CMS master recovery. A
  10-step ladder (peel proxy → public bucket → strip params → clamp-vs-upscale → named policy →
  non-webp `Accept` → format ladder → sub-size promotion → suffix strip → TLS bypass), the
  counterintuitive failure modes, verification, and backend-API enumeration per CMS.
  `CDN_TABLE.md` alongside it is the one-line-per-host index of lever + trap.
- **`dead-site-treasure-hunt`** — the triage tree. "Dead" is a spectrum, and the state dictates
  the road: six recon probes, then Branch A (origin alive) / B (SPA + live CMS backend) /
  C (archive only) / D (open cloud bucket), then exhaustive extraction and verification.
  `FIELD_KIT.md` alongside it is copy-paste commands for every step.

## What's in the box

```
tools/cdn/app.sh          the engine — 48 host resolvers + a generic fallback
tools/cdn/tests/run.sh    128 offline unit tests (no network); run before any resolver change
scripts/recon.sh          Phase-1 recon: six probes → dossier → branch routing
registry/                 41 per-host lore entries — lever, trap, enumeration surface, dead ends
skills/                   the two playbooks
commands/                 the two entry points
```

### The registry

`registry/README.md` is an indexed table of 41 entries covering image CDNs and CMS delivery
(Sanity, Cloudinary, imgix, Substack, Photon/WordPress, Akamai Image Manager, Squarespace, Arc XP,
Hearst, RebelMouse, GOAT, mzstatic, Discogs, Reddit, Meta, Hypebeast, TheRealReal, Brandfolder,
Thumbor, …), commerce and marketplaces, portfolios and DAMs, digital-edition flipbooks, and video.

Each entry carries the **lever**, the **trap**, the **enumeration surface**, and the **dead ends
with their disproving evidence** — so a proven-dead path is never re-run and an ACL-gated or
over-cap master is reported honestly instead of chased. Two orthogonal entries,
`cloudflare-polish` and `waf-and-bot-walls`, combine with any host rule.

Read it when a host looks familiar and `CDN_TABLE.md`'s one-liner isn't enough, or when the host
isn't wired into the engine at all.

### The engine

`tools/cdn/app.sh` is a self-contained bash pipeline. Run it directly:

```bash
bash tools/cdn/app.sh -o ./out '<url>'          # resolve + download the best version
bash tools/cdn/app.sh --no-cdn '<url>'          # skip resolution, see the raw baseline
bash tools/cdn/app.sh -c cookies.txt '<url>'    # paywalled / authenticated
PROBE_DELAY=1 bash tools/cdn/app.sh '<url>'     # rate-limit a fragile host
bash tools/cdn/app.sh -c cookies.txt --vimeo <id|url>
```

Read its log: `CDN resolved → …` names the resolver that fired, `BEST → FMT (size)` is the
winner. Selection is lowest format-priority, then largest `Content-Length`, with a ≥4× size
dominance override — and a transcode detector that demotes a same-dimensions candidate that
gained bytes without gaining information.

Known hosts include imgix (generic + Bustle/BDG custom domain), Cloudinary, Sanity, Photon/PMC,
Substack, mzstatic/Apple Music, StockX, GOAT, Etsy, eBay, Depop, Grailed, TheRealReal, Discogs,
Reddit, Squarespace, Akamai Image Manager (NBC/FWRD/Revolve), Arc XP, Hearst hdnux, RebelMouse,
Hypebeast, Next.js/Netlify/Cloudflare image proxies, Thumbor, Shopify, Contentful, Storyblok,
Uploadcare, Fastly, Bunny, Sirv, Tumblr, Flickr, Imgur, Cargo, Format.

### Recon

```bash
bash scripts/recon.sh [options] <domain>

  -o DIR   output directory (default ./recon-<domain>)
  -H HOST  pin the liveness target
  -p FILE  extra candidate paths
  -d SECS  delay between liveness probes (default 0.3)
  --no-archive / --no-liveness / --no-third-party
```

Six probes — DNS triage across 40 subdomains, front-door classification, certificate
transparency, reverse-IP, Wayback CDX census, CommonCrawl — plus the four-way liveness read.
Third-party lookups run concurrently because they hit different hosts; the origin gets a single
serialized queue, because a fragile legacy box answers *empty* rather than 429 under
concurrency, which corrupts enumeration without ever erroring.

Writes `RECON.md` (classification, live-host map, liveness read, archived path inventory,
branch routing), the raw output of every probe, and a `registry-stub.md` to fill in. It
downloads no assets — this phase only builds the map.

## The two ideas worth internalizing

**1. The archive is a map. The origin is the treasure. They are usually disjoint.**

The record shows what was linked and crawled; crawlers grab HTML and skip deep asset trees. The
origin may still hold assets nothing ever linked — and may be missing what the record kept. So
"404 in Wayback" is not "gone", and a live directory the archive never saw cannot be enumerated
by any archive query. The cross-reference between the two lists is the highest-value move in a
dead-site hunt, and no single probe produces it for you.

**2. Every trap is "bigger and/or better-format but not more real pixels."**

| Trap | Looks like | Actually |
|---|---|---|
| False full-res transcode | full-res `.tif` | lossy webp at the source's own dimensions |
| Upscale | a 7000px master | Lanczos-interpolated fake detail |
| Lossless wrapper | `f_tiff` / `fm=png` | a JPEG in a lossless container, zero fidelity gained |
| Bloat re-encode | 3× the bytes | pixel-identical (PSNR >50 dB) |
| Cold-cache HEAD lie | `404`, 118 bytes | GET serves the real asset |
| SPA catch-all | `200` on a deep path | the app shell, for literally any path |
| Wildcard DNS | 30 live subdomains | one wildcard record answering everything |
| Over-cap original | an 8192px "master" | the true original is above the CDN's cap and unreachable |

Which is why the rule is: verify before believing. Magic bytes over file extensions, real pixel
dimensions over `Content-Length`, PSNR when two candidates share dimensions (>50 dB means same
picture — keep the smaller honest one), ranged reads over downloads, and
`{"archived_snapshots":{}}` as the only authoritative "never archived".

## Conventions

- **Report the ceiling honestly.** When the true original is unreachable, name the best
  obtainable rendition and say so. Never imply you got the master.
- **Document dead ends with disproving evidence.** A proven-dead path recorded is as valuable as
  a live one found; it stops the next hunt re-running it.
- **Scope discipline.** Resolve what was handed to you. Enumerating a host's whole collection is
  a separate, larger job — offer it, don't auto-run it.
- **Promote levers to code.** A pure string transform belongs in `app.sh` as
  `cdn_resolve_<name>()`, ordered more-specific-before-generic, with fixtures added to
  `tools/cdn/tests/run.sh`. Run `bash tools/cdn/tests/run.sh` (expect all pass), `shellcheck`,
  and `bash -n app.sh` before committing. Notes in `registry/` are for the trap and the
  enumeration surface — things code can't carry.

## Legality and scope

This recovers material from hosts that serve it, using ordinary HTTP requests and public
archives — no authentication bypass, no credential attacks, no exploitation. Rate-limiting
politeness is built in and enforced by default. What you may *do* with recovered material is a
copyright question this plugin does not answer: it produces provenance records (`CITATIONS.md`,
`manifest.csv` with SHA-256) precisely so the question can be answered later.

## License

MIT

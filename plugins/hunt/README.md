# hunt

Claude Code plugin for two adjacent recovery problems:

- **Find the master.** Given a URL, a page, or a `.har`, recover the byte-exact
  highest-fidelity original hiding behind a CDN/CMS transform.
- **Rob the grave.** Given a dead, defunct, parked, redirected, or archive-only site, find what
  is still alive and where, then extract it exhaustively.

They share one premise: **more bytes is not more picture, and a 404 is not proof of absence.**
Most of what this plugin knows is a catalog of ways a candidate wins on size or format priority
while carrying *fewer real pixels*, and ways a dead end turns out to be a locked door.

## Start here

In Claude Code:

```
/hunt:master https://cdn.example.com/img/hero_800x.jpg?q=60   ← one image → its true original
/hunt:recon  deadsite.com                                     ← one domain → what survived, where
```

Or drive the tools directly, without Claude:

```bash
bash tools/cdn/app.sh -o ./out '<url>'          # resolve one URL to its master
bash scripts/recon.sh -o ./recon-deadsite deadsite.com
```

Recon is read-only and downloads nothing, so it is always safe as a first move. Run it before
extracting anything: "dead" is a spectrum, and which of the four branches you are in decides
every later step.

### Scope — and when this is the wrong plugin

`hunt` is the front door for **any** dead site and for **any** single asset. It installs nothing
beyond `curl` and `dig`, holds no state, and is safe to point at an unknown host.

The one job it deliberately hands off: rebuilding the **full product catalog of a dead
storefront**. That is [`wayback-archive`](../wayback-archive/) — a nine-stage resumable pipeline
with a SQLite ledger and an audit gate. Recon detects storefronts and prints the handoff command;
take it rather than hand-rolling a catalog. Conversely, if you don't yet know whether a site is
dead, or you want one image rather than a catalog, start here, not there.

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
scripts/recon.sh          Phase-1 recon: seven probes → dossier → branch routing
registry/                 43 per-host lore entries — lever, trap, enumeration surface, dead ends
skills/                   the two playbooks
commands/                 the two entry points
```

### The registry

`registry/README.md` is an indexed table of 43 entries covering image CDNs and CMS delivery
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

#### What the engine actually knows

Two different things get called "supported", and conflating them wastes a hunt. Regenerate this
list any time you touch `app.sh`:

```bash
grep -oE '^cdn_resolve_[a-z0-9_]+' tools/cdn/app.sh | sed 's/cdn_resolve_//' | sort
```

**Wired — a resolver fires automatically (48):** imgix (generic + Bustle/BDG custom domain),
Cloudinary, Sanity, Photon/PMC, WordPress uploads, Substack, mzstatic/Apple Music, StockX, GOAT,
SKIMS, Discogs, Reddit, Pinterest, Twitter, Google, Squarespace, Akamai Image Manager
(NBC/FWRD/Revolve), Arc XP resizer, Hearst hdnux, Condé Nast, WSJ, Playboy, YNAP, RebelMouse,
Hypebeast, Next.js/Netlify/Cloudflare Images proxies, Thumbor, Shopify (+ legacy), Contentful,
Storyblok, Uploadcare, Fastly, Bunny, Sirv, Tumblr, Flickr, Imgur, Cargo/Cargo Collective, Format.

**Registry-only — lore exists, but no resolver.** The engine falls through to its generic
fallback on these, so **you must apply the lever by hand** from `registry/`:

| Host | Where the lever lives |
|---|---|
| Etsy, eBay, Depop, Grailed | [`reseller-marketplaces`](registry/reseller-marketplaces.md) — `il_fullxfull` · `s-l1600` · `P0` · bare |
| TheRealReal | [`therealreal`](registry/therealreal.md) |
| Swell Commerce, Fourthwall | [`swell-commerce`](registry/swell-commerce.md), [`fourthwall`](registry/fourthwall.md) |
| Brandfolder, SFCC/Scene7, ASA-DTS | [`brandfolder`](registry/brandfolder.md), [`pacsun-sfcc-scene7`](registry/pacsun-sfcc-scene7.md), [`asa-dts`](registry/asa-dts.md) |
| 3DIssue, eMagazines, Pugpig, FolioLink | the digital-editions entries in [`registry/README.md`](registry/README.md) |

Closing that gap is the standing invitation: when you verify a pure string transform for one of
them, promote it to `cdn_resolve_<name>()` with fixtures (see **Conventions** below) and move it
up into the wired list.

### Recon

```bash
bash scripts/recon.sh [options] <domain>

  -o DIR   output directory (default ./recon-<domain>)
  -H HOST  pin the liveness target
  -p FILE  extra candidate paths
  -d SECS  delay between liveness probes (default 0.3)
  --no-archive / --no-liveness / --no-third-party
```

Seven probes — DNS triage across 39 subdomains, front-door classification, certificate
transparency, reverse-IP, Wayback CDX census, CommonCrawl, commerce fingerprint — plus the
four-way liveness read over 53 candidate paths. **It downloads no assets; this phase only builds
the map.**

Third-party lookups run concurrently because they hit different hosts. The origin gets a single
serialized queue, because a fragile legacy box answers *empty* rather than 429 under concurrency
— which corrupts enumeration without ever erroring, so the failure reads as "there was nothing
there."

#### What it writes

| File | What it is |
|---|---|
| `RECON.md` | the dossier — front-door class, live-host map, liveness read, archived path inventory, branch routing |
| `recon.json` | the same findings as **data** (schema 1) — `RECON.md` is prose and nothing can parse it |
| `commerce.txt` | storefront fingerprint: platform, which signal proved it, any `.myshopify` alias |
| `liveness.txt` | four-way read, with a catch-all guard at the top |
| `cdx*.txt` | full census, plus subdomain / directory / image breakdowns and a completeness check |
| `dns.txt` `crtsh.txt` `reverseip.txt` `commoncrawl.txt` | raw probe output |
| `registry-stub.md` | pre-filled lore entry to complete and move into `registry/` |

In `recon.json` every host carries the **evidence** that put it there (`cdx`, `dns`, `ct`,
`dns-wildcard`, `myshopify-alias`) — so a consumer can tell a host proven by a capture from one
that merely resolves under a wildcard, which is the difference between a real target and a
fabricated one.

#### Read these three first

They decide whether anything else in the dossier is trustworthy:

- **SPA catch-all** — the host returns 200 for garbage paths, so every 200 is suspect. Match code
  *and* size against the guard; identical size means app shell, not content.
- **Wildcard DNS** — a bogus name resolves, so `[wildcard]` rows are not evidence a host exists.
- **CDX completeness** — `cdx-pages.txt` must report 1 page, or the census is truncated and your
  host list is not exhaustive.

#### Dead storefronts hand off

A dead store is the one recovery shape with a purpose-built pipeline. When the census or an HTML
sample shows Shopify, Swell, Fourthwall, or Adidas, `RECON.md` says so and prints:

```bash
python3 <wayback-archive>/scripts/bootstrap.py --from-recon ./recon-<domain>/recon.json
```

That upgrades both ends: [`wayback-archive`](../wayback-archive/) gets an authoritative
`matchType=domain` census instead of its own bounded `limit=5000` sample, inherits the wildcard
and catch-all warnings, and drops wildcard-only hosts rather than dumping them. Rebuilding a
catalog by hand from `cdx-images.txt` instead throws away the product↔image association, which is
the actual deliverable.

## The two ideas worth internalizing

**1. The archive is a map. The origin is the treasure. They are usually disjoint.**

The record shows what was linked and crawled; crawlers grab HTML and skip deep asset trees. The
origin may still hold assets nothing ever linked — and may be missing what the record kept. So
"404 in Wayback" is not "gone", and a live directory the archive never saw cannot be enumerated
by any archive query. The cross-reference between the two lists is the highest-value move in a
dead-site hunt, and no single probe produces it for you.

*Worked once, on a photographer's dead site:* the apex was parked on AWS and `/` redirected to the
owner's new domain — the shape most hunts stop at. But `www` and `cpanel` still resolved to the
original hosting box, and the root redirect was a root-only rule, so sub-directories bypassed it.
`/kanye/` turned out to be a **wide-open Apache index holding 4,605 images across 41 folders
(423 MB) that Wayback had never seen** — including two 67 MB camera-original TIFFs. Meanwhile the
site's *most heavily archived* galleries were deleted from the origin **and** imageless in the
archive: `{"archived_snapshots":{}}` for every one. Fully disjoint in both directions. The full
retrace is in `skills/dead-site-treasure-hunt/SKILL.md`.

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

## When a probe comes back strange

| Symptom | Cause | Move |
|---|---|---|
| Every path returns 200 | SPA catch-all | Check the guard at the top of `liveness.txt`; match size, not just code |
| 30+ subdomains "resolve" | Wildcard DNS | Only unmarked rows are evidence; cross-check `cdx-subdomains.txt` and `crtsh.txt` |
| `crtsh.txt` is empty or has a failure line | crt.sh rate-limits and 502s under load | Re-run later; it is slow (5–30 s) by nature, not broken |
| Census looks thin | `cdx-pages.txt` reports >1 page | The census is truncated — your host list is not exhaustive |
| Origin returns empty bodies mid-crawl | A fragile box rate-limiting by IP | It answers *empty*, not 429. One host, one queue; raise `-d` |
| `403` on a directory | Exists but no-index | Not a dead end — attack sub-paths, it's on disk |
| HEAD says 404, GET works | Cold-cache HEAD lie | Never conclude absence from HEAD alone |
| Engine picks a bigger file that looks worse | A wrapper or bloat re-encode | Compare real pixel dimensions; PSNR >50 dB means keep the smaller one |
| Host blocks everything | WAF / TLS fingerprinting | Install `curl_cffi`; see `registry/waf-and-bot-walls.md` |

Before declaring anything unrecoverable, get the disproving evidence:
`curl -s "https://archive.org/wayback/available?url=<url>"` returning `{"archived_snapshots":{}}`
is the **only** authoritative "never archived".

## Legality and scope

This recovers material from hosts that serve it, using ordinary HTTP requests and public
archives — no authentication bypass, no credential attacks, no exploitation. Rate-limiting
politeness is built in and enforced by default. What you may *do* with recovered material is a
copyright question this plugin does not answer: it produces provenance records (`CITATIONS.md`,
`manifest.csv` with SHA-256) precisely so the question can be answered later.

## License

MIT

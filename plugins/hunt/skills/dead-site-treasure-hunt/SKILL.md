---
name: dead-site-treasure-hunt
description: >
  Recover valuable assets — master images, video, whole galleries/catalogs, documents — from a
  DEAD, defunct, abandoned, parked, redirected, or "gone" website. Use whenever the user hands a
  dead/old domain, a Wayback dump, a defunct creator/photographer/brand/store site, or says the
  site "is gone / offline / gets redirected / used to have X" and wants what was on it. This is
  the recon-and-recovery playbook: figure out what (if anything) is still alive and WHERE, then
  extract exhaustively. Trigger on: "dead site", "defunct", "abandoned", "site is gone", "used to
  be at", "old site", "parked domain", "redirects now", "wayback", "web archive", ".har of a dead
  site", "recover the images/catalog/gallery from", "is the server still up", "find the origin",
  "the CMS is gone", "resurrect", "old CDN", "cached version", or a bare defunct URL pasted with
  intent to recover its contents. COMPANION to `master-image-hunt` (use that to resolve an
  individual file to its master once found) and `wayback-archive` (dead e-commerce catalog+images
  by URL). The engine is the vendored tools/cdn/app.sh; Phase 1 is automated by scripts/recon.sh;
  per-host lore lives in the plugin's registry/ and in any local project_* memory files.
---

# Dead-Site Treasure Hunt

A defunct site is not one thing. "Dead" is a spectrum — parked, redirected, replaced-by-SPA,
host-alive-but-content-deleted, or truly gone — and each state has a *different* road to the
treasure. This skill is the **triage tree**: spend the first moves finding what is still alive
and where, because that single fact dictates everything after.

## Prime mental model

> **The archive is a map. The origin is the treasure. They are usually DISJOINT.**

- The **record** (Wayback / CommonCrawl / search cache) shows what was *linked and crawled*. It
  routinely lacks the actual full-res assets (crawlers grab HTML, skip deep `/bin/images/`).
- The **origin** (the real server / bucket / CMS) may still hold assets that were *never linked
  or crawled* — and may be missing things the record has. In the worked example below, the live
  host served an entire `/kanye/` tree Wayback **never saw**, while the biggest *archived*
  galleries (KO, IYAZ) were **deleted from the origin and imageless in Wayback** — fully disjoint.

So: never stop at the archive, and never assume "404 in Wayback" = gone. Check both layers.

## The hunt, in order

```
0 FRAME  → what's the treasure? gather every domain/subdomain/URL/dump you have.
1 RECON  → what is still alive, and WHERE?  (the decisive phase — see below)
2 BRANCH → route by what's alive: A live-origin · B SPA+CMS-backend · C archive-only · D cloud-bucket
3 EXTRACT→ enumerate exhaustively (open-index parser · gallery-format awareness · crawler ∪ backfill)
4 VERIFY → is it really the master? (ranged-header dims · exiftool · camera-name ≠ master)
5 DELIVER→ citation log + manifest + file tree; DOCUMENT DEAD ENDS explicitly.
```

Run `${CLAUDE_PLUGIN_ROOT}/tools/cdn/app.sh` on any single recovered URL to resolve it to its
master (it knows 48 hosts plus a generic fallback). This skill is what wraps *around* app.sh when
the site itself is dead.

**Phase 1 is automated.** `bash "${CLAUDE_PLUGIN_ROOT}/scripts/recon.sh" -o ./recon-<d> <domain>`
runs all six probes below, classifies the front door, tests for both the SPA catch-all and
wildcard DNS, and writes a `RECON.md` dossier with the branch routing. Read the dossier, then do
the archive↔live cross-reference by hand — that step is judgment, not a probe. The rest of this
section is what the script is doing and why, which is what you need when a probe comes back
strange or you must go beyond it.

---

## Phase 1 — RECON (do these in parallel; they hit different hosts, so it's safe)

The goal is a map: **live hosts + the full historical inventory.** Six probes:

1. **DNS triage — dig EVERY name, not just the apex.** apex, `www`, and service/legacy
   subdomains can point to *different* hosts.
   ```bash
   for h in "" www. cpanel. webmail. webdisk. ftp. mail. api. cdn. assets. img. images. \
            media. static. m. mobile. blog. shop. store. v2. v3. old. staging. dev. beta.; do
     printf "%-28s %s\n" "$h$D" "$(dig +short ${h}$D A | tr '\n' ' ')"
   done
   ```
   **Tell:** live `cpanel.`/`webmail.` → a cPanel account is still up → the *origin is probably
   alive* even if the apex is parked. (This is how the Nabil hunt started.)

2. **Certificate transparency** — the owner's whole domain/subdomain family, incl. addon domains
   and `api.`/`v3.` hosts the frontend never links: `curl -s "https://crt.sh/?q=$D&output=json"`
   (also try `%25.$D`). SANs on the *current* cert exposed `api.`, `v3.`, mail infra, and sibling
   brands in the example.

3. **Reverse-IP** — shared vs dedicated, occasional sibling domains:
   `curl -s "https://api.hackertarget.com/reverseiplookup/?q=$IP"`. (Shared GoDaddy IP = mostly
   unrelated tenants; don't chase those. Dedicated/Vercel/Netlify = the real footprint.)

4. **Current front door** — `curl -sSIL` the apex + www. Classify:
   - **Parked** (registrar lander, 405-on-HEAD-but-HTML-on-GET) → dead front, check origin/archive.
   - **301/302 to a new domain** → the creator moved; that target has its own live backend (Branch B).
   - **Modern SPA** (`id="app"`, Netlify/Vercel/Cloudflare Pages, `prerender.io`) → its *backend/CMS*
     is the treasure surface (Branch B).

5. **Wayback CDX census — authoritative, full, un-truncated:**
   ```bash
   curl -s "http://web.archive.org/cdx/search/cdx?url=$D&matchType=domain&output=text\
&fl=original,timestamp,mimetype,statuscode&collapse=urlkey" > cdx.txt
   # confirm not truncated: add &showResumeKey=true or check &showNumPages=true (=1 means complete)
   ```
   `matchType=domain` covers every subdomain + depth. Extract: every subdomain, every top-level
   dir, every deep dir, every image/asset URL. (A trailing-`*` + `matchType=prefix` sometimes
   returns 0 rows — a syntax quirk; the `domain` query is authoritative.)

6. **CommonCrawl index** (when Wayback is thin) — `https://index.commoncrawl.org/` collinfo, then
   query a CC-MAIN index for the host; WARC offsets give raw archived bytes Wayback may lack.

**Output of Phase 1:** a list of live hosts + the complete historical path/subdomain inventory,
so Phase 2 knows which branch(es) to run.

---

## Phase 2 — BRANCH by what's alive

Run whichever branches your recon lit up (often more than one).

### Branch A — Origin host still alive (moved/parked, but the server answers)
The classic jackpot: content was *partially* deleted but the docroot was never de-indexed.
- **Probe the docroot** with the **four-way liveness read** — this is the whole game:

  | code | meaning | action |
  |------|---------|--------|
  | `200` | live file **or open directory index** | crawl it |
  | `403` | **exists but forbidden/no-index** | attack sub-paths under it (dir is on disk) |
  | `404` | gone | skip |
  | `301` | redirected away (e.g. to the new site) | note the target, it's Branch B |

- **Recognize the archive↔live inversion.** Cross the Wayback path inventory against live probes:
  dirs Wayback saw but are now 404 = *deleted*; dirs that are **200-live but Wayback never saw**
  = the survivors worth crawling (Wayback can't enumerate them for you — go straight to the live
  open index). In the example, `/kanye/` and `/nas/` were live-only; guessing artist names was
  low-yield precisely because of this disjointness.
- If the docroot `/` 301s away, **sub-directories often bypass the redirect** and serve their real
  contents (the redirect is usually a root-only `.htaccess` rule).

### Branch B — Replaced by a modern SPA with a live headless-CMS / API backend
The creator rebuilt on Netlify/Vercel; the *data* lives behind a public API.
- Fetch the SPA, pull `app.*.js`, and grep for the backend: `api.`, `/lazystate`, `/_next/data`,
  `/page-data/`, `graphql`, GROQ (`*.apicdn.sanity.io`), `cdn.contentful`, `prismic`, `cargo`,
  `format`, `.json` state endpoints, S3/`amazonaws`, `cloudinary`/`imgix`.
- Many are **public and auth-free.** In the example, `api.nabil.com/lazystate/<route>` returned
  `files{name:{url,width,height,hash}}` for every page — a full enumeration surface even though
  directory listing was 403. Masters were served straight from `/content/<page>/<file>.jpg` (no
  resizer — the stored file was the ceiling).
- **Trap — SPA catch-all fake-200:** Netlify/Vercel serve the SPA shell (HTTP 200) for **any**
  path. `deadsite.com/kanye/anything.tif` returns 200 with a fixed-size HTML body — it is NOT an
  open dir. **Always verify with a deliberately-bogus filename**; if garbage returns the same
  200/size, it's a catch-all, not content.

### Branch C — Origin dead; only the record remains
- **Wayback raw-byte recovery** — fetch the *original* bytes, not the rewritten viewer page:
  `https://web.archive.org/web/<ts>id_/http://<original-url>` (the `id_` suffix is mandatory).
- **Confirm zero-captures authoritatively** before declaring a dead end:
  `curl -s "https://archive.org/wayback/available?url=<url>"` → `{"archived_snapshots":{}}` = truly
  never archived. (In the example this proved KO/IYAZ images were *unrecoverable anywhere* — worth
  knowing definitively rather than guessing.)
- CommonCrawl WARC, Google/Bing cache, `timetravel.mementoweb.org` aggregator for other mirrors.
- Ceiling here = whatever the crawler happened to fetch (often only the web-display tier).
- **If the dead site is a STOREFRONT, hand off — do not hand-roll the catalog.** A store is the one
  Branch-C shape with a purpose-built pipeline: the `wayback-archive` plugin does CDX dump → index →
  filter → fetch → CDN discovery → match → download → normalize → build, with a SQLite ledger and an
  audit gate, across Shopify / Swell / Fourthwall / custom platforms. Tells that you are looking at
  one: `/products/`, `/collections/`, `/cart` in `cdx-dirs.txt`; `cdn.shopify.com`, `/cdn/shop/`,
  `cdn.swell.store`, or `imgproxy.fourthwall.com` in `cdx.txt`; a `.myshopify.com` alias in any
  captured HTML. Feed it the census this recon already produced rather than letting it re-derive a
  weaker one:

  ```bash
  python3 <wayback-archive>/scripts/bootstrap.py \
    --input "$(awk '{print $2}' <recon-dir>/cdx-subdomains.txt | paste -sd, -)"
  ```

  **The storefront CDN usually outlives the storefront** — see `registry/dead-shopify-storefronts.md`
  before assuming a dead product page means dead images. It is a tendency, not a guarantee: confirm
  per store and record the negative with its evidence.

### Branch D — Assets migrated to still-open cloud storage
- S3/GCS/R2 bucket **list**: `?list-type=2` / `?prefix=` on the bucket host; open Firebase; a CDN
  origin still serving behind a dead frontend. Bucket name often leaks in the SPA JS or old HTML.

---

## Phase 3 — EXTRACT exhaustively

- **Apache open-index → authoritative file list** (parse the Size column; masters = biggest, no
  downloads needed). See `FIELD_KIT.md §Autoindex`.
- **Gallery-format awareness** — old-school exports have known, fixed tier layouts; recognize the
  generator and go straight to the ceiling tier:
  - **Adobe Photoshop "Web Photo Gallery"**: `index.html` frameset · `pages/N.htm` · `images/N.jpg`
    (display = ceiling; **no original tier exists in the export**) · `thumbnails/N.jpg`.
  - **JAlbum / Lightroom "Default (HTML)"**: `index_N.html` · `content/<name>_large.html` ·
    `content/bin/images/large/<name>.jpg` (ceiling) · `.../thumb/`.
  - Others to fingerprint: Koken, Zenphoto/ZenPhoto20, SmugMug, Cargo/Cargo2, Format, Photodeck,
    Pixieset, Koken, Jimdo. `grep -l 'Web Photo Gallery'`, look for `content/bin/images/`, etc.
- **Mirror = crawler ∪ authoritative-index backfill.** `wget --mirror` (or any HTML-follow) MISSES
  files reachable only via the directory listing. Enumerate the open index independently, diff
  against disk, and `curl` the gaps. In the example, wget got 5,316/5,672 and backfill recovered
  the remaining **356** (all Lightroom frames the frameset didn't link).
- **Politeness = one queue per origin host.** A shared/legacy box rate-limits by IP and will
  answer **empty** (not 429) under concurrency — which silently corrupts enumeration. Serialize
  all heavy work against one host; parallelize only *across different* hosts. (This cost two wasted
  "0-result" runs in the example.)

## Phase 4 — VERIFY the master

- **Ranged-read the header, don't download the file:** `curl -r 0-400000` then `file` (prints
  WxH + camera for TIFF/JPEG) or parse the TIFF IFD (tags 256/257). Measured a 67 MB TIFF as
  6000×3732 / Canon 1D Mark II from 400 KB.
- `exiftool` (if installed) for camera/lens/serial/date/color-profile — provenance + verification.
- **Camera-original filename ≠ master.** `DSCF*/IMG_*/_E5H*` are the raw capture names, but the
  *bytes* served are often a web downscale. Compare byte size vs `fm=json`/expected; know when the
  web tier **is** the ceiling (no original survived) so you don't chase a nonexistent `originals/`.

## Phase 5 — DELIVER + document dead ends

- **Citation log** (provenance: which host/IP, access method, retrieval date), **manifest.csv**
  (per-file source URL + bytes + SHA-256), **file tree**. See the Nabil deliverables as a template.
- **Document dead ends explicitly** — exactly what was tried and confirmed unrecoverable, with the
  disproving evidence (e.g. `availability` API `{}`), so nobody re-runs a proven-dead path.

---

## Trap catalog (hard-won)

- **`403 ≠ 404`** — locked door vs empty lot. 403 dirs are on disk; attack their sub-paths.
- **cpanel/webmail subdomain alive = origin alive** even when the apex is parked.
- **Archive ↔ live are disjoint** — crawl live-only survivors; don't trust Wayback for "what exists."
- **SPA catch-all fake-200** — verify any "found" path with a garbage filename first.
- **Parked apex 405s on HEAD** but serves on GET — always GET before concluding "dead."
- **Wayback `id_`** returns original bytes; the bare `/web/<ts>/` form returns the rewritten viewer.
- **`{"archived_snapshots":{}}`** is the only authoritative "never archived" — use it before dead-ending.
- **Crawler completeness is a lie** — always diff against the directory index and backfill.
- **One host, one queue** — concurrency against a fragile origin returns empty, not errors.
- **Ranged-read before you download or celebrate** a big master.
- **Root `/` 301 doesn't bind sub-dirs** — deep paths often still serve.

## Worked example (the reference case)

`nabilphotography.com` → apex parked (AWS, 405); `www`/`cpanel` still resolved to the original
**GoDaddy cPanel box**. `/` 301'd to the creator's new site `nabil.com`, but sub-dirs bypassed it:
`/kanye/` was a **wide-open Apache index** holding the photographer's entire 2007 Kanye West shoot
archive (41 folders, 4,605 images, 423 MB) — **never archived by Wayback**. Masters: two 67 MB
TIFFs (6000×3732, Canon 1D Mark II) + an 11 MB Leica JPEG. The web galleries' `images/` tier was
the ceiling (no `originals/`; 55/55 guesses 404). Branch B (`api.nabil.com/lazystate` Kirby CMS)
held only 1 curated Kanye still + 3 Vimeo video IDs. Branch C confirmed KO/IYAZ galleries dead
everywhere (`{"archived_snapshots":{}}`). Deliverables: `CITATIONS.md`, `manifest.csv` (SHA-256),
`FILE_TREE.txt`, `POST_MORTEM.md` in `~/downloads/Nabil/`. Full retrace + snippet origins in that
post-mortem.

## Adjacent tooling

- **`master-image-hunt`** skill — once you have one live URL, resolve it to its byte-exact master.
- **`wayback-archive`** plugin — dead *e-commerce* catalog (products + images) recovery, end to end.
  A separate install (Python + a stateful pipeline), and the correct move for a dead **store**
  rather than hand-rolling one. See the handoff in Branch C for the tells and the invocation.
- **`${CLAUDE_PLUGIN_ROOT}/tools/cdn/app.sh`** — 48 CDN resolvers + a generic fallback; run on any
  recovered URL. `--vimeo` for video. Offline tests: `bash tools/cdn/tests/run.sh`.
- **`${CLAUDE_PLUGIN_ROOT}/scripts/recon.sh`** — automates Phase 1 into a `RECON.md` dossier.
- **`${CLAUDE_PLUGIN_ROOT}/registry/`** — portable per-host lore; write the lever and the trap
  here when you crack a site, and carry the `registry-stub.md` the recon script leaves behind.
- **`FIELD_KIT.md`** (this dir) — copy-paste commands for every step above.
- **Missing tools that would help** (install if hunting often): `ffuf`/`feroxbuster` (recursive
  content discovery w/ 403/404 handling), `exiftool`, a Wayback bulk downloader (`cdx_toolkit`),
  DNS-history (SecurityTrails), reverse-image search API.

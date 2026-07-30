---
description: Phase-1 recon on a dead, defunct, parked, or redirected site — find what is still alive and where, then route to the right recovery branch. Read-only; downloads nothing.
argument-hint: "<domain> [outdir]"
---

Run recon on `$1` and route the hunt. Load the `dead-site-treasure-hunt` skill — "dead" is a
spectrum (parked · redirected · replaced-by-SPA · host-alive-content-deleted · truly gone) and
each state has a different road to the treasure. Do not start extracting before the map exists.

1. **Run the recon script.** It performs all six probes, runs the third-party lookups
   concurrently, keeps the origin on a single serialized queue, and writes a dossier:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/recon.sh" -o "${2:-./recon-$1}" "$1"
   ```
   Useful flags: `-H <host>` to pin the liveness target, `-p <file>` to add candidate paths,
   `-d <secs>` to slow the probes down, `--no-archive` / `--no-third-party` / `--no-liveness`.

2. **Read `RECON.md` first**, then the raw files it cites. It gives you the front-door
   classification, the live-host map, the four-way liveness read, the archived path inventory,
   and the Phase-2 branch routing. Three findings in it decide whether anything else is
   trustworthy:
   - **SPA catch-all** — if the host returns 200 for garbage paths, every 200 is suspect. Match
     code *and* size against the guard; an identical size is the SPA shell, not content.
   - **Wildcard DNS** — if a bogus name resolves, `[wildcard]` rows are not evidence that a host
     exists. Cross-check against `cdx-subdomains.txt` and `crtsh.txt`: a control-panel subdomain
     that Wayback or a CT cert also saw is real regardless of the wildcard.
   - **CDX completeness** — `cdx-pages.txt` must say 1 page, or the census is truncated.

3. **Do the archive↔live cross-reference by hand — this is the highest-value move and no single
   probe produces it.** Diff `cdx-dirs.txt` against `liveness.txt`:
   - archived but now 404 → **deleted**, so it is a Branch C (archive) target;
   - **live but never archived** → the survivors, and no archive query will ever enumerate them;
   - 403 → the directory is on disk, so attack its sub-paths.

   The archive is a map; the origin is the treasure; they are usually **disjoint**.

4. **If `RECON.md` says a storefront was detected, hand off — don't hand-roll the catalog.** A
   dead store is the one shape with a purpose-built pipeline. Run the command the dossier prints:
   `bootstrap.py --from-recon <outdir>/recon.json` in the `wayback-archive` plugin, which consumes
   this run's census rather than re-deriving a weaker one. Rebuilding by hand from `cdx-images.txt`
   discards the product↔image association, which is the actual deliverable. If that plugin isn't
   installed, say so and stop rather than improvising a pipeline.

5. **Run the branches `RECON.md` lit up** (often more than one) per the skill's Phase 2. Before
   crawling, fingerprint the gallery generator and go straight to its ceiling tier — Photoshop
   Web Photo Gallery has no original tier at all, JAlbum/Lightroom keeps it at
   `content/bin/images/large/`. Then mirror as **crawler ∪ index backfill**: `wget --mirror`
   silently misses files reachable only from the directory listing, so enumerate the index
   independently, diff against disk, and curl the gaps.

6. **One host, one queue.** Parallelize across different hosts only. A fragile legacy origin
   answers *empty* rather than 429 under concurrency, which corrupts enumeration without
   erroring — the failure looks like "there was nothing there."

7. **Verify** any master by ranged read rather than download
   (`curl -r 0-400000 "$URL" -o head.bin && file head.bin`), and resolve individual files to
   their true masters with `/hunt:master`. A camera-original filename is not proof of a master.

8. **Deliver** `CITATIONS.md` (host/IP, access method, retrieval date), `manifest.csv`
   (url, bytes, sha256), `FILE_TREE.txt` — and **document dead ends with their disproving
   evidence**, so nobody re-runs a proven-dead path. `{"archived_snapshots":{}}` from
   `archive.org/wayback/available` is the only authoritative "never archived"; never call
   something unrecoverable without it.

Finally, fill in `registry-stub.md` from the output directory and move it into
`${CLAUDE_PLUGIN_ROOT}/registry/` so the lever and the trap survive this session.

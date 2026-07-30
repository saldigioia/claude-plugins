---
description: Resolve a URL (or a .har capture) to the byte-exact highest-fidelity master behind its CDN/CMS transform. Runs the vendored 48-resolver engine first, then the manual ladder only if the host is unknown.
argument-hint: "<url | page-url | file.har> [outdir]"
---

Recover the master for `$1`. Load the `master-image-hunt` skill and follow its algorithm — do
not improvise a ladder, and do not hand-probe a host the engine already knows.

Order of operations:

1. **If `$1` is a `.har`**, do HAR triage first (skill §HAR triage): largest image responses,
   unique image hosts, the `Accept` header the browser sent, and the fingerprinting response
   headers. Use `jq` — never read the HAR into context. That yields the candidate URLs and the
   enumeration surface; then continue per-candidate below.

2. **Run the engine before thinking.** It encodes 48 host resolvers plus a generic fallback:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/tools/cdn/app.sh" -o "${2:-./hunt-out}" '<url>'
   ```
   Add `-c cookies.txt` for paywalled/authed hosts, `PROBE_DELAY=1` to rate-limit, `--no-cdn`
   to see the untouched baseline. Read the log: `CDN resolved → …` names the resolver that
   fired; `BEST → FMT (size)` is the winner.

3. **Check the result against the trap catalog before believing it** (skill §Traps). Every trap
   is "bigger and/or better-format but NOT more real pixels": false full-res transcode, upscale,
   lossless-wrapper, bloat re-encode, quality-ladder, cold-cache HEAD lie, over-cap original.
   The one in `CDN_TABLE.md` for this host is the one to check first.

4. **Verify — never trust a filename or a Content-Length** (skill §Verify): magic bytes, real
   pixel dimensions, EXIF survival, and PSNR when two candidates share dimensions (>50 dB means
   pixel-identical, so keep the smaller honest one; <40 dB is a genuine fidelity difference).

5. **Only if the host is unknown to the engine, or the result looks wrong**, walk the 10-step
   manual ladder in the skill. When you crack a new host, the endgame is to wire a
   `cdn_resolve_<name>()` into `app.sh` (skill §Adding a resolver: pure string transform,
   ordered more-specific-before-generic, fixtures in `tests/run.sh`, `shellcheck` + `bash -n`)
   and to record the lever and the trap in
   `${CLAUDE_PLUGIN_ROOT}/registry/` — see that directory's README for the entry format.

6. **Report** the winning URL, its verified dimensions and format, the resolver or lever that
   produced it, and the trap you ruled out. If the true original is unreachable (e.g. a source
   above Sanity's 8192px ceiling), say so explicitly and name the best obtainable rendition
   instead of implying you got the master.

Scope discipline: resolve what the user handed you. Enumerating the host's whole collection is a
separate, larger job — offer it, don't auto-run it.

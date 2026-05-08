# Why this skill exists

This exists because most stem-summing tools either default to normalization (which destroys the engineer's gain decisions) or default to lossy intermediate (which destroys headroom). This is the conservative third option.

The audience: anyone with a folder of multitrack stems who wants a stereo mixdown they can hand to a mastering engineer or stand behind as an archival deliverable. The opposite audience — somebody who wants the loudest possible bounce for a streaming upload — is correctly served elsewhere.

## What this skill insists on

1. **The source is the ceiling.** Output rate and depth follow the inputs; lossy in the chain caps to 16/44.1 FLAC (Cmd 1).
2. **Sum at unity.** `amix=normalize=0` always; headroom comes from measured pre-attenuation, never from post-sum normalization (Cmd 2 + 3).
3. **Dither when reducing depth.** Triangular high-pass at every 16-bit reduction, no exceptions (Cmd 5).
4. **True peak everywhere.** ITU-R BS.1770 dBTP for measurement and headroom; sample peak is never a target (Cmd 7).
5. **Sidecar provenance per output.** Tool versions, exact ffmpeg command, filter graph, input SHAs, before/after measurements, idempotency key (Cmd 13).

## What this skill refuses to do

1. **Normalize to a LUFS target.** The mix bus isn't where you chase Spotify's -14; that's a mastering decision (Cmd 9). `--preview` exists for headphone listening only, and the file is labeled accordingly (Cmd 17).
2. **Upsample beyond source.** No 24/96 FLAC out of MP3; the only way to that path is the `--lie` flag, named to make the operator type something they have to defend (Cmd 1).
3. **Re-encode lossy hot.** Lossy → lossy is allowed exactly once at MP3 V0; the sidecar logs it as a second-generation encode (Cmd 8).
4. **Write into the source folder.** Default output dir is a sibling of the source. The legacy in-source layout is reachable only via `plan.py --output-dir` (Cmd 18).
5. **Embed invented metadata.** Title and comment are derived from the project + group; ARTIST / ALBUM / DATE / GENRE flow from input metadata when consistent across stems. ISRC, BARCODE, MUSICBRAINZ_* are never invented (Cmd 11).

## What's adjacent, not this

- **Mastering** — out of scope by Cmd 9. Send the unity-sum output to a separate mastering tool.
- **Source separation from a finished mix** — different problem, different tooling. Out of scope by design; use a dedicated separation tool.
- **Session timeline reconstruction** — out of scope. If your stems have different `bext.time_reference` values, consolidate in the source DAW first; the `stems_unanchored` warn (Cmd 10) tells you when this matters.
- **Multichannel input** (5.1, 7.1, ambisonic) — different problem; downmix in a tool that's honest about the coefficients.

## How to read the doctrine

`references/commandments.md` is the authoritative list. Each error message and plan rationale that cites a commandment uses the form `(Cmd N)` so the reader can jump from the diagnostic to the doctrine without searching.

The eighteen commandments aren't decoration — every one of them is the cause of behavior somewhere in `scripts/`. If you want to change behavior, start there.

# Multi-Track, Verification & Workflow Safety

Selecting tracks, proving losslessness, and not destroying source material.
`verify.sh` automates the verification below.

## Track selection & mapping

- Keep everything: `-map 0:v:0 -map 0:a` (video + all audio). Add `-map 0:s` only
  to carry subtitles.
- Keep one: `-map 0:v:0 -map 0:a:0`. Drop SAP/secondary by not mapping it.
- Audioless or uncertain sources: use optional maps (`-map "0:a?"`) so the mux
  doesn't fail when a stream is absent.
- The first mapped audio becomes the default track — map the primary (e.g.
  English 5.1) first.

## Language tags

- Copy preserves existing tags. PS (`.mpg`) carries none — add
  `-metadata:s:a:0 language=eng`. Repair junk tags (e.g. `aaa`) the same way.
- For PCM-decoded audio, set the language explicitly (the decode may not carry it).

## Per-track delays

AC-3/E-AC-3 captures often carry a small `Delay relative to video`. It's in the
timestamps and **preserved by `-c copy`** — leave it. Only the Rung-3 rebuild
rezeros it; reapply a real offset with `-itsoffset` there. Probed 2026-07-25
(ffmpeg 8.1.2): a 0.4 s TS audio delay survives the copy as a QTFF **empty
edit** on the audio track (`elst` media time −1) — the spec's own mechanism.

**Why the 0.25 s A/V parity tolerance is sound** (QTFF audit 1e): the largest
*legitimate* duration skew the spec blesses is AAC encoder priming — implicit
convention 2112 samples ≈ **44 ms @ 48 kHz** (QTFF Appendix G), represented via
edit lists / sample groups. That sits an order of magnitude under the 0.25 s
gate, while gap-collapse desync grows past it on any real capture — so the
tolerance passes every legitimate file and still catches the defect class.
**Source-aware since 1.11 (WO 2.4):** a source with *measured* transport loss
legitimately reads short by exactly the dropped time, so when the base 0.25 s
is exceeded, gate (f) widens by the source's measured forward-gap seconds
(`disc_scan` on SOURCE, or the caller-supplied `RTM_SOURCE_GAP_BUDGET`
override — e.g. a ts-health measurement of the original capture when SOURCE is
a trimmed intermediate). Never widened without a measured budget; a mismatch
beyond budget+base still flags, and an explained residual is printed, never
silent.

## Verifying a lossless remux (run before trusting output)

`scripts/verify.sh SOURCE OUTPUT` runs the cheap tier; add `--full` for the
exhaustive one. **Do not default to whole-file decoding** — two full decodes
cost roughly the video's runtime in CPU and are almost never needed.

**verify.sh's exit contract (accepted legacy — read before writing a
caller):** the verdict is the printed **text** — `>> OK` and `>> REVIEW`
**both exit 0** (verify.sh never emits the house code 10 itself); `>> FAIL`
exits 1; usage/env exits 2; an exact-match waiver exits 0 with the `WAIVED`
line. Every in-repo caller maps the text to the house contract
(`mov.sh`/`auto.sh`/`resync.sh`/`qt-groups.sh`: `>> REVIEW` → their own exit
10). A caller switched on the exit code alone reads REVIEW as green — the
qt-groups.sh defect the 1.11 fix round repaired; this paragraph and
verify.sh's header now state the contract so it cannot mislead again.

**Container scope:** verify.sh's gate (d) demands zero N/A DTS on the OUTPUT —
correct for QTFF, but a **matroska cross-check output legitimately reports
N/A DTS on B-frame head packets** (measured 2026-08-14: a lossless
`-c copy` MKV of a clean source FAILs gate (d) with `N/A-DTS=2`). Verify MKV
cross-check copies with `ts-health.sh`, not verify.sh (known-limits.md).

**Cheap tier (demux + ~30 s of decode, regardless of file length):**

```
# (a) packet-hash identity — demux only, ZERO decode. A match PROVES lossless.
ffmpeg -v error -i IN  -map 0:v:0 -c copy -f streamhash -hash md5 -
ffmpeg -v error -i OUT -map 0:v:0 -c copy -f streamhash -hash md5 -
# A MISMATCH here is INCONCLUSIVE, not a failure: TS sources get SPS/PPS
# re-placed and Rung-3 rebuilds repacketize, so identical video can hash
# differently at the packet level. Fall through to (b).
# (b) lossless essence. H.264: VCL-payload hash — strip SPS(7)/PPS(8)/AUD(9)/
#     SEI(6) so parameter-set placement (TS in-band vs MOV avcC) and a re-time
#     cannot false-mismatch. Demux only. A MATCH proves lossless even when (a)
#     and decoded framemd5 both disagree (it survives TS->MOV AND field-rate
#     rebuilds — the exact case where framemd5 FALSE-FAILs).
ffmpeg -v error -i IN  -map 0:v:0 -c:v copy -bsf:v filter_units=remove_types=6|7|8|9 -f streamhash -hash md5 -
ffmpeg -v error -i OUT -map 0:v:0 -c:v copy -bsf:v h264_mp4toannexb,filter_units=remove_types=6|7|8|9 -f streamhash -hash md5 -
#     (prepend h264_mp4toannexb, only for AVCC inputs: MP4/MOV/MKV. Omit for TS/PS.)
#     Non-H.264: decoded framemd5 of the first ~300 frames (hash column only) +
#     packet-count parity (ffprobe -count_packets; demux only).
# (c) output decode spot-checks: 10 s windows at middle and tail (-f null)
# (d) output timeline integrity — WHOLE file, demux only. Zero N/A PTS/DTS,
#     strictly monotonic DTS, and a sane sample-duration histogram. This is the
#     gate the shipped-broken files would have failed: a muxer handed
#     timestamp-less packets writes N/A-free but INVENTED timing — decode-order
#     PTS, 1-tick durations — while every essence check passes.
ffprobe -v error -select_streams v:0 -show_entries packet=pts,dts,duration -of csv=p=0 OUT \
  | awk -F, 'NF{ if($1=="N/A")nap++
      if($2=="N/A"){nad++} else {if(h && $2+0<=p) bad++; p=$2+0; h=1}
      if($3!="N/A") d[$3]++ }
    END{ printf "N/A pts=%d dts=%d  non-strict DTS=%d  durations:", nap+0,nad+0,bad+0
         for(k in d) printf " %dx%s", d[k], k; print "" }'
# want: 0 / 0 / 0, and one or two adjacent duration values on CFR broadcast
# (e) SCRUB GATE — accurate seek to a deliberately OFF-keyframe point (-ss AFTER
#     -i), the way a player lands mid-GOP and follows the seek index/edit list.
#     A keyframe-snap seek (-ss before -i) stays clean on a broken PAFF timeline,
#     so it is NOT a substitute. Any decode error here = FAIL (catch it before
#     deleting the source). Pick the midpoint between two keyframes as the target.
ffmpeg -v error -ss KF_BEFORE -i OUT -ss DELTA_TO_MIDPOINT -t 4 -map 0:v:0 -f null -
#     plus a keyframe-spacing sanity check: a single GOP over a multi-minute file
#     is effectively not seekable. (verify.sh step (e) automates all of this.)
# (f) if the SOURCE failed the MKV strict-mux test, confirm OUT now passes it
# (g) scrub by eye at start / middle / end — the ultimate arbiter (playable≠valid)
```

**Exhaustive tier (`--full`) — whole-file decoded-pixel identity:**

```
ffmpeg -v error -i IN  -map 0:v:0 -c:v rawvideo -f md5 -
ffmpeg -v error -i OUT -map 0:v:0 -c:v rawvideo -f md5 -   # must match
```

For **field-coded (PAFF) H.264 this positional rawvideo md5 FALSE-FAILs** — the
rebuilt file presents a different frame COUNT/order (field-vs-frame, edit list),
so the byte streams differ even when lossless. There, compare the *sorted
multiset* of frame hashes instead (order/count-tolerant) and treat the cheap-tier
VCL hash as the authoritative proof — never FAIL a field-coded stream on a
positional decode. `verify.sh --full` does exactly this split automatically.

Reserve `--full` for: final archival sign-off, settling a REVIEW verdict from
the cheap tier (e.g. packet counts differ and no Rung-3 rebuild explains it),
or once per new pipeline/source type to validate the recipe — then trust the
cheap tier for the rest of the batch.

**Hash the right thing.** Decoded comparisons must be timestamp-agnostic: do
NOT md5 full `framemd5` lines — they include dts/pts/duration columns and
FALSE-mismatch after any re-timing rebuild (rebuild-paff.sh changes the
timeline). Compare only the hash column. Likewise raw-bitstream MD5
false-mismatches on TS sources (SPS/PPS re-placement) — that is why a
streamhash mismatch only escalates, never fails. **For field-coded (PAFF)
H.264, decoded comparison fails even on the hash column** — the decoder presents
a different frame count/order, so a first-N or positional compare mismatches a
lossless rebuild. Use the **VCL-payload hash** (SPS/PPS/AUD/SEI stripped via
`filter_units`) as the arbiter; it compares the coded picture data directly and
is invariant to both parameter-set placement and re-timing.

## Container-valid ≠ QuickTime-playable

A correct mux can still fail to play; don't chase a phantom "bad mux".

| Content | Validly in MOV? | Plays in QuickTime Player? |
|---------|-----------------|----------------------------|
| HEVC tagged `hev1` | Yes | No — needs `-tag:v hvc1` |
| MPEG-2 4:2:0 | Yes | Yes |
| MPEG-2 4:2:2 (422@HL) | Yes | Historically no; per-OS/per-file empirical since 1.11 (demoted gate — prove the finished build with `playable-check.sh`, `--fidelity` since 1.12). Tag-dependent AND **container-dependent** (1.13): `m2v1` renders macroblock garbage where `xd5*` renders correctly on the same bitstream *when the stream matches the fourcc profile contract* (2026-08-15 VMA pair) — but on a stream that does not, all five MOV tags corrupt identically and the same bits in an `.mp4` (`mp4v`+`esds`) render correctly (2026-08-15, 21 GB capture, SSIM 0.9175+). Route: `scripts/mp4-swap.sh` — see "The container axis" in `ingest-compatibility.md` |
| Dolby Vision HEVC | Yes (ffmpeg ≥5.0, single-layer) | Device/app-dependent |
| AC-3 | Yes | Yes on modern macOS (older: spotty) |
| E-AC-3 (Dolby Digital Plus) | Yes | Yes — native in modern QuickTime |
| DTS / DTS-HD MA | Yes | No |
| MP2 | Yes (non-standard) | **Per-OS empirical** — measured playing in QuickTime here 2026-08-29, measured silent on the D3 bench 2026-08-15 (1.13); the `esds` OTI ffmpeg writes is already the correct `0x6B`, so the declaration was never the variable. Prove it on your target machine; a PCM access track is the works-everywhere option; `verify.sh` gate (g) REVIEWs an MP2 track with none |

For genuine playback of the "no/unverified" rows: first the lossless rungs —
a sample-entry retag where the class allows it, then the **container swap**
(`scripts/mp4-swap.sh`, 1.13) — and only then Rung 4 (transcode — see
`delivery-encode.md`), or keep the original container for archival. A fidelity
FAIL routed straight to a re-encode was the D2 defect: the measured remedy for
the 2026-08-15 class is lossless and was not on the list.

## The muxer can drop a mapped stream, silently (1.13)

`ffmpeg -c copy -f mov` was measured writing **2 of 3 mapped streams** with
nothing but a `-v warning` line (2026-08-15, the field-report capture). Nothing
in the pre-1.13 gate set could see it: the essence gates compare the streams
that ARE present, the timeline gates read `v:0`, and `RMX_PLAN ... unmapped=N`
is a plan printed *before* the mux. So the loss shipped green.

Every builder now reconciles the finished part file against its own plan —
count **and** per-stream codec identity — before the `mv` that blesses it
(`mux_census` in `lib-mux.sh`, machine line `RMX_CENSUS ... match=ok|MISMATCH`).
A MISMATCH is exit 1 with the artifact kept as `x.part.mov`. Rule of thumb when
adding a builder: if you wrote `-map`, you owe a census.

## Mux-valid ≠ seekable (the silent-corruption gap)

A file can pass every *mux* test — it opens, plays start to finish, passes the
strict MKV-mux test, shows monotonic DTS — and still tear the instant a player
scrubs. "Timestamps present and monotonic" and "the container's seek index /
edit list lands correctly" are different properties, and the gap between them is
where a genpts'd field-coded (PAFF) remux corrupts silently. Two cheap automated
proxies close it (both in `verify.sh` step (e)):

- **Scrub gate** — accurate seeks (`-ss` AFTER `-i`) to deliberately off-keyframe
  targets, the way a GUI scrub lands mid-GOP and follows the index/edit list. A
  keyframe-accurate seek (`-ss` before `-i`) snaps to a keyframe and stays clean
  on the broken file, so it does NOT test this. Use the accurate form.
- **Keyframe-spacing sanity** — a single GOP (or absurdly sparse keyframes) over a
  multi-minute file means a scrub must decode from far back: effectively not
  seekable.

A real player is still the final arbiter ("playable ≠ valid"), but these catch
the case unaided — before the source is deleted.

## A FAIL is a defect until every gate is individually explained

The acceptance discipline that failed in the 2026-07-25 incident, now doctrine:

- **The muxer's confession is a hard stop.** `pts has no value`, `Timestamps
  are unset in a packet`, or `Non-monotonic DTS` in a COPY mux's log means the
  muxer invented the timeline. The incident log said `pts has no value` ×4,120
  and was treated as cosmetic; the files shipped broken. `remux.sh` and
  `dual-track.sh` now capture the mux log and refuse to bless such an output —
  regardless of what any later check says about the video essence. (On a
  DELIBERATE restamp — rebuild-paff — unset-timestamp warnings are the
  mechanism working as designed; there the output-timeline gates are the proof.)
- **Replicating errors on the source explains only their class, never the
  verdict.** Two independent defects can share one symptom: the incident's
  inherent `mmco` seek noise was real AND it masked an invented container
  timeline that fails the same gates. Explaining *part* of a failure is not
  explaining the failure. A reclassification to "inherent" requires (a)
  **matching** error counts on the same windows of the source — 9 vs 5 does not
  match — and (b) the container timeline independently proven clean.
  *Automated* (QTFF audit 5-4a/b): on a nonzero count, gates (c)/(e) rerun the
  identical stage against the source and print `source: N / output: N /
  delta: D`. Gate (e) first recounts both sides at `-threads 1` — threaded
  decode jitters corruption-noise line counts (19 vs 17 measured on the same
  file), so only deterministic counts are compared, and a zero recount means
  the fast-pass lines were load strays (gate (c)'s confirm-min doctrine) — and
  splits **decoder-class** lines from **muxer-stage** `[null @ …]` lines (the
  scrub harness's own null muxer objecting to its feed, e.g. duplicate-DTS
  complaints on ms-quantized sources — a harness artifact, not a torn
  picture; C69). Delta ≤ 0 with (d) clean downgrades to REVIEW **carrying the
  evidence** — never a silent OK; archival sign-off still requires the proof
  set (MKV strict-mux + `--full` presentation order). Any excess over the
  source, or a dirty (d), keeps the FAIL (C70: only the delta indicts the
  pipeline).
- **A scrub-gate FAIL is never cleared by source replication alone.** The
  timeline must be proven with the gate table below.
- **Thumbnail render ≠ playable.** `playable-check.sh` proves ONE frame
  decodes — nothing about the presentation timeline. It is a floor under the
  gates, never a sign-off over them.
- **Precedent is not diagnosis.** A prior file "accepted with the same
  signature" is a hypothesis to re-test, not a convention to apply. The
  incident's saved precedent was itself a broken file.

### Sign-off gate table for a suspect timeline (ALL must pass, per file)

| Gate | Requirement |
|------|-------------|
| VCL-payload identity (verify.sh b) | MATCH — video bits identical |
| Output timestamps (verify.sh d) | 0 packets with N/A PTS/DTS; DTS strictly monotonic |
| Sample-duration histogram (verify.sh d) | one/two adjacent values only (e.g. 1501+1502), ±1 count |
| Presentation order (verify.sh --full) | framemd5 sequence of decoded output == source |
| MKV strict-mux of the OUTPUT | PASS (even when the source itself fails it) |
| Scrub gate (verify.sh e) | 0 decode errors, or deterministic (`-threads 1`) per-class counts matching the source under identical seeks, with (d) clean |
| A/V duration parity (verify.sh f) | Δ within 0.25 s, or the same Δ measured in the source |
| Dual-track audio (verify.sh --audio) | original track md5 == source elementary (for a TS/ADTS AAC source the compare is repeated after `aac_adtstoasc` reframing of the source side — the mux reframes ADTS→ASC automatically, payload identical; 1.11 fix round); PCM access == decoded original |
| playable-check.sh | OK — necessary, NOT sufficient (thumbnail only) |

### Recorded waivers (`OUTPUT.waiver.json`) — evidence instead of memory

When a **count-signature gate** ((d)/(e)) FAILs but its named independent
proofs all pass, the verdict can be *recorded* instead of re-litigated from
human memory every run (QTFF audit 5-4c). `scripts/waiver.sh SOURCE OUTPUT
--attest "…" --coverage "…" --proof "…"` writes `OUTPUT.waiver.json` beside the
file: the failed gate, the **exact failure signature** (class + count, taken
from a live verify.sh run — never hand-typed), the proof results with hashes,
the coverage limits stated plainly (e.g. "frame order proven on 5 windows /
954 frames, not full duration"), tool versions, date, and the operator's
**verbatim** attestation string (defined once in `lib-attest.sh`; a near-miss
is refused, never corrected).

`verify.sh` consults the sidecar on FAIL. An **exact** match — same gate set,
same counts, same file size and video streamhash, verbatim attestation — exits
**0** with a loud `WAIVED(<gate>)` line plus a machine-readable
`VERIFY_SUMMARY` field (verify.sh's own exit contract is untouched: text
verdict `>> OK`/`>> REVIEW` both exit 0, `>> FAIL` 1, usage 2 — code 10 is
never emitted by verify.sh itself; callers map the text). Any drift — a
new signature, a changed count, a changed file — **voids the waiver** and the
FAIL stands: changed evidence is new evidence, and a waiver never transfers.

Hard boundaries:

- **One file, one signature — never a class.** A waiver blesses one recorded
  failure on one artifact; it is not precedent for the next file with the same
  symptom (see "Precedent is not diagnosis" above).
- **Essence/identity failures are never waivable.** A (b)/`--full`/`--audio`
  FAIL *is* the lossless proof failing — "independent proofs pass" cannot hold,
  and verify.sh refuses the sidecar outright.
- A waiver can only turn FAIL into a loud, evidence-carrying pass — never into
  a silent OK, and never without the operator's exact attestation.

## Optional preservation checks (`--signaling`, `--audio`)

Losslessness and a clean timeline don't prove the *non-pixel* signaling survived.
Two opt-in `verify.sh` checks cover the rest:

- `--signaling` compares color/HDR tags (primaries/transfer/space/range), the
  HEVC `hvc1` tag, HDR mastering/CLL side data, and closed-caption presence
  (source vs output). Drift → REVIEW (some normalization on copy is benign).
- `--audio` checks the dual-track deliverable: the preserved original track must
  be **bit-exact** vs the source (else FAIL) and the PCM access track must equal
  the decoded original and stay aligned (else REVIEW) — the alignment QC that
  `dual-track.sh` prints, automated.

`auto.sh` builds the lossless ladder; add these flags when the source carries
HDR, captions, or you shipped the dual-track build.

## Workflow safety (lessons that cost real files)

- **Gate every step** (`set -e` / `&&`) so a failed step aborts *before* cleanup.
- **Never auto-delete** temp/elementary files — remove by hand after verification.
- **Atomic output**: write `OUT.part` (with `-f mov`), `mv` to the final name only
  on success.
- **The source is the master** — original `.ts`/`.mkv` is immutable; PCM/MOV
  derivatives are regenerable.
- **`-nostdin`** in every batch call so a loop can't be consumed by a prompt.

## Synthesizing test files

Known-good vectors for exercising a pipeline step without touching real
captures (the same technique used to verify this skill's facts):

```
# H.264 + AAC in MP4
ffmpeg -f lavfi -i testsrc2=size=1280x720:rate=25 -f lavfi -i sine=frequency=1000:sample_rate=48000 \
  -t 5 -c:v libx264 -pix_fmt yuv420p -c:a aac -b:a 128k -movflags +faststart t_h264_aac.mp4
# ProRes 422 HQ + PCM in MOV
ffmpeg -f lavfi -i testsrc2=s=1280x720:r=24 -f lavfi -i sine=1000 -t 5 \
  -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le -c:a pcm_s16le t_prores_pcm.mov
# HEVC (hvc1) + AAC in MP4
ffmpeg -f lavfi -i testsrc2=s=1280x720:r=30 -f lavfi -i sine=1000 -t 5 \
  -c:v libx265 -tag:v hvc1 -pix_fmt yuv420p10le -profile:v main10 -c:a aac t_hevc_hvc1.mp4
```

## Version-dependent behavior (probe.sh surfaces these)

Tested ffmpeg 6.1.1: MP2 muxes into MOV but is non-standard (decode for
playback); no `fiel` atom on copy (field order via bitstream); `colr` written by
default; HDR10 `mdcv`/`clli` in SEI only; Dolby Vision survives copy on ffmpeg
≥5.0 (single-layer). Confirm on your ffmpeg and on the target QuickTime.

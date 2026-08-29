# PAFF field pairing and pic_order_cnt — reading the bitstream instead of guessing at it

Guidance, not a gate. Every claim here was measured on 2026-08-29 against a
25.38 GB MPEG-TS capture (PAFF H.264 + 2× MP2) that this plugin had refused in
three prior sessions and can now convert.

The short version: **field pairing and display order are stated outright in
every slice header.** Every rule that infers them from timestamp arithmetic is
reading a proxy, and on real reordered broadcast PAFF the proxy is wrong.

---

## 1. Both fields of a complementary pair go in ONE sample

ISO/IEC 14496-15. A complementary field pair is two coded field pictures —
`field_pic_flag = 1`, `bottom_field_flag` going 0 → 1, the same `frame_num`,
adjacent in coded order — and the container stores them as a **single sample**
whose payload is the two access units concatenated.

Players time playback off samples. One sample per **field** therefore makes the
container claim roughly twice the rate the decoder emits — ~50/s over a ~25/s
decode — and the file stutters in QuickTime and IINA while remaining
**bit-identical to its source**. No essence hash can see it. `verify.sh` gate
(h) is the check that can.

**A plain `ffmpeg -c copy` of a PAFF source produces exactly this.** The defect
needs no exotic tool; the obvious command is what makes it.

    measured, 20 s slice:  1002 field pictures -> 501 complementary pairs
                           plain copy declared 1002 samples at 50/1
                           the structure implies 501 at 25/1

## 2. POC is direct evidence; a timestamp delta is a proxy for it

`pic_order_cnt_lsb` in the slice header states each picture's display position.
Unwrap it per ITU-T H.264 §8.2.1.1 (`PicOrderCntMsb` steps by
`MaxPicOrderCntLsb` on a half-range jump; both reset at every IDR) and you have
the display order the encoder actually meant — not an inference from the
container's timestamps, which is what every heuristic above this one uses.

The rung lattice is then `k = POC + C`.

## 3. C is constant PER (IDR epoch, field parity) — and that is the whole trick

**A single global C fails on a stream where the relation is provable to four
nines.** Bottom fields are legitimately stamped a constant offset below their
own tops, so pooling both parities makes the winning constant look
non-unanimous, the class is discarded as unproven, and the file is refused.

    measured, same slice:  epoch=0 parity=top     C=143  unanimity 501/501
                           epoch=0 parity=bottom  C=139  unanimity 501/501

Four rungs apart, each perfectly unanimous within its own class. Pooled, the
same data reads as two competing answers.

The bar stays unforgiving: a class is trusted only at **≥ 99.9 % agreement over
≥ 100 votes**, and an untrusted class yields nothing at all — never the most
popular guess.

## 4. "Zero adjacent pairs one field apart" is true and means nothing

On the motivating capture, **0 of 424,596** adjacent coded pairs differed by one
field duration — both parities, against a 99 % bar. Literally true. The
conclusion drawn from it ("this stream has no field pairing") was false: the
fields are coded-adjacent and share `frame_num`; the source simply stamps each
bottom field a constant **−5400 ticks** below its own top field, which is the
delta dominating **48.985 %** of that file's packet histogram.

The evidence that settles it was in the slice headers the rule declined to
open.

## 5. Work in frames, not fields, and most "holes" stop existing

After pairing, a bottom field's carried PTS is discarded — the frame takes the
**top** field's. On the motivating capture that turned 24 unstamped packets into
one: 23 were bottom fields whose timestamps are discarded on merge, leaving a
single frame-coded picture to solve from its own POC.

Counting in **field** units also invents gaps that are not there: 8,600
frame-coded pictures legitimately occupy two field rungs each, and a field-unit
census reads them as **8,632 forward "gaps"**. The genuine loss on that capture
is **11 frames = 0.44 s**, not the 177.8 s that figure implies.

## 6. Duplicate display slots are adjudicable, and the asymmetry is why

Where two packets claim one rung, the later holder is carrying a timestamp
across a transport discontinuity. Measured **10 of 10**: the earlier holder
always fits its local POC lattice and the later one never does. That asymmetry
is what makes them settleable from the bitstream rather than guessable from
neighbouring arithmetic — and a duplicate POC cannot settle is refused, not
quietly kept (`verify.sh` gate (j) exists for exactly that defect).

Holes and duplicates are usually **one** phenomenon, not two: on that capture 2
of the 10 duplicates bracketed an unstamped burst exactly.
`scripts/diagnose.sh` reports the straddle count for this reason.

## 7. Anchor on the earliest DISPLAYED frame

A MOV anchored on the first **coded** packet declares a presentation start above
its own earliest composition time, and the frames before it fall outside the
declared presentation. On a reordered stream the first coded picture is not the
first displayed one, so this is the normal case, not an edge case. Subtract
`min(PTS)` from every stream — the same constant everywhere, so A/V sync is
untouched. `verify.sh` gate (l) reports the condition.

## 8. Traps that cost real time

- **PyAV opens MP2 with the `mp3float` DECODER.** `codec_context.name` reads
  `"mp3float"`, so `add_stream_from_template` inherits codec id MP3 and the MOV
  gets a **`.mp3` sample entry over Layer II payload** — bit-identical, decodes
  without an error, and Apple documents `.mp3` as Layer *3*. Create the stream
  by codec **name** instead. Setting `codec_tag` afterwards does **not** work:
  the muxer validates tag against codec id in both directions and rejects it.
  ffmpeg's own MOV muxer refuses the combination outright ("Tag .mp3
  incompatible with output codec id"), which is itself the evidence that it is
  a genuine mislabel. `verify.sh` gate (i) catches it.

- **`framemd5` sequence comparison cannot distinguish a good remux from a bad
  one.** The H.264 decoder reorders by POC regardless of what the container
  says, so it tests essence only and can never certify a timeline.

- **Merging two field AUs turns a 4-byte start code into a 3-byte one**, costing
  exactly one byte per merged pair. A raw byte hash reports a false MISMATCH
  against a provably correct build; `scripts/nalhash.py` compares NAL payloads
  instead and is the arbiter `verify.sh` gate (m) uses.

- **macOS `head -n -N` (negative count) is unsupported** and fails silently
  inside a pipeline — it produced a false "IDENTICAL" from comparing two empty
  files.

- **An apostrophe inside a single-quoted `awk` program** ends the shell string
  and the rest is parsed as shell. Hit twice while writing the pairing census
  for this round; `tests/regression.d/94-rot-sweep.sh` §1 is the guard.

## 9. QuickTime and MP2, from Apple's own spec

The complete sound sample description list is:

    .mp3  alaw  dvca  fl32  fl64  ima4  in24  in32  mp4a  NONE  Qclp  QDM2
    QDMC  sowt  twos  ulaw

**There is no entry for framed Layer II.** `.mp3` is documented as Layer *3*;
the only documented Layer II path is the `'MPEG'` media type, which stores the
whole stream as a single sample. `.mp2` is ffmpeg's convention rather than an
Apple-documented format — it round-trips as `codec_name=mp2` and plays, but it
is not in the spec, and this plugin's own doctrine is that MP2 ships as
dual-track's *preserved original* with a PCM access track alongside.

## 10. What reads all this

| | |
|---|---|
| `scripts/h264poc.py` | slice-header reader + §8.2.1.1 POC unwrapper + 14496-15 pairing. SPS is **parsed**, never assumed. |
| `scripts/poc-remux.sh` / `.py` | Rung 3-POC: the field-pair-aware, POC-timed lossless remux |
| `scripts/nalhash.py` | the start-code-agnostic essence arbiter (gate (m)) |
| `scripts/codec-id.py` | sample entry vs payload identity (gate (i)) |
| `scripts/attempt-battery.sh` | measures whether the mux fails, instead of predicting it |
| `verify.sh` gates (h)–(n) | the container-level tier, and the ledger that says what it could not prove |

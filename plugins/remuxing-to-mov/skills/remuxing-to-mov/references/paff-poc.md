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

**The sample floor stays unforgiving: a class with fewer than 100 votes yields
nothing at all** — never the most popular guess — and one class short of the
floor withdraws the offer for the whole stream. There is no env override for it.

**The unanimity half became an announced measurement in 1.17.0** (TIERS.md
T3.4, Constitution I.3), and the reason is arithmetic, not appetite. Unanimity
is capped at **1 − f** where f is the mis-stamped fraction: a stream with 17.4 %
of its pictures stamped one frame late tops out at 0.826 and can never reach
0.999, however exactly the bitstream states its own display positions. The bar
therefore refused precisely the class this rung exists to repair, whenever that
class was systematic rather than sparse. So when no class clears it and every
class carries its 100 votes, the modal C proceeds as **PROVISIONAL**, loudly,
naming its shortfall — and the output gates decide, because they are strictly
stronger: a wrong C cannot survive the bijection onto the display lattice
(`poc-remux.py` refuses unless every frame lands on its own slot), and the full
`verify.sh` suite judges the artifact after that. `RTM_POC_MIN_AGREE` sets the
bar; its value is printed beside the per-class report either way.

## 3a. POC counts FIELDS; the lattice counts RUNGS

H.264 counts `pic_order_cnt` in fields. A field-coded stream codes one picture
per field, so POC advances **1** per rung and `k = POC + C` works directly. A
**progressive** stream codes one picture per *frame* — two fields — so POC
advances **2** per rung while the container's lattice advances 1, and
`rung − poc` is then a different key for every picture. Every class reads as
unanimous at about 1/n: field-measured **0.01042**, 2 votes of 192, on a file
whose repair is exact.

`h264poc.poc_advance` MEASURES the advance and never assumes it: the per-epoch
modal positive delta of the sorted POC values, adopted only when it agrees
across every epoch **and** divides every POC value exactly. Either check
failing yields A = 1 and no normalisation at all — an odd POC divided away is a
display position invented rather than read, and this rung's whole claim is that
it never invents one.

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

Counting in **field** units also invents gaps that are not there: the
frame-coded pictures legitimately occupy two field rungs each, and a field-unit
census reads them as **8,632 forward "gaps"**. The genuine loss on that capture
is **11 frames = 0.44 s**, not the 177.8 s that figure implies.

**A note on that capture's breakdown, because two counts of it exist.** The
plugin's census reads **8,617 frame pictures and 0 unpaired fields**; the
workshop's cache reads 8,600 frames + 17 unpaired field singles. Same sample
total (216,631), and gate (h) passes either way. The plugin's is the correct
one, and the 17 are a parsing artifact — see §6.

## 6. A parser that hardcodes one capture's SPS reads plausible nonsense

Measured 2026-08-29, and it is the reason `h264poc.py` parses the SPS instead
of assuming it. The workshop tool this module was ported from carried:

    FRAME_NUM_BITS = 8      POC_LSB_BITS = 8      FRAME_MBS_ONLY = 0

Those are right for most of feed.ts. One SPS in that file declares
`log2_max_frame_num_minus4 = 0` (frame_num is **four** bits) and
`log2_max_pic_order_cnt_lsb_minus4 = 2` (poc_lsb is **six**) — it is activated
at the program changes, which is exactly where the discontinuities are.

Reading eight bits where four exist consumes four extra, so the value comes
back as `true × 16 + four stray bits`:

| picture | hardcoded reader | SPS-aware readers |
|---|---|---|
| 63685 | frame_num 32, field_pic 1 | frame_num 2, field_pic 0 |
| 63687 | frame_num 48, field_pic 1 | frame_num 3, field_pic 0 |
| 217880 | frame_num 16, field_pic 1 | frame_num 1, field_pic 0 |

32 = 2×16, 48 = 3×16, 16 = 1×16. And because every field AFTER `frame_num` is
then read from the wrong bit offset, the misread manufactures
`field_pic_flag = 1` on 17 frame pictures — which is the whole of the 8,600/17
vs 8,617/0 discrepancy. ffmpeg's own CBS (`trace_headers`) and this module's
SPS-aware reader agree with each other and disagree with the hardcoded one on
exactly those 17 pictures, and on 42 `frame_num` values.

**The failure mode worth remembering:** the parser did not crash, and did not
return nothing. It returned confident, plausible, wrong values. That is what a
constant standing in for a measurement looks like from the outside.
`tests/regression.d/112-sps-aware-slice-reader.sh` mints a synthetic bitstream
with those unusual widths and pins that the reader recovers the true values.

## 6a. A picture with no `pic_order_cnt_lsb` still has a position

`pic_order_cnt_type` decides what the slice header even carries:

| type | what the slice carries | how the position is obtained |
|---|---|---|
| 0 | `pic_order_cnt_lsb` | unwrap it (§8.2.1.1), scope by scope |
| 1 | cycle deltas in the SPS | **unsupported here** — UNPROVEN by index |
| 2 | nothing | the spec *defines* display order to equal decode order |

Type 2 is the trap, because the absence is silent. The extractor used to emit
no row at all for such a picture; downstream, gate (k) compared row count to
timestamped-packet count, found them unequal, and reported UNPROVEN with a
`count` symptom. Measured 2026-08-29 on a mixed capture: `POC rows=50,
timestamped packets=100` — **an absence the extractor created, read back as a
fact about the file** (Constitution III.1, one layer down from where it was
first written).

So every coded picture emits exactly one row, and the row carries a
**provenance** column saying where its position came from:

```
1,0,2,lsb     poc_lsb was present and unwrapped under this scope's modulus
0,99,,t2      pic_order_cnt_type 2: position DERIVED from decode order
0,0,,none     neither — a placeholder, judged by index and counted unproven
```

The modulus column is empty on a `t2` row on purpose: `MaxPicOrderCntLsb` is
undefined for type 2, and carrying the previous SPS's value forward would
publish a number that does not apply there.

**No bar moves.** A `t2` scope is judged by *its own* rule — presentation must
advance with decode order, which is exactly what type 2 promises — so a torn
one is off-slot, not exempt. A `none` scope (type 1, or a picture whose header
could not be read) is counted in `PL_NOFIT` with its picture count and reaches
the operator as UNPROVEN. `tests/regression.d/113-poc-type2-scopes.sh` pins all
three lanes; guard G47 suppresses the placeholder emission and the count
disagreement comes straight back.

## 7. Duplicate display slots are adjudicable, and the asymmetry is why

Where two packets claim one rung, one of them is carrying a timestamp that does
not belong to it. **Exactly one holder fits its local POC lattice** — that
asymmetry is what makes the pair settleable from the bitstream rather than
guessable from neighbouring arithmetic — and a duplicate POC cannot settle is
refused, not quietly kept (`verify.sh` gate (j) exists for exactly that defect).

**WHICH holder fits is not fixed, and an earlier draft of this section said it
was.** On the 2024 VMA capture all 10 duplicates were a stale timestamp carried
*forward* across a transport discontinuity, so the earlier holder fit every
time, and "the later holder never fits" was written down as if it were the
rule. It is one capture's shape. The 2026-08-30 Reading Festival file splits
roughly **550 second-lower / 509 first-lower** on the same measurement. The
code was always general — `adjudicate_duplicates` measures `fits` and does not
care which side wins — and only the prose over-generalised.

Holes and duplicates are usually **one** phenomenon, not two: on that capture 2
of the 10 duplicates bracketed an unstamped burst exactly.
`scripts/diagnose.sh` reports the straddle count for this reason.

## 8. Anchor on the earliest DISPLAYED frame

A MOV anchored on the first **coded** packet declares a presentation start above
its own earliest composition time, and the frames before it fall outside the
declared presentation. On a reordered stream the first coded picture is not the
first displayed one, so this is the normal case, not an edge case. Subtract
`min(PTS)` from every stream — the same constant everywhere, so A/V sync is
untouched. `verify.sh` gate (l) reports the condition.

## 9. Traps that cost real time

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

## 10. QuickTime and MP2, from Apple's own spec

The complete sound sample description list is:

    .mp3  alaw  dvca  fl32  fl64  ima4  in24  in32  mp4a  NONE  Qclp  QDM2
    QDMC  sowt  twos  ulaw

**There is no entry for framed Layer II.** `.mp3` is documented as Layer *3*;
the only documented Layer II path is the `'MPEG'` media type, which stores the
whole stream as a single sample. `.mp2` is ffmpeg's convention rather than an
Apple-documented format — it round-trips as `codec_name=mp2` and plays, but it
is not in the spec, and this plugin's own doctrine is that MP2 ships as
dual-track's *preserved original* with a PCM access track alongside.

## 11. What reads all this

| | |
|---|---|
| `scripts/h264poc.py` | slice-header reader + §8.2.1.1 POC unwrapper + 14496-15 pairing + the measured POC advance. SPS is **parsed**, never assumed, and **both standard carriages are read** — Annex-B start codes and avcC length prefixes (MKV/MOV keep the parameter sets in extradata; `avcc_param_sets` seeds the parser from them). |
| `scripts/poc-remux.sh` / `.py` | Rung 3-POC: the field-pair-aware, POC-timed lossless remux |
| `scripts/nalhash.py` | the start-code-agnostic essence arbiter (gate (m)) |
| `scripts/codec-id.py` | sample entry vs payload identity (gate (i)) |
| `scripts/attempt-battery.sh` | measures whether the mux fails, instead of predicting it |
| `verify.sh` gates (h)–(n) | the container-level tier, and the ledger that says what it could not prove |
| `lib-paff.sh` `pf_poc_lattice` | judges each scope by its OWN provenance rule (§6a) — lattice, decode order, or unproven |

# WO-1.16.7 — faststart everywhere, and a claim demoted to a measurement

**Filed:** 2026-08-30, from `plugin-doctor/FOLLOWUP-1.16.6.md` (two items, one round).
**Operator policy resolution (recorded verbatim, because it narrows the WO):**
faststart defaults ON on every `.mov`-writing route **including archival** — the
opt-out is manual and announced (`--no-faststart` / `RTM_FASTSTART=0`), never
automatic. That closes the WO's own open question ("consider whether the access
copy, not the master, is where faststart belongs") in the direction of the spec.

**One sentence:** Item 1 stops gate (g) asserting a categorical the bench had
already falsified and leaves two dated measurements in its place; Item 2 makes
one policy out of three (`+faststart` hardcoded in the shell rungs, hardcoded
again in a PyAV dict, and absent entirely from the POC rung), after measuring
the thing the disk budget hung on.

---

## The measurement the item was gated on

The WO made the disk pre-flight budget conditional on a fact nobody had taken:
does libavformat's relocation need a second copy of the output on disk, or does
it shift in place? Answer, measured before any code was written:

**Bench.** ffmpeg 9.0.1 / libavformat 63.1.101, macOS 26.6.2 (Darwin 25.6.0),
external APFS SSD (`/Volumes/T9`), 2026-08-29. Fixture: a 3.93 GiB stream-copy
of the 2024 VMA build (`ftyp`/`wide`/`mdat`/`moov`, 961,616 B moov at the end),
rewritten with `-c copy -movflags +faststart` while `df`, the directory listing
and `lsof` were sampled every 0.25 s (50 samples).

| Observation | Result |
| :--- | :--- |
| second pass runs at all | yes — `Starting second pass: moving the moov atom to the beginning of the file` |
| descriptors held during the pass | `3r` input, **`4w` output, `5r` the SAME output** |
| temp files seen, any name, 50 samples | **none** — the directory went `{fixture}` → `{fixture, out}` and stopped |
| free space before / min during | 104,207,220,736 B / 99,982,245,888 B |
| **peak consumption** | **4,224,974,848 B against a 4,224,596,893 B output = 1.000×** |
| wall time | 8.1 s mux + 10.9 s relocation = 19.0 s |
| essence across the relocation | video+audio stream md5 identical |

**Verdict: the relocation is IN PLACE.** libavformat reopens its own finished
output for reading and shifts the media data forward; it does not stage a copy
and rename. Therefore, per the operator's instruction, **the disk pre-flight
budget is UNCHANGED** — `rtm_disk_preflight` already requires free ≥ the
source's size, and a faststart build never needs more than that. The cost of
the policy is **time, not space**, and that is what the knob buys back.

**Second measured question (WO implementation note 3): does PyAV trigger the
relocation?** Yes. `poc-remux.py` with `options={"movflags": "+faststart"}`
produced `ftyp moov wide mdat` on a 30 s PAFF cut of `feed.ts`. **No post-pass
fallback was needed** and none was built. `--no-faststart` and `RTM_FASTSTART=0`
each produced `ftyp wide mdat moov`, and all three builds share one video md5.

---

## Item 1 — gate (g)'s MP2 claim, demoted to per-OS empirical

Gate (g) asserted: *"AVFoundation has no MPEG Layer II path for mp4a/.mp2
tracks: no positive report of Layer II decode in QuickTime X/AVFoundation
exists in any container, and this bench measured silence"* (D3, 1.13). A
positive report now exists, from this project, dated and reproducible on this
machine — and the session watched the gate assert the opposite over it.

**Done as the in-house precedent (C56/C72, WO 4.1) did it.** The old
measurement is not called a lie; it is dated and kept, and the new one is dated
beside it. Both now read:

- measured **PLAYING** in QuickTime on this machine **2026-08-29**
  (`plugin-doctor/README.md`, "QuickTime and MP2")
- measured **SILENT** on the D3 bench **2026-08-15** (1.13)

with `C63`'s two-way drift as the reason both can be true, and the operator told
to prove it on the target machine. The spec-conformance objection **survives**
the playability reversal and is now stated wherever the topic appears: `.mp2` is
ffmpeg's convention, not an Apple-documented sample entry (the spec lists no
framed Layer II format) — worth a line in any sidecar.

**Swept as a class (V.1)** — every site restated, not just the one that fired:
`scripts/verify.sh` (the gate's REVIEW text, its `note`, and the D3 comment
block above it), `SKILL.md` (instant-answers row + the 1.13 narrative),
`references/ingest-compatibility.md`, `references/verification-safety.md`,
`references/qtff-claims.md` (C102 marked **REVERSED (playability half)**, the
2026-08-15 record retained verbatim inside it).

**The verdict CLASS is unchanged.** MP2-with-no-PCM was an advisory REVIEW
before and is an advisory REVIEW now — this round changes what is SAID, not
what is scored. Test 117 §5 pins that, so a reworded gate cannot quietly
promote or demote the finding.

**Not done, deliberately.** The WO's optional step 3 (an AVFoundation
audio-render probe as the measuring arm) is **not built**. A bounded Layer II
decode probe is not cheap here, and the WO's own instruction governs: *do not
build a flaky probe to avoid writing an honest sentence.* The dated-citation
form stands alone.

**Pinned by** `tests/regression.d/117-mp2-per-os-claim.sh` (19 assertions):
the fixture arms gate (g); the wording is per-OS with both dates and the
sidecar note; the three categorical sentences are gone (matched against a
whitespace-collapsed report — unflattened, the assertion passes on the very
tree that prints them); the verdict class is still REVIEW; and a tree-wide
sweep finds no categorical claim outside the reversal record.
**Guard G54/P54** (`mut_recategorize_mp2`) re-adds one confident sentence beside
the dates — the realistic regression, since it reads as a summary — and §4 goes
red. The prose case names the forbidden sentence in a comment and stays CLEAN,
which is why §6 reads scripts through `rtm_strip_comments`.

---

## Item 2 — one faststart policy, announced, never automatic

**The defect was three writers with three policies.** Five shell rungs each
carried `MOVFLAGS="+faststart"`; `derive-dts.py` hardcoded the same string again
in a PyAV options dict; `poc-remux.py` set **no movflags at all**. So the POC
rung shipped end-moov while every other rung shipped front-moov, and no log line
anywhere said so. The 2024 VMA deliverable is that artifact — `moov` trailing
24 GB of `mdat`, silently, because the rung that built it was the one rung that
had never been given the policy.

**Now:** one writer per language — `rtm_faststart_on` / `rtm_movflags` /
`rtm_faststart_announce` in `lib-mux.sh`, and `lib_faststart.py` for the two
PyAV rungs. Ten routes converted: `remux.sh`, `dual-track.sh` (build **and** its
copy-cut intermediate), `resync.sh`, `rebuild-paff.sh`, `pairfill-paff.sh`,
`derive-dts.sh` (chapter re-attach), `metadata.sh`, `rung4.sh`, `derive-dts.py`,
`poc-remux.py`. `batch.sh`'s throughput comment, which taught the superseded
"faststart is an access-copy need, not a shelved-master need", now teaches the
policy and the in-place measurement.

**Announced either way**, per route: `RTM_FASTSTART state=on|off route=<name>`.

**Never automatic.** The predicate reads `RTM_FASTSTART` and nothing else — no
size test, no "this looks archival". Test 116 §8 asserts that by reading the
DECISION rather than an output, because a size threshold is invisible to every
assertion that runs on a small fixture. **Guard G53/P53**
(`mut_auto_faststart_optout`) injects exactly that threshold and §8 catches it.

**An empty movflags VALUE is a hard ffmpeg error** (`Unable to parse "movflags"
option value ""` — measured), so "no flags" has to mean "no option". The shell
side builds a bash array and passes it with the tree's absent-safe
`${MOVF[@]+"${MOVF[@]}"}` idiom; `lib_faststart.options()` returns `{}` rather
than `{"movflags": ""}`. Test 116 §2 pins the ffmpeg behaviour that forces this,
so the idiom cannot be "simplified" back into a breakage.

**Every gate runs on the FINAL, post-relocation file** — the item's
non-negotiable — and it holds **by construction**, not by a new step: the
relocation completes when the container closes, inside the writer, before the
part file is censused, verified or blessed. There was no pre-relocation artifact
to accidentally verify, and so no re-verify ordering to suppress; the WO's
second Item-2 guard has no step to attach to and was not invented. What is
pinned instead is the property: §3/§6 assert the blessed output is front-moov.

**Pinned by** `tests/regression.d/116-faststart-policy.sh` (20 assertions):
the helper's defaults, both opt-outs and the empty case; the ffmpeg parse error
that motivates the array; a real `remux.sh` build front-moov and announced;
the same rung opted out, end-moov, announced, same essence; the Python module;
the class-sweep shape (nothing outside the two policy writers names
`+faststart`); and the never-automatic decision.
**Guard G52/P52** (`mut_suppress_faststart_announce`) drops the announcement —
a build that silently front-moovs is still a divergence, just an unreadable one.

**Jurisdiction (III.2).** §6 builds through the POC rung for real, but true PAFF
cannot be synthesized on this bench — x264 emits MBAFF frames, not field
pictures, so the fixture tree has none. §6 therefore runs only when
`RTM_PAFF_FIXTURE` names a PAFF source and is **SKIPPED, announced**, otherwise;
the measured result (front-moov on a 30 s cut of `feed.ts`) is recorded above.
Everything else in the file is unconditional.

---

## Bench

`bash tests/regression.sh` → **313 passed, 0 failed** (311 at 1.16.6; +2
sub-suites). `MA_OUTDIR=… bash tests/mutation-audit.sh` → **`MA_SUMMARY
total=97 bad=0 verdict=pass`**, 57 CAUGHT / 40 CLEAN, rc 0 — verdict read from
`$OUTDIR/VERDICT`, never from a remembered rc. Bench: macOS 26.6.2, ffmpeg
9.0.1, PyAV 18.1.0. Run sequentially (suite, then audit).

**The first bench run was RED, and the defect was this round's own test.**
`116-faststart-policy.sh` §8 read the decision with `printf '%s' "$body" |
grep -q …`, twice — which is precisely the shape 94 §10 forbids suite-wide (the
1.15.2 SIGPIPE class: an early-exit reader that can kill its own writer). The
blast radius is worth recording, because it is what a shared baseline looks like
when it breaks: `94-rot-sweep` went red, 29 guards name 94 as their test and so
reported **BASE-RED** rather than grading a mutation against a failing baseline,
and `90-harness-honesty` §7 — whose clean-run probe is `mutation-audit.sh G03`,
and **G03's test is 94** — reported `bad=1` where it wanted `bad=0`. One defect,
32 bad cases, two red sub-suites. Fixed by writing the body to a file and
grepping the file (a file has no writer to signal, so it is outside the class).
The 1.16.5 observation channel is what made this legible in one read: the
verdict file said `bad=32` with BASE-RED reasons, instead of 32 mutation
failures that would have been read as guard bugs.

## Operator step (carried forward, not done here)

`plugin-doctor/FOLLOWUP-1.16.6.md`'s third item — settling gates (h)/(k) on
`test.mov` with `RTM_STRUCT_MAX_BYTES=0` — is an operator action on an artifact
outside this repo and is unaffected by these two items.

# Changelog — remuxing-to-mov

History moved here from the `plugin.json` description in 1.15.0 (the orphaned
1.14 Phase-6 packaging item). Detailed doctrine lives in `skills/remuxing-to-mov/
SKILL.md` and `references/`; every empirical claim below is dated in the docs.

## 1.15.18 — the review round (2026-08-28)

A `/code-review` pass over the 1.15.17 diff returned 15 verified findings
(26 candidates, 2 refuted). All 15 are fixed here; the two that generalize
are recorded first, because each is a rule the last round *thought* it had
already applied.

**"Ask, don't model" was applied to one route.** `clean.sh` asked zero-base
with `--preflight-only` (1.15.13) and still printed the `trim-to-idr.sh`
command ready-to-run off the ts-health counter alone — its own model of the
other Tier-1 tool. Measured: a head trim-to-idr refuses (no keyframe in the
scan window, an open-GOP boundary, the missing-timestamp class) got a
"ready to run" command that FAILed rc=1 with nothing written — the F12 class
the 1.15.13 comment had called "structurally impossible on every axis".
`trim-to-idr.sh --preflight-only` now exists (steps 1-2 only, writes nothing:
exit 0 eligible with a `TTI_PREFLIGHT` row, 2 would-refuse with its reasons on
stderr, anything else = could not run — the zero-base convention), the clinic
asks it inside the pre-key branch and relays the answer in the tool's words,
93 §5 pins the ask by call shape, and 93 §7 is the negative control
(`RTM_IDR_WINDOW=1` on the mid-GOP fixture: no ready-to-run command, refusal
relayed, `routes=` clean; the default window still offers it and §4 runs it to
a blessed build). zero-base's own pre-flight now refuses a mid-GOP head too
(it built the whole re-wrap and died at verify-source, v_drop=102, on a file
the clinic had offered it for), and 93 §4 requires a BLESSED build (0/10) of
every offered route, not merely "not rc=2". The clinic's verdict line and
comment now claim only what is true: eligibility is about the source; the
writer lock and disk headroom are each tool's run-time checks.

**A one-writer refactor is done only when every consumer asks AND maps.**
1.15.17 gave the census verdict one writer and 94 §4 checked that every
`census_rc` consumer calls `rtm_census_failed`. Three builders did — and
still ended `exit "$census_rc"`, the raw census rc as the process exit
(trim-to-idr, rung4, rebuild-paff). Today that is 0 or 10; the first widening
of `rtm_census_failed` — the one-site edit the writer exists for — makes them
exit 11 (REFUSED, a false verdict batch/mov switch on) or 12 (outside the
contract) *after* the `mv -f` of the blessed output, while the builders that
ask stay in contract. All three now `if rtm_census_review; then exit 10; fi;
exit 0`, and 94 §4 pins "no builder exits with the raw census rc"
(mutation-audit G32/P32).

**The harness that certifies the guards had blind spots of its own.**
`tests/mutation-audit.sh`: (a) its EXIT trap `rm -rf`'d an operator-named
`MA_OUTDIR` — including on an early `exit 2` — the 1.15.12 class this very
file exists to police; now it removes only what it created. (b) The sandbox
symlinked the REAL `tests/fixtures/` directory, so a test that regenerates a
missing fixture wrote into the real tree, and `MA_JOBS>1` raced `ffmpeg -y`
on one shared `.part`; now a real directory of per-file links. (c) A prose
case whose marked PASS survived while the RUN went red was reported CLEAN —
P11's comment tripped 92 §4's un-stripped per-consumer pin and the shipped
"49/49, none crying wolf" was false; that verdict is now `RED-ELSEWHERE`, and
a test red before any mutation reads `BASE-RED`. (d) The comment stripper
`sed 's/#.*//'` — pasted at 26 sites across seven tests — truncated code at
`${v#pat}`, `${v##*/}`, `$#`, `${#a}` and ffprobe's `'%+#1'` (73 such lines
in 33 scripts, 15 losing an `exit`), so 94 §6's errexit detector cried wolf
on a correct one-line region and was blind to an exit past one; one
`rtm_strip_comments` (whitespace-anchored `#`) in `tests/lib-harness.sh`,
with `grepq`/`grepqe` moved there from their seven pasted copies.

**Tests that had gone vacuous, each demonstrated with a mutation that stayed
green:** 84's A4 lockstep pin had been weakened to "each body mentions
`RTM_CONFESSION_RE`" (a `|dts discontinuity` widening passed) — it compares
the exact grep argument again; 84's mktemp shim intercepted only the exact
argv `-d`, so `mktemp -d -t x` passed through to the darwin temp dir and "no
mktemp leak" PASSed over ~40 MB leaked — the shim now takes every path-less
`-d` form, logs each interception, and the test asserts it FIRED (a
path-template form turns the test red, "the leak watch is vacuous", instead
of green); 92 §4's per-consumer pins grepped RAW source while the loop above
stripped comments (red on a benign comment, green with the call deleted) —
stripped and pinned by call shape. Also: `clean.sh`'s zero-base relay
labelled every nonzero rc "refuses at pre-flight" (rc=1 = could not run, an
UNPROVEN presented as REFUSED), relayed stdout progress naming the clinic's
soon-deleted temp dir, and its display pipeline had no `|| true` under
pipefail (a header-only relay killed the clinic with exit 1 = DAMAGED and no
`CLEAN_SUMMARY`); it now captures stderr only, distinguishes 2 from the rest,
and cannot die displaying.

`hunt/tools/cdn/app.sh` (reviewed in the same diff): the Vimeo data-attribute
matcher had both narrowed (`{6,}` dropped pre-2008 5-digit `data-vimeo-id`)
and widened (any `data-*vimeo*` name — `data-vimeo-start="123456"` came back
as an id and sent `handle_vimeo` after a stranger's upload); now
`data-vimeo-id` at any length, and a generic carrier only when the name ENDS
at `vimeo`/`-video`/`-id`. The JWT scope heuristic had made the API path
fail-closed with its warning silenced at two of three call sites — unknown now
still tries the API. The Squarespace manifest branch reported every yt-dlp
failure as "yt-dlp required" with stderr discarded — its output is visible,
with the site UA, the page as Referer and retries like the Vimeo path. A
direct `video.squarespace-cdn.com` URL on argv (the lever the registry
documents) finally has an intercept. `normalize_url` handles IPv4, localhost,
userinfo@ and underscore hosts and no longer reads a scheme inside the query
as the URL's own; a mistyped list-file name (`urls.txt`) says "no such file"
instead of probing `https://urls.txt` as a phantom failure. Offline suite
172/172 (+18).

Suite 292/292 (the banner counts one row per sub-suite; the changed files grew
inside it — 93: 22 -> 27 assertions, 94: 16 -> 22, 84: 19 -> 20, 92: 25 -> 27),
`tests/mutation-audit.sh` **57/57 in contract** on the shipped tree (36 defect
cases CAUGHT, 21 prose CLEAN; four new cases G32/P32/G33/P33), and the
review's own measured scenarios re-run green on scratch copies (the `-t`
mktemp form's leak is caught; the window-1 head is withheld).

Residuals, recorded not fixed: `trim-to-idr`'s pre-flight runs `gop-probe`
(the one decode-heavy step) on every pre-key source the clinic meets — asked
only inside the pre-key branch, never unconditionally; Tier-2 routes stay
outside 93's invariant because they are consent-gated by design; `app.sh`'s
five-copy tier scaffold and fetch-once refactors are deferred for want of
offline coverage of their blast radius.

## 1.15.17 — the guards' own audit (2026-08-28)

1.15.15 built the standing sweep and recorded that **two of its five guards
were vacuous on first draft** — one satisfied by the COMMENT describing the
idiom, one using `grep -l` so a second definition inside one file was
invisible. Both would have shipped green while guarding nothing. The older
tree-wide guards had never been mutation-tested at all. This round tests the
tests.

**`tests/mutation-audit.sh` — the guards' own test.** Two lanes, because a
guard fails in two directions: *defect* introduces the exact defect the guard
claims to catch and requires its assertion to flip PASS → FAIL; *prose*
introduces a benign COMMENT quoting the same idiom and requires it to stay
PASS. Every case runs in a throwaway copy of the plugin (fixtures symlinked,
never copied), so the real tree is never written to — which retires by
construction the restore hazard CONSTITUTION.md V.2 records. Four harness
properties earned the hard way while writing it, each after a case reported a
finding that was really a harness bug:

- a mutation whose regex matches nothing reports `MUTATE-NOOP` instead of
  masquerading as a vacuous guard (the `BEGIN{n=0}` mutation matched nothing —
  a `; ?` that required a semicolon the tree does not have — and read MISSED);
- **a mutation must not land in a COMMENT.** Re-aimed, that same mutation hit
  the comment ABOVE the code that explains why `BEGIN{n=0}` is load-bearing.
  Mutating prose proves nothing; it is now line-anchored;
- a verdict is decided by whether the guard's PASS line survived plus the run's
  own exit status — never by matching one marker against both wordings, because
  house style gives an assertion two different ones ("defined exactly once" vs
  "has 2 definitions");
- a guard that emits ONE PASS LINE PER ITEM (93 §4 judges every offered route)
  needs the FAIL text named instead, or the items that legitimately keep passing
  read as MISSED — hence the optional `FAILMARK` column.

And one mutation was simply wrong: `perl -pi -e 's/…/if [ "$ZB_RC" -ge 0 ]/'`
writes an EMPTY `$ZB_RC`, because in a Perl replacement that is a Perl variable.
It produced `[ "" -ge 0 ]`, so the clinic offered no route at all and the case
looked like a caught defect for entirely the wrong reason.

**Measured, 37 cases over 23 tree-wide assertions in 10 test files** (the work
order named 8; the sweep found two more — 73 §2's `program=` class guard and
88 §8's locale sweep). **20 of 25 defect cases CAUGHT; 6 of 12 prose cases
CLEAN.** The eleven that were not:

- **Three guards were VACUOUS.** `92` §4's merge count used `grep -l`, counting
  FILES — a second copy pasted into `lib-probe.sh` itself was invisible (the
  identical blind spot 94 §5 was rewritten to close, still live one file over).
  `88` §8 accepted a script that merely *mentioned* `lib-probe.sh` in a comment,
  so a new entry point could ship with the float gates locale-exposed while
  naming the lib that pins them. `93` §5 asserted `--preflight-only` appears in
  `clean.sh` — and `clean.sh`'s own comment says `--preflight-only`, so the
  mutation that broke the actual zero-base CALL left the guard green. All three
  now read comment-stripped source and count occurrences, not files;
  re-mutated to CAUGHT.
- **Six guards FALSE-POSITIVED on prose** — 94 §4 (`census_rc`), 92 §4
  (`idx in seen`), 92 §4 (the merge), 41 §3 (`qt-undecodable`), 73 §2
  (`program= | head`), 93 §6 (`NPROG`): each is a bare `grep` over unstripped
  source, and each tripped on a comment that recorded the defect it forbids.
  A guard that cries wolf gets disabled, and then its class is unguarded AND
  believed guarded (V.3). All six strip comments now and report basenames
  instead of full sandbox paths.
- **Two were harness bugs, not findings** (`MUTATE-NOOP`, and a mutation that
  ADDS a roster row having no baseline line to lose) — both fixed in the
  harness, both re-run CAUGHT.

**And then the harness caught a defect in this round's own hardening.** The
comment-stripping fixes above read source as `sed 's/#.*//' "$f" | grep -q PAT`
— and so did two of 1.15.15's original guards. `grep -q` closes the pipe on the
FIRST match and SIGPIPEs its writer: the same early-exit shape as the 1.15.2
`ffp … | head -1` field defect, which test 91 §5 pins for `scripts/` and nothing
pinned for the suite's own guards. Measured on `verify.sh` (95 KB):
`printf: write error: Broken pipe`, and under `pipefail` the non-zero pipeline
flipped 88 §8 from PASS to a **FALSE FAIL** naming a file that does source
`lib-probe.sh`. The same code passed on the bench and failed in the audit's
sandbox — a load-dependent race, which is precisely why a green bench is not
evidence that a guard is sound. Every source-scanning reader in the suite now goes through
`grepq`/`grepqe` (`grep -c`, reads to EOF), and **94 §10** sweeps for the shape,
excluding only this section and `mutation-audit.sh` — the one file whose job is
to author the defects these guards forbid.

**And then it caught a third.** Converting `grep -q -- 'PAT'` to `grepq -- 'PAT'`
left the `--` in place — but the helper takes the pattern as `$1`, so two of
93 §5's pins searched for the literal string `--`, matched every long option in
`clean.sh`, and went green while guarding nothing. The mutation that breaks the
actual `zero-base --preflight-only` CALL passed straight through it. `grepq` now
swallows a leading `--` instead of searching for it, and the call sites are
fixed. Three vacuous guards found in the pre-existing suite, and three more
introduced and caught in this round's own work — the harness earned itself
several times over, and none of the three would have shown on a green bench.

**Item 4 — the census verdict has one writer.** `rc 0 or 10 is acceptable,
anything else is a census failure` was re-implemented in all 10 builders.
Measured before flattening: the semantic was uniform — no builder differed on
anything but wording — so this was a maintenance hazard, not a live defect.
`rtm_census_failed` / `rtm_census_review` (lib-mux.sh) own the verdict; the
stage name, message, retention pointer, exit contract and machine rows stay
per-builder, because that is presentation, not the fact (IV.1). Both predicates
fail CLOSED on an unreadable rc (III.1): a code nobody could read is never a
blessing. Test 94 §4 now pins the single writer rather than the uniformity of
copies, and IV.3 discharges `census_rc`.

**Item 3 — the classes not yet swept, named and settled.**

- **`set +e` regions — enumerated, guard added (94 §6).** 42 real regions (the
  work order's ~45 counted comment mentions). Every one restores `set -e`, the
  longest spans 3 lines, and none exits while errexit is disarmed. The guard
  pairs the tokens IN ORDER over comment-stripped source: 29 of the 42 are
  written `set +e; cmd; rc=$?; set -e` on ONE line, and a line-wise reader calls
  every one of them unbalanced — measured, and the reason the first draft of
  this analysis was wrong.
- **A new class, met in this round's own harness (94 §9).** `local a="$1"
  b="pre-$a"` does NOT work: `local` is a builtin, so every argument is
  word-expanded BEFORE any assignment, and `$a` there is the CALLER's `a` under
  dynamic scope — or empty. Measured on this bench, bash 3.2.57:
  `f(){ local a="$1" b="pre-$a"; echo "$b"; }; f XYZ` prints `pre-`. The
  mutation harness shipped with it — `local id="$1" sb="$OUTDIR/sb-$id"` named
  every sandbox from whatever `id` the caller happened to hold: unique per case
  by luck, EMPTY for every baseline, so ten baselines silently overwrote one
  directory. Swept: `scripts/` is clean, the harness was the only instance, and
  the class is now enumerated every run. The detector is deliberately narrow
  (simple `local NAME=VALUE` words, plain string search so a value cannot inject
  a regex) and unit-checked against the legitimate multi-assignment `local`s in
  `lib-mux.sh`, which it must not flag.

- **The confession vocabulary had FIVE copies, and only two were pinned.**
  `84`'s A4 lockstep held `lib-paff.sh`'s two counters byte-identical; the same
  alternation also sat in `derive-dts.sh`, `remux.sh` and `pairfill-paff.sh`
  display greps, unguarded — free to drift exactly the way 1.14 drifted the
  pair A4 was written for. One definition now (`RTM_CONFESSION_RE`), the flags
  stay per-site, A4 pins the writer, and 94 §7 counts the copies.
  `lib-rewrap.sh` keeps its deliberately narrower pattern: splitting nudges from
  hard confessions is a different question.
- **The QuickTime-native audio table stays duplicated, and is now held in
  step (94 §8).** `aac|alac|mp3|pcm_*|eac3` appears as a case arm four times
  (mov.sh twice, remux.sh, pairfill-paff.sh) and is deliberately not
  centralized — mov.sh's classifiers are sourced by the `RTM_TEST` harness and
  each arm reads at its point of decision. E-AC-3's membership has drifted
  before (1.15.9 F7 found the reference page still calling it a dual-track class
  rounds after the code classified it native). It moves into IV.3's standing
  slot as `census_rc` leaves it.
- **The clinic's OTHER routes.** 1.15.13 made `clean.sh` ask `zero-base` for
  its own verdict, and 93 §4 pinned the invariant — for that one route. The
  clinic prints three ready-to-run commands. §4 now reads the routes out of the
  clinic's OWN output and judges every Tier-1 command it offers, so a route
  added later joins the invariant the day it lands; a `midgop` profile
  (`late-sps.ts`) was added so the `trim-to-idr` arm is actually exercised
  rather than never offered. Measured: 3 offered routes across 4 profiles, none
  refuses at pre-flight. Tier 2 is deliberately out of scope — the clinic's own
  verdict line says Tier-2 needs the operator's `--discard-content`.
- **Cross-script condition modelling: investigated, one instance, no others.**
  `auto.sh` does not model its children — it ATTEMPTS a rung and reacts to
  `RESULT`, and its own comment records that pairfill's capability refusal
  "lands here as a generic RESULT=FAIL". `mov.sh` hands the PAFF path to
  `auto.sh`. `diagnose.sh` is report-only; the one fully-formed command it
  prints is `resync.sh`, whose only refusal (exit 11, mid-stream layout change)
  is discovered by measuring layouts mid-run — not a foregone pre-flight
  refusal, and not knowable without doing resync's own work. Recorded, not
  changed.
- **Scratch cannot be redirected on macOS — named limitation, written down.**
  Re-measured 2026-08-28: `mktemp -d` and `mktemp -d -t PREFIX` both ignore
  `TMPDIR` and land in `/var/folders/…/T`; only an explicit template obeys it.
  14 `mktemp -d` sites and ~12 bare `mktemp` sites are affected identically. It
  is NOT a defect in the disk pre-flight — `rtm_disk_preflight` receives the
  ACTUAL staging path (`rebuild-paff.sh` passes its own `$WORK`), so it measures
  the volume that really gets written. The limit is operator control, and it is
  now in `references/known-limits.md`.
- **Investigated and sound, no guard owed:** the codec RANK table
  (lossless/lossy-high/lossy-low) exists once, in remux.sh's plan awk —
  `auto.sh`'s `rank` is a different fact (verdict ranking); the QTFF
  sample-entry allowlist exists once, in verify.sh (its second appearance is the
  comment that documents it).

CONSTITUTION.md updated where this round falsified it: IV.3's standing example,
V.2's test (the harness), V.4's ship checklist. `tests/README.md` documents the
harness as the guards' own test.

Suite 292/292 green (the banner counts one row per sub-suite; the changed files
grew inside it — 94: 7 -> 16 assertions, 93: 19 -> 22, 84: 18 -> 20), and the
final `tests/mutation-audit.sh` sweep is **49/49 in contract** on the shipped
tree: 32 defect cases CAUGHT, 17 prose cases CLEAN, none missed, none crying
wolf. `claude plugin validate --strict` green on plugin and marketplace.

Residuals recorded here rather than fixed: `zero-base.sh` returns rc=1 (not a
pre-flight refusal) on the mid-GOP fixture the clinic offers it for — a measured
outcome from its own gates, which the clinic could not know without running it,
so the invariant deliberately forbids only rc=2. Tier-2 routes stay outside the
invariant, because the clinic's own verdict line says Tier-2 needs the
operator's `--discard-content`. The 94 §9 detector is narrow by choice (simple
`local NAME=VALUE` words, one-line function bodies included, `;`-separated
fragments): an exotic shape can slip past it, which beats a guard that cries
wolf.

## 1.15.16 — CONSTITUTION.md (2026-08-27)

The rules of this plugin were distributed across work orders, checkups,
changelog entries and code comments, cited by shorthand — `WO 3.4`, `D5`,
`A1`, `F12`. Measured: `scripts/` and `tests/` carry hundreds of such
citations, 48 to one checkup document alone. Every one resolves. That was
never the problem.

The problem is what resolving one GETS you: **where a claim was written, not
whether it is still true.** A reader who doubts a rule must find the document
and take its word, and documents go stale silently — the authoring session's
own memory note asserted these work orders were "untracked, not committed";
they have since been committed, so the note was true when written and false
when read.

`CONSTITUTION.md` inverts the authority. Each amendment states the rule so it
stands without following any reference, the failure it prevents as something
MEASURED, and **a test to run if you doubt it**. Provenance lines are
explicitly discardable. Articles: what may be done to media; how verdicts are
reached; how evidence is collected; how the code is structured; how the guards
are guarded.

- All 14 cited test files verified to EXIST and PASS at the time of writing —
  a constitution whose tests do not run is the disease, not the cure.
- **V.2's example was wrong on first draft, and verifying it proved its own
  point.** It used `git checkout` to restore after a mutation. Run against a
  tree with 1.15.14 still uncommitted, that reverted `lib-probe.sh` to a
  version predating `rtm_aud_manifest` and destroyed the round — and the guard
  then went GREEN, because the reverted file no longer contained the construct
  being guarded, so the check skipped it. **A mutation test with a wrong
  restore can report success while having deleted the thing under test.** The
  amendment now backs up by copy and verifies the restore, not just the red.
  (The work survived only because it had already been synced to the installed
  copy — which is itself amendment V.4.)
- Standing rule for amendments: if you cannot write the test, you have a
  preference, not an amendment. Say so and leave it out.

## 1.15.15 — "the standing sweep" round (2026-08-27)

The method, not another instance. 1.15.10/.11/.12 were each found by tripping
over them — and .12 only because a suite run happened to share a machine with
a 24 GB build. Finding a CLASS and then waiting to meet its next INSTANCE is
not a method. Test **94** enumerates every class this plugin has actually
shipped, mechanically, over the whole tree, every run.

- **Guards (all five mutation-verified — a guard nobody has seen fail is a
  guard nobody knows works):**
  1. every script and test parses under `bash -n` — the exact detector for the
     apostrophe-in-single-quoted-awk trap, hit TWICE in one session;
  2. every counter-subscripted awk initializes its counter (1.15.10);
  3. nothing scans shared temp ground for files it did not write (1.15.12);
  4. all 10 `census_rc` consumers treat rc=10 as REVIEW, not error;
  5. no centralized fact grows a second definition.
- **Two of the five were VACUOUS when first written, and mutation testing
  caught both.** §2's pattern `BEGIN{ *n=0` is also how the idiom is DESCRIBED,
  so a comment mentioning it satisfied the guard — comments are now stripped
  first. §5 used `grep -l`, counting FILES, so a second definition pasted into
  the same file was invisible — it now counts definitions. Both would have
  shipped green and guarded nothing.
- **§3 was deliberately narrowed.** The first form audited every `rm -rf` and
  false-positived on `.lock` paths, on a string assertion, and on itself. A
  tree-wide guard that cries wolf gets disabled — and then the class is
  unguarded AND believed guarded. It now pins the precise defect shape (the
  scan, not the delete) with zero false positives, and a negative control
  proves it catches a reintroduction.
- Classes swept and found CLEAN, recorded so they are not re-chased: no
  `ffp … | head -1` code sites survive (the one hit is a comment documenting
  the idiom — 1.15.9 D3 genuinely holds); exactly ONE site uses the bare
  counter-subscript shape and it is initialized; no apostrophe-in-awk survives;
  every `rm -rf` targets owned scratch.
- **Investigated and found SOUND** (recorded so it is not re-chased): the
  colour-primaries probe is duplicated 5x with drifted error handling
  (`|| true` in three, absent in two), which looked like A1 on the colour axis
  — a failed probe silently dropping `write_colr`. MEASURED with a PATH shim
  failing only that query: the two outputs are BYTE-IDENTICAL. `movenc` writes
  `colr` from input stream parameters regardless, so the flag is a no-op here
  and the drift has no observable consequence. Not a defect.
- **Known duplication left standing, deliberately:** `census_rc` handling is 9
  genuinely different forms across 10 builders. The wrapping differs
  legitimately per builder; the SEMANTIC is uniform and now pinned by §4. This
  is the lockstep treatment the mux-confession vocabularies already get:
  duplication not being refactored today must at least be held in step.

## 1.15.14 — "one writer: the audio manifest" round (2026-08-27)

1.15.13 rule 2, applied to the outstanding case it named. 1.15.10 fixed the
COPY; this fixes the COPYING.

- **What was duplicated:** the audio-manifest ffprobe query, the field-parse
  loop, and the WO 3.4 view-merge existed in full in BOTH `probe.sh` and
  `remux.sh`. WO 3.4 was applied to one of them, so `probe.sh` reported
  `PR_AUD_n_LANG=und` for four `eng` tracks for four versions until the field
  run caught it. Nothing prevented the next edit from landing in one copy
  again.
- **The single writer:** `rtm_aud_manifest IN [ERRFILE]` in `lib-probe.sh`.
  stdout is one line per track, already merged, in track order —
  `ord|codec|channels|layout|lang`. rc is ffprobe's own status, passed through
  untouched, because EMPTY != ABSENT (A1): a failed probe must never read as
  "no audio", so the function declines to guess and the CALLER decides how
  loudly to refuse. It runs the probe in `if` context rather than `set +e`, so
  a failing probe cannot disarm the caller's errexit for the lines after it.
- **What deliberately did NOT move.** The two consumers differ in exactly two
  ways, and both stay local: how loudly to refuse a failed probe (`probe.sh`
  emits the `PR_AUD_MANIFEST=failed` sentinel and returns 1; `remux.sh` is a
  pre-flight refusal, exit 2, quoting probe stderr), and the empty-layout
  fallback — `probe.sh` prints `unknown`, `remux.sh` synthesizes `Nch` for its
  curation key. The shared writer therefore emits RAW values with an empty
  layout left empty; imposing either fallback would have made one consumer
  wrong. Sharing the FACT is the goal; sharing the presentation is a
  different bug.
- **Test 92 §4 is now a class guard rather than a per-copy check.** It asserts
  the merge exists in exactly ONE file, that the file is `lib-probe.sh`, that
  both consumers call `rtm_aud_manifest` and hold no private copy, and that
  each keeps its own fallback. "Does this copy merge correctly" is a question
  that scales with the number of copies; "does the merge exist once" stays one
  assertion forever. 92 goes 19 -> 26.
- Same apostrophe trap as 1.15.10, hit again and recorded again: a `'` inside
  an awk program in single quotes (`rtm_aud_manifest's`) closes the shell
  string. Both former copies avoided possessives for this reason.

## 1.15.13 — "ask, do not model" round (2026-08-27)

Not a defect round. A structural answer to why the defect rounds keep coming.

**The pattern.** 1.15.10, 1.15.11 and 1.15.12 were found in a single field
session, and they are one shape wearing three coats: a fact written in two
places and corrected in one.

| round | the fact | written in | fixed in |
|---|---|---|---|
| 1.15.10 | how to read a per-track audio manifest | `probe.sh` + `remux.sh` | `remux.sh` |
| 1.15.11 | what `zero-base` refuses | `zero-base.sh` + `clean.sh`'s guard | `zero-base.sh` + 2 of 3 axes |
| 1.15.12 | which scratch directory is mine | the code + the test's scanner | neither |

None is a muxing bug. The plugin's own 1.15.2 note — "every defect sat in the
honesty machinery, never in the muxing" — is true and incomplete: they sit
specifically in DUPLICATED knowledge, and the repair has been to add one more
enumerated condition. Enumeration cannot close. Real sources supply axes
faster than a guard can list them, so each round ships the next round's bug.

**The change.** `clean.sh` no longer re-derives `zero-base`'s refusal
conditions. `zero-base.sh` gains `--preflight-only`: it runs ITS OWN refusal
logic, writes nothing, and exits 0 eligible / 2 refused; `--src-tsh` (the
`verify-source` convention — one scanner, one truth) hands it the whole-file
scan `clean.sh` already took, so asking costs no second pass. The clinic then
RELAYS the refusal verbatim rather than paraphrasing it, so it holds no copy
of the reasoning that can drift.

The five-term modelled guard becomes one asked question:

```
-  if [ "$IS_TS" = yes ] && [ "$(tget TSH_BACK)" = 0 ] && [ "$(tget TSH_DUP)" = 0 ] \
-     && [ "$(tget TSH_VIDEO)" != none ] && [ "${NPROG:-0}" -le 1 ] \
-     && [ "$ZB_PAFF_OK" = yes ]; then
+  if [ "$ZB_RC" -eq 0 ]; then
```

Offering a route that refuses is now structurally impossible — on every axis,
including ones nobody has met yet. 1.15.11's `ZB_PAFF_OK` term is deleted: it
was the right fix to the wrong layer, and keeping it would preserve the model
the round exists to remove.

**Test 93 §6 is the claim, made falsifiable.** It runs the clinic on a
MULTI-PROGRAM source — F12's axis — and asserts three things: no ready-to-run
command is offered, `zero-base` does refuse it (rc=2, so the ask matched the
authority), and `clean.sh` contains no multi-program code at all. An axis
closing in a driver that has never heard of it is the whole thesis. §5 pins
the structure (the ask is made, the scan is shared, no hand-mirrored term has
crept back); §4's invariant — a printed command must not refuse — remains the
general guard over all of it.

**Recorded as the standing rule, in preference to more guards:**
1. Ask the authority, never model it. A driver that can name another script's
   refusal conditions is already wrong.
2. One writer per fact. (Still outstanding: the audio manifest lives twice,
   in `probe.sh` and `remux.sh` — 1.15.10 fixed the copy, not the copying.
   It belongs in `lib-probe.sh`, consumed by both.)
3. Invariants over enumerations in tests. Verdicts may stay conservative —
   gate (g) answering REVIEW on unproven attribution is correct and should
   not change. It is the GUARDS that must be general, not the verdicts.

## 1.15.12 — "a test with no jurisdiction" round (2026-08-27)

Test-only round (the 1.15.8 harness precedent: the bench is versioned too).
Surfaced by running the suite alongside the 24 GB field build — the first
time this bench has been asked to share a machine.

- **The defect:** test 84's D2 leak watch scanned the WHOLE shared darwin
  temp dir for any `tmp.*/s` newer than a marker file. It had no jurisdiction
  over what it found. Two consequences, both measured: it **false-FAILed**
  when a concurrent process created matching scratch inside its window (the
  definitive 1.15.11 suite run came back 290/1 for exactly this, with the
  build's `verify.sh` scratch as the culprit); and its else-arm
  **`rm -rf`'d the directory it found** — a live scratch dir belonging to
  another process. A test that deletes another process's working files is a
  hazard, not a check; had the timing shifted slightly it would have been
  deleting from under a 24 GB archival build.
- **Why the old design existed:** re-measured and CONFIRMED — macOS
  `mktemp -d` with no template ignores `TMPDIR`, and so does `-t`; only an
  explicit template honours it. So the watch could not simply point at a
  private `TMPDIR`, and fell back to scanning shared ground.
- **The fix:** shim `mktemp` beside the existing `ffmpeg` shim — the code
  under test calls it bare, so PATH interception is exact — and force its
  scratch into a test-owned directory. The watch then looks only where this
  run could have written: jurisdiction stated, no time window, no foreign
  deletion. The shim intercepts ONLY the bare `-d` form; anything carrying
  its own template passes through.
- **Two new assertions** pin both halves: a foreign scratch dir planted
  during the window is neither mistaken for this run's leak nor deleted.
  Test 84 goes 16 -> 18.
- Investigated and found SOUND (recorded so it is not re-chased): the
  `mktemp`/`TMPDIR` split does NOT affect `rtm_disk_preflight`.
  `rebuild-paff.sh` passes the ACTUAL `$WORK` path it received from `mktemp`
  as STAGE_DIR, so the preflight measures the volume genuinely being staged
  to, whatever `TMPDIR` says. The header comment's "the TMPDIR volume" is
  loose wording over correct-by-construction code. The real residual is a
  LIMITATION, not a bug: on macOS an operator cannot redirect plugin scratch
  to another volume via `TMPDIR`.

## 1.15.11 — "the clinic must not hand you a refusal" round (2026-08-27)

Second defect from the same field run. Test **93**, red-verified against
1.15.10 (9 red of 15).

- **The defect:** `clean.sh` printed
  `TIER 1 (structural): scripts/zero-base.sh "feed.ts" OUT.ts` as ready to
  run for a source `zero-base.sh` **refuses at pre-flight** — while step 1 of
  the same report printed `paff=yes`, three lines above.
- **It is 1.15.7 F12's rule, on the axis F12 did not close.** F12's own
  entry reads "clean.sh printed a ready-to-run zero-base command that refuses
  exit 2 on a 2-program TS, measured"; B1 closed no-video. The guard tested
  `IS_TS / TSH_BACK / TSH_DUP / TSH_VIDEO / NPROG` and its comment named its
  coverage as "B1 … and F12". **PAFF was never added** — even though PAFF is
  the refusal 1.15.2 Defect C introduced, *for this exact capture*, and BOTH
  of zero-base's PAFF arms refuse (1.15.2 pair-timestamped; 1.15.7 F1
  full-timestamp, as policy). `PF_PAFF`/`PF_HALF_TS` were already in the
  `--kv` block the driver parses for `PR_NPROG`.
- **The fix:** `ZB_PAFF_OK` joins the Tier-1 guard, plus a PAFF-specific
  else-arm — named separately from the generic one because PAFF is not a
  defect to correct but a source whose `.ts` IS the master, so the honest
  route is `pairfill-paff.sh`, not a re-wrap. The generic arm keeps its
  wording verbatim (tests 72/88 pins hold).
- **Test 93 §4 is the part that matters:** rather than enumerate refusals
  forever, it pins the INVARIANT — *if the clinic printed the ready-to-run
  command, running it must not come back as a pre-flight refusal* — swept
  across all three profiles. That assertion would have caught B1, F12 **and**
  this one before any of them shipped.
- Bench note in the test: the house pair-injection table is calibrated to a
  29.97 nominal rate; on a 25 fps fixture the ratio lands at 1.6 and reads
  `paff=no`. Also recorded: the pre-fix §5 guard ("does clean.sh mention
  PF_PAFF anywhere") passed before the fix — step 1 already prints `paff=` —
  so it was vacuous and now pins the gate term itself.

## 1.15.10 — "the unfixed sibling" round (2026-08-27)

Found by the field battery on the 2022-08-28 VMA capture — the run that was
supposed to be a victory lap for 1.15.2–1.15.9. Test **92**, red-verified
against 1df5941 (9 red of 19).

- **The defect:** a program-bearing TS emits every stream section TWICE (a
  bare top-level view, then the in-program view) and only ONE carries the
  PMT tags — language. `probe.sh`'s per-track audio manifest deduped by
  index KEEP-FIRST (`if(idx in seen) next`), keeping whichever view arrived
  first — the tag-less one — so `PR_AUD_n_LANG` read `und` for every track
  on a source whose tracks are all `eng`. Measured on the field capture:
  `remux.sh --print-plan` said `lang=eng` ×4 while `probe.sh --kv` said
  `und` ×4, **in the same run, on the same file**.
- **This is WO 3.4, unapplied.** 3.4 diagnosed this exact bug ("the
  keep-first dedupe read every TS track as lang=und"), fixed it at
  `remux.sh`'s manifest with a field-by-field MERGE, and pinned it in test
  34 — but only against `remux.sh`'s PLAN. The sibling manifest in
  `probe.sh` was never converted, and no test asserted `probe.sh`'s
  `PR_AUD_*_LANG`, so the machine API kept shipping `und` for four
  versions while the human `-- audio --` section of the same run printed
  `eng`. The fix is 3.4's merge, ported verbatim — including its
  `BEGIN{n=0}` (load-bearing: an uninitialized `n` used as an array
  subscript is the empty string, not 0, so record 0 lands at `C[""]` while
  `n++` still counts it — the porting attempt hit it immediately, exactly
  as the remux.sh note warns).
- **Blast radius, swept not assumed:** `PR_AUD_*_LANG` has no consumer in
  `scripts/` — this corrupted the documented `--kv`/`--json` machine API
  (and any operator or agent reading it), never the build path; delivered
  MOVs carry correct languages because the mux reads them elsewhere. Of the
  11 index-dedupe sites in the tree, `probe.sh`'s was the ONLY one deduping
  a query requesting `stream_tags`; the other ten extract index/codec/type,
  identical in both views, where keep-first is harmless. Test 92 §4 pins
  that as a class guard on the idiom, not the file.
- **The invariant that would have caught it**, now pinned (§3): `probe.sh
  --kv` and `remux.sh --print-plan` must agree track-for-track on the same
  file. Two manifests over one source is the smell; agreement is the test.
- Bench note recorded in the test: `movenc` does not write `mdhd` language
  from `-metadata:s:a:0` on ffmpeg 9.0.1, so a `.mov` single-view fixture
  reads `und` on every track and cannot tell a working read from a broken
  one — §6 rides Matroska instead.

## 1.15.9 — "docs + hygiene" round (2026-08-27)

`WO-1.15.9-DOCS-HYGIENE.md` — the final checkup round: **F2, F5, F6, F7**
plus the deferred hygiene (**D3**, the dim-scan D1 sibling). Test **91**,
red-verified against e3110b9 (19 red of 26).

- **F5:** `--mp4-swap` now rides mov.sh's PAFF path through to auto.sh
  (which owns the swap) instead of being parsed and silently ignored — the
  --audio-keep class of trap; usage string names it. PAFF REVIEW builds
  (rc=10) apply requested metadata (was rc=0 only, while the non-PAFF path
  applies unconditionally), with a REVIEW floor surviving the re-verify.
- **F6:** parsers reject what they shrugged at — `diagnose.sh IN --deep`
  (a silent no-op reading as "diagnosed deep"), stray third args to
  clock/gop-probe/ts-health, the `--kvv` mode typo (fell back to human: a
  --kv consumer got zero rows, exit 0), and `mov.sh in.ts -full` (built a
  file named "-full") — all exit 2 naming the stray.
- **F2:** the retired "reordered → pairfill" doctrine (the exact 1.14
  misroute preserved as instructions) is gone from README, skills/mov,
  and SKILL.md's hard-won facts — all route by MEASURED profile and name
  Rung 3-DERIVE; `timeline-repair.md` finally carries a 3-DERIVE section
  and the widened junction precondition (it asserted strict-pair a version
  behind the code); rebuild-paff's scope-limit routes by profile.
- **F7:** README's "decoded-pixel identity for every output" scoped to
  --full (the default arbiter is VCL identity, and the text says so);
  dual-track-quicktime.md aligned with the classifier (E-AC-3 is
  QuickTime-native/copy-single in the drivers; "when unsure, default to
  dual-track" predated the classifier and is gone).
- **D3:** 94 `ffp … | head -1` sites converted to `ffp1` (the 1.15.2
  SIGPIPE class — multi-line producers on program-bearing TS; ffp1
  byte-identical on single-line queries, doctrine since 1.15.2, previously
  used at 2 sites); chained sites became `ffp1 … | tr`; the
  no-sites-remain sweep pinned in test 91. dim-scan's `grep|head|awk`
  assignment (D1 sibling) became a single early-exit awk.
- Residuals in the WO: F6 scoped to the measured offenders; direct
  `ffprobe | head -1` sites outside the measured class left; clock.sh's
  numeric-seconds-only PLAYER_TIME (pre-existing, surfaced and recorded).

## 1.15.8 — "the harness counts what it cannot see" round (2026-08-27)

`WO-1.15.8-HARNESS.md` — the checkup round packaged as "harness"
(CHECKUP-2026-08-27 **Class E**; rule 6), plus the closures this session
made tractable. Test **90** (red-verified against f45b89d: 6 red — the
E1/E2/E3/E7 metas; the E6/E8 sections were coverage additions, green through
1.15.5's seams); E7 lands inside test 14 itself.

- **E1/E2/E3 — the runner is factored and honest** (`tests/lib-harness.sh`,
  unit-tested by 90 §1): every `regression.d/*.sh` is enrolled REGARDLESS of
  exec bit (the old `[ -x ] || continue` silently un-enrolled on mode drift
  — measured: a chmod 644 or even a deleted regression.d/ read "PASSED: 0
  FAILED: 0" exit 0; now a missing/empty dir is a suite FAILURE and a
  missing bit an announced note); each case's `name: X passed, Y failed`
  tail is cross-checked against its exit status (a green exit with a
  nonzero failed-count, or no recognizable tail, is a convention-breach
  FAILURE — all existing sub-suites already complied, swept); SKIP
  announcements are counted into `HARNESS_SKIPS` and printed in the final
  banner — green but VISIBLE, so a leaner bench can no longer keep the
  same PASSED shape while whole lanes go dormant.
- **E7 — test 14's roster derives from the tree** (scripts/*.sh minus
  lib-*): the hand-kept string was 8 entry points behind its own "every
  entry point" promise. The nine new entries (the 1.15 clinic family +
  poc-gate) joined the forced-failure battery and all passed in contract
  on every arm (109/109) — no code fixes needed, which is itself the
  measurement.
- **E6 closure:** the in-situ POC count-arm UNPROVEN branch is exercised
  end-to-end through pairfill (canned census with matching picture count —
  so the histogram gate passes — but a short poc table: rows=70 vs
  packets=75 trips the count guard; machine row `unproven=1 why=count`,
  retention + re-judge, exit 1, .part kept). Testable only since 1.15.5's
  census side files — the seam E6 said was missing.
- **E4 closure:** `--signaling` now sees real color tags both ways.
  Preserved: a `setparams`-stamped bt709 source through `-c copy`, the
  VALUE printed back (non-vacuous). Drift: the SAME bitstream with its VUI
  rewritten to bt2020/PQ via `h264_metadata` — lossless, so every other
  gate passes and only this gate can catch it (three DRIFT lines, REVIEW +
  note). Bench facts recorded in the test: bare `-color_primaries` encoder
  flags landed only the matrix (use setparams), and a MOV output masks the
  rewritten SPS behind a colr atom written from input parameters (the
  drift fixture rides mpegts).
- **E8 / 5.2 debt closed:** `rewrap_nudges` / `rewrap_hard_confessions`
  unit tables — counts on canned logs plus the discrimination pins (a
  +1-tick nudge is never a hard confession and vice versa; empty log 0/0).
- **Recorded, not this round:** E5 (junction setts on real untimestamped
  data — the synthesis limit is house doctrine, test 65's header);
  E8 remainder (doctor degraded verdicts, derive-dts.py direct unit tests,
  pf_dts_source beyond injection); fixture-reality gaps (multi-program
  success paths, real open-GOP, DTS/DCA, MBAFF); main-section skip echoes
  outside the sub-suite tally (named in the banner text).

## 1.15.7 — "a scanner states its jurisdiction" round (2026-08-27)

`WO-1.15.7-JURISDICTION.md` — the checkup round packaged as "jurisdiction"
(CHECKUP-2026-08-27 **B1–B4, F1, F12, A3**; rule 5). Tests **88–89**,
red-verified against 0d225ad (88: 26 red; 89: 4 red — both bench
preconditions minted, no skips).

- **B1:** ts-health no longer scans stream 0 as "video" on a video-less
  source (measured: MP2-only TS read `video packets=1532 … CLEAN`); a
  `[scope]` finding names the missing jurisdiction (FINDINGS rc=10),
  `TSH_VIDEO=yes|none` additive, the single-GOP finding video-gated.
  zero-base refuses audio-only at PRE-FLIGHT exit 2 (pre-round: full
  re-wrap built, then verify-source's refusal — Item-C shape); clean.sh
  gates its Tier-1 route and adds the scope finding.
- **B2:** program streams have no transport-counter vocabulary (measured:
  4000 random bytes mid-.vob read "no transport loss"). `TSH_SCOPE=
  mpegts|demux-only` additive; a scope line for every non-mpegts container;
  the CLEAN verdict scoped ("demux-only … a DECODE proves content"). rc
  semantics unchanged — the harm was the definitive wording.
- **B3:** both scanners (ts-health, lead-check) parse the FULL num/den
  timebase; `${tb##*/}` was numerator-blind (measured A/B: an identical
  15-frame drop read `gaps=1 ~0.500s` through mpegts and `gaps=0` through
  AVI tb 1001/30000). Test 89 pins the A/B agreeing through both.
- **B4:** the unwrapped-wrap symptom — NEGATIVE start_time (measured:
  minted 2^33 crossing → start −7.317689, `V_WRAP=0`, CLEAN) — is a named
  finding in ts-health (`TSH_START` additive; the wrap counter documented
  as guarding the representation this demuxer no longer hands it) and in
  clean.sh (which checked the positive direction only). The −2^32
  half-wrap secondary stays SUSPECTED (recorded in the WO).
- **F1:** zero-base's PAFF refusal split — the half_ts arm keeps its
  1.15.2 message verbatim; the full-TS arm refuses as stated POLICY with
  the honest profile (half_ts=no), says pairfill would refuse that very
  file (exit 3), and names routes that accept it (mov.sh; diagnose.sh).
  Pinned via the measured pf_detect injection (2× nominal, all stamped →
  paff=yes half_ts=no).
- **F12:** `PR_NPROG` in probe --kv and `"nprog"` in --json (append-only);
  clean.sh gates the zero-base ready-to-run on it and names the topology
  (pre-round it printed a command that refuses exit 2 — measured).
- **A3:** the locale sweep is now a standing pin (test 88 §8): every entry
  point sources lib-probe.sh or exports LC_ALL=C.

## 1.15.6 — "one writer, atomic bless" round (2026-08-27)

`WO-1.15.6-ONE-WRITER.md` — the checkup round packaged as "one writer"
(CHECKUP-2026-08-27 **A2 + F11**, both CONFIRMED with measured repros),
penciled there as "1.15.5" and shipping as 1.15.6 (WO-1.15.3's execution
took 1.15.5). Tests **86–87**, red-verified against 6e90e20 first
(86: 14 red — including the sequential evidence-truncation pin; 87: 11 red).

- **A2, half 1 — unique part names:** `rtm_part` now mints
  `out.part-<pid>-<epoch>.mov` (extension-keeping as ever — D6 is about the
  SUFFIX, not determinism). The deterministic name was half the measured
  corruption: two runs sharing one part path meant run B's `ffmpeg -y`
  truncated run A's part mid-census (A blessed foreign bytes, rc=0,
  delivered file undecodable), and the SEQUENTIAL half — a stale `.part`
  kept as FAIL evidence was silently truncated by the next run's `-y`, the
  very file the retention message invited the operator to inspect. Test 86
  pins the kept evidence surviving a retry byte-identical. `rtm_sidecar`
  stays deterministic on purpose (premeta/autobest must be re-derivable
  within a run; cross-run safety is the lock's job). `trim-to-idr.sh`'s
  1.9-era inline part name converts to `rtm_part`. Test 45's exact-name
  pins re-recorded as shape pins (deviation recorded in the WO).
- **A2, half 2 — the per-OUT writer lock:** `rtm_lock`/`rtm_unlock`
  (lib-mux.sh) — `mkdir "<OUT>.lock"` (atomic POSIX primitive; macOS ships
  no flock) holding pid + host. A second live writer REFUSES pre-flight,
  exit 2, nothing written, machine row `RTM_LOCK verdict=refused holder=
  dir=`. A dead same-host holder is stolen with one announced line
  (kill-9/reboot self-heal); an EMPTY pid file is treated as LIVE — the
  holder's mkdir-to-pid-write window is never stolen (never-corrupt beats
  auto-heal; the refusal names `rm -rf` for the truly-orphaned case).
  Drivers hold ONE lock across children/sidecars/post-build reads via the
  exported `RTM_LOCK_HELD` re-entry (mov.sh after OUT settles, auto.sh
  before the stale-park rm, mp4-swap.sh newly sourcing lib-mux,
  waiver.sh — a waiver must never bind to a MOVING OUT). Release is an
  EXIT trap at the acquisition site (after every arg guard — the lib-exit
  EXIT-trap caveat pattern); lib-exit already routes INT/TERM/HUP through
  exit 1, so killed runs release; kill-9 leaves the stale-steal case.
- **F11 — disk pre-flight:** `rtm_disk_preflight OUT SRC [STAGE_DIR]` —
  free bytes on OUT's volume (and the staging volume: `rebuild-paff` stages
  ~1× the source's media on TMPDIR before its mux starts) must be ≥ the
  source size, else REFUSE exit 2 with the arithmetic + machine row
  `RTM_DISK verdict=refused free= need= vol=`. ONE rule deliberately (the
  TSH_LOSS_FAIL precedent); its stated assumption — a lossless remux
  writes roughly the source's size — has legitimate exceptions (cuts,
  trims), so `RTM_DISK_CHECK=0` is an OPERATOR knob: a resource heuristic
  is not an evidence gate, which is why a knob is legitimate here where
  1.15.2 Defect-B forbade one. A failed `df` announces "could not
  measure — proceeding unverified" and never refuses (EMPTY ≠ ABSENT
  applies to refusals too: a broken meter is not a full disk). Test hook
  `RTM_DISK_FREE_KB`; threshold pinned as a relationship in test 87 (free
  just below the fixture's size refuses, just above proceeds).
- **Wiring:** `rtm_writer_preflight OUT SRC [STAGE_DIR]` (lock + disk) at
  all 11 builders' writer-begins point (the `rtm_part` site — read-only
  modes like `--print-plan` never reach it); `zero-base`/`surgical-cut`
  re-arm their TMP traps to include the unlock. Lock-only at the four
  driver/sidecar scripts. Machine rows tabled in SKILL.md; knobs
  (`RTM_DISK_CHECK`, hooks) in `knobs.md`.
- **Recorded residual:** `batch.sh`'s ledger CSV (a report, not an
  artifact) is not locked — two concurrent batch runs sharing a ledger
  path interleave it; inherited by the next filing knowingly.

## 1.15.5 — "verify the POC gate's reach" round (WO-1.15.3 executed, 2026-08-27)

`WO-1.15.3-VERIFY-POC-REACH.md`, filed 2026-08-27 and executed the same day,
after 1.15.4 — so the round ships as **1.15.5** (no released 1.15.3 exists
and versions only move forward; the WO keeps its filed name). The checkup's
penciled "1.15.5 one-writer" round shifts to the next free number. Reserved
tests **77–79** land here, each verified RED against 9b1c792 first
(77: 28 red / 78: 12 red / 79: aborts on the missing script).

- **Item 1 — capability pre-flight (`pf_poc_capability`, lib-paff.sh):** the
  junction POC-lattice gate's verdict on a `pic_order_cnt_type != 0` source
  was knowable from a 40-frame head probe in seconds, yet its discovery cost
  the entire build (field-recorded: ~55 min mux + a 26-min whole-file output
  parse to a foregone UNPROVEN, exit 1, 24.8 GB `.part` kept). The head
  feature-probe is now captured once to a file and parsed for capability:
  `why=no_pictures` folds in the old "parsed no coded picture" refusal (now
  with the probe's rc — EMPTY ≠ ABSENT), `why=poc_type` is a new pre-flight
  refusal in the precondition voice, exit 3, nothing written, naming the
  manual route (`references/timeline-repair.md`) and the `auto.sh`
  consequence. **No bypass flag, deliberately** (1.15.2 Defect-B lesson) —
  and no attestation route either. `PCAP_MAXLSB` rides forward to the gate;
  two known SPS captures that disagree refuse loudly (a changed SPS across a
  `-c copy` indicts the source, not the gate). The census count-mismatch note
  now states its consequence (count guard WILL trip → UNPROVEN ceiling) —
  announced, not refused: that class has a legitimate multi-slice/non-VCL
  population and the duration gate still judges it. Machine row
  `PP_POC_CAPABILITY` (additive). Driver behavior per profile (Item 1 step
  6) decided and documented in `auto.sh`: the established fallbacks stand
  (PF_REORDER=no → flattening rebuild; reorder + derive signature → Rung
  3-DERIVE — neither POC-gated), the refusal guarantees only that pairfill
  itself writes nothing. Test 77 (unit lane on canned head logs +
  integration on the appendix fixtures; `PF_HEAD_TRACE_FILE` hook).
- **Item 2 — census-pass reuse (1.15.2 leftover 5.4):** `pf_trace_census`
  now emits the per-picture `idr,poc` table + SPS `log2_max` value as
  optional side files from the SAME whole-file pass (zero extra reads; the
  awk grew four token matches), and the gate builds its table as
  census-`idr,poc` ⨯ output-ffprobe-PTS — the output pays only its PTS list
  instead of the ~20-minute header re-parse. Soundness is measured, not
  argued: the gate's own extraction produced byte-identical tables across
  ts → `-c copy` → mov (appendix 2026-08-27; pinned by test 78's A/B). The
  license — copy-by-construction within the same run — is stated in the
  code; the direct-output extraction is factored (`pf_poc_extract`) and kept
  as the fallback arm. Cost model recorded in `references/knobs.md`.
- **Item 3 — `scripts/poc-gate.sh`:** playbook step 7's "re-run the gate
  against the `.part` standalone" now exists as a script (the field run had
  hand-sourced lib-paff.sh). Direct extraction + `pf_poc_lattice`, same
  human line and machine row; `--table CSV` judges a prepared table (the
  unit lane's entry point — test 76's tables drive it as-is); `--maxlsb N`
  explicit. Exit contract 0/1/**10**/2 — the 5.1 principle applied locally:
  standalone there is no bless decision, so UNPROVEN is honest REVIEW
  semantics (10), while inside pairfill the same verdict keeps exit 1 +
  retention. Companions: the UNPROVEN branch gained its machine row
  (`PP_POC_LATTICE unproven=1 why=… rows=… packets=…` — it previously
  printed nothing machine-readable) and both retention messages name the
  re-judge route. Test 79. **Considered and declined:** a `verify.sh --poc`
  flag — verify's contract is route-agnostic lowest-cost-conclusive, and the
  POC lattice is junction-specific and whole-file-parse expensive; a flag
  there invites running it where it proves nothing. Recorded here so it is
  not re-litigated.
- **Item 4 — `pic_order_cnt_type` 2 doctrine:** position 1 (pre-flight-
  announced UNPROVEN) shipped as the floor; position 2 shipped as a
  doctrine sentence in `references/timeline-repair.md`, explicitly labeled
  argument-not-measurement (type-2 lattice degenerates to a uniform ramp;
  the duration histogram is the operative evidence). Position 3 (POC
  reconstruction from `frame_num`, §8.2.1.3) **declined until a field case
  demands it** — spec-heavy code with no measured demand, and
  UNPROVEN ≠ FAILED already keeps the verdict honest. Type 1 stays
  UNPROVEN, honestly labeled by the same pre-flight (no fixture source on
  this bench: x264 emits only 0 and 2, measured).
- **Skipped, recorded (Item 1 fix 5):** the optional `/clean` capability
  line. `clean.sh` is the source clinic — report-only, source-domain, and
  its findings deliberately route timestamp-profile matters to
  `diagnose.sh` ("NOT clinic business"); the capability is a remux-rung
  evidence property that pairfill itself now announces at pre-flight before
  any cost, and `poc-gate.sh` covers the standalone ask. Adding it would
  also have introduced the clinic's first trace_headers probe for a fact
  the remux path surfaces for free.
- Docs: reach map in `pairfill-paff.sh`'s header + `timeline-repair.md`;
  `PP_CENSUS` / `PP_POC_CAPABILITY` / `PP_POC_LATTICE` rows added to
  SKILL.md's machine-lines table (PP_CENSUS emitted since 2026-08-18,
  tabled now); `poc-gate.sh` row in the task table; `PF_HEAD_TRACE_FILE`
  hook + the cost-models section in `knobs.md`. Suite 283/283; the
  1.15.2-Phase-5 leftovers 5.1/5.2/5.5/5.6 and the field follow-ups stay
  open and are restated in the WO's closing ledger.

## 1.15.4 — "EMPTY ≠ ABSENT" round (2026-08-27)

First round packaged by `CHECKUP-2026-08-27.md` (six-axis audit; findings
verified with measured repros) — the sites where a probe's EMPTY output was
read as a measured fact. The rule this round lands, twin of 1.15.2's
UNPROVEN ≠ FAILED: **no probe output feeds a verdict, a plan, or an
accusation without its exit status** (the `clean.sh` capture idiom,
`set +e; x=$(…); rc=$?; set -e`, at every touched site). Full scope +
leftovers: `WO-1.15.4-EMPTY-NE-ABSENT.md`. No released 1.15.3 exists —
`WO-1.15.3-VERIFY-POC-REACH.md` stays filed-unexecuted (its reserved test
numbers 77–79 are kept; this round's cases are 80–85).

- **A1 (the worst confirmed finding — silent false-bless):** one failed
  ffprobe (the audio-manifest query) shipped a silently audio-stripped MOV as
  ">> DONE … verified lossless", exit 0. The whole feeder family now fails
  CLOSED: `remux.sh`'s plan probe refuses exit 2; `probe.sh --kv` emits
  `PR_AUD_MANIFEST=failed` + exits 1 instead of fabricating
  `PR_AUD_COUNT=0` from its awk END block (which silently disabled the
  Dolby-E refusal loop at every eval site); the `mov.sh`/`auto.sh` eval
  sites capture the probe rc and refuse; `mov.sh`'s `--print-plan` consumer
  relays a failed plan instead of reading it as MODE=none ("no audio →
  pure copy"); `rebuild-paff.sh`'s audio census refuses instead of
  "rebuilding video only"; `verify.sh` gates (f)/(g) report a failed census
  as **UNPROVEN → REVIEW**, never "gate N/A" + OK. Test 80 (PATH-shim fault
  injection, the checkup-appendix recipe, plus fail-closed-not-fail-always
  negative controls).
- **C2:** `verify-source.sh` with an empty/invalid SOURCE baseline
  (`--src-tsh` empty file, failed scan) accused "backward DTS INTRODUCED
  (0 → N)" on a byte-identical copy. Now: "no source baseline — attribution
  UNPROVEN", one REVIEW, the four s_*-dependent comparisons skipped and the
  output counters printed unattributed. Test 81.
- **C3:** `verify.sh` gate (b) read empty-vs-empty hashes (tool failure —
  both `fhead` and the VCL branch end `|| true`) as "decoded frames differ /
  VCL MISMATCH — NOT a lossless copy". Accusations now require two NON-EMPTY
  differing hashes; empty is "could not decode — INCONCLUSIVE" REVIEW,
  mirroring gate (a) and the degraded-env arm. Test 81 (ffmpeg-shim
  injection + re-encode discrimination controls).
- **C4:** `ts-health.sh` on an unreadable input died at its first probe with
  zero output and exit 1 — the contract's DAMAGED. Now an announced
  pre-flight: "cannot read (ffprobe rc=N), NOT a damage verdict", exit 2;
  `clean.sh` propagates the child's 2 as 2 instead of relabeling it. Test 81.
- **C6 (+ the D4 fixture it was deferred for):** `verify.sh`'s `spo()` read
  ffprobe's `start_pts`/`time_base` by LINE NUMBER while ffprobe emits
  canonical order (measured: line 1 = time_base) — declared start_pts read 0
  unconditionally, the D4 "delta == declared start_pts, content aligned"
  branch (built for the 2026-08-15 field case) was dead code, and the report
  printed a false measurement inviting the exact "fix" the D4 comment warns
  against. Now parsed BY KEY; the branch is re-armed WITH its fixture: a
  minted dual-track MOV whose 4800-sample decode delta equals its declared
  start_pts reads "ALIGNED at offset 0 … not drift" → OK, and a
  non-matching offset still reads "NOT explained" → REVIEW. Test 82.
- **C7:** `mov.sh`'s bare builder calls died at a child's exit 10 —
  remux.sh's SANCTIONED REVIEW — skipping verify, playability, metadata,
  `MOV_SUMMARY`, the verdict line and trim custody (measured: rc=10,
  verify ran 0). Builders are now rc-captured: 10 continues into the gate
  battery with a REVIEW floor (an OK verify cannot outrank the child's own
  10); other codes announce, keep temp custody, and propagate unchanged.
  Test 83.
- **D1:** the confession hard-stop's frequency summary
  (`…| sort -rn | head -4`) SIGPIPEd its producer on large muxlogs and the
  ERR trap ate the "kept at $PART (log: $MUXLOG)" pointer — a mktemp path,
  unfindable without it (`remux.sh` + `pairfill-paff.sh`; `derive-dts.sh`
  was fixed in the one-liner round). The reader is now `awk 'NR<=4'` (reads
  to EOF). Test 84 reproduces with a 30k-line log — measured red pre-fix on
  this bench.
- **D2:** `verify.sh --full`'s whole-file decodes ran in statement position —
  a mid-decode failure was a SILENT exit 1 (no verdict line) that leaked the
  mktemp dir of framemd5 lists (~40 MB/occurrence). Both `--full` arms now
  capture per-decode rcs, print "FAILED mid-stream … INCONCLUSIVE (UNPROVEN,
  not FAILED)", land REVIEW, and clean up on every path. Siblings fixed the
  same way: `lead-check.sh`'s astats probe (announces, keeps
  `audio_hot=na`) and `qt-groups.sh`'s essence proofs (UNPROVEN — not
  blessed, evidence pointer intact; the empty-vs-empty accusation arm is
  unreachable for tool failures). Test 84.
- **C8:** `derive-dts.py` opened inputs at libav's stock 5 MB probesize
  against lib-probe.sh's "no call site can fall back to stock defaults"
  (measured on the repo's own late-sps.ts: PyAV saw 0x0). `rtm_open_options()`
  now plumbs `RTM_PROBESIZE`/`RTM_ANALYZEDURATION` (same 200M defaults,
  K/M/G parsed to plain integers) into both read-side `av.open` calls.
  Test 85 (unit lane, importlib — no PyAV needed) + a lockstep guard on the
  call sites.
- **A4 lockstep guard:** the one-liner round's broadened `mux_confessions`
  carried a "keep in lockstep" comment with no test — test 84 now asserts
  the two confession regexes byte-identical and pins the 4.4-era spellings.

One carried pin re-recorded, not weakened: test 12 §3's never-mask control
fed remux.sh a garbage input to provoke its mux-stage failure — with A1 an
unreadable input now refuses at the pre-flight (exit 2, nothing written,
still no retry line), so the pin records the new contract while the
property it guards (a non-probe-shaped failure is never retried, reported
once, writes nothing) is asserted unchanged.

Suite 280/280 on this bench (274 carried + tests 80–85, each verified RED
against a checkout of the pre-round commit); `claude plugin validate
--strict` green on plugin and marketplace.

## 1.15.2 — field-defects round (2026-08-27)

Four defects measured in the field on one live capture (2022-08-28 MTV VMA
satellite backhaul, 23.68 GB PAFF mpegts — `WO-1.15.2-FIELD-DEFECTS.md` holds
the full evidence; none was caught by the 1.15.1 suite). Every defect sat in
the honesty machinery — the gates that judge the work — never in the muxing:

- **Defect A (silent abort):** `rewrap_layout`'s `program=` probes died by
  SIGPIPE under `pipefail` (`ffprobe | head -1` — program= emits one line per
  program PLUS one blank per program_stream; head's early close is a race the
  field bench lost 5/5 at the 200M window). Killed `zero-base.sh` /
  `surgical-cut.sh` with exit 1 and zero diagnostic. Fix: `ffp1` in
  lib-probe.sh (awk reads to EOF, first non-empty line), both sites
  converted; test 73 pins the recovered values and greps the class.
- **Defect B (prediction contract):** the pre-pass ran `-f null -` +
  `-copyts` — a different mux than the build (field: predicted 0, observed
  11; the gate would have FAILED a fully-explained build). `rewrap_predict`
  is now a TRUE DRY RUN — the caller's own mpegts mux, layout opts included,
  bytes discarded; callers run `rewrap_layout` first and mirror extra build
  options through `RW_PREDICT_IN_OPTS`/`RW_PREDICT_OUT_OPTS`, which the build
  itself splices so the commands cannot drift. Test 74 pins predicted ==
  observed on a collision-bearing timeline (relationship, never a literal).
- **Item C (doctrine qualified + pre-flight):** the "TS→TS plain copy
  preserves the pair-timestamped PAFF shape" claim is scoped to its case
  file — the field source measured the opposite ('Timestamps are unset', the
  hard-stop class, after a full 23.68 GB build chasing 40 ms of cosmetic
  start_time). `zero-base.sh` now refuses pair-timestamped PAFF at
  pre-flight (exit 2, nothing built, `pairfill-paff.sh` named); test 75.
- **Defect D (POC-lattice false FAIL — regression vs the recorded proving
  job):** `pf_poc_lattice` never unwrapped `pic_order_cnt_lsb`, so any IDR
  sequence outliving one wrap period read as off-lattice — broadcast
  long-IDR open-GOP is the NORM (field: 24 sequences × ~73 wraps →
  3,179/451,071 on a provably correct build; 55 minutes to a false FAIL at
  the last gate). The gate now unwraps per ITU-T H.264 §8.2.1.1, preferring
  the SPS's `MaxPicOrderCntLsb` (captured in the same trace_headers pass)
  over per-sequence inference; the patched gate restores the proving job's
  451,071/451,071 on the same artifact and still fails a genuinely off-slot
  picture. Test 76 (the unit-test lane's first resident: pure CSV tables, no
  media). Git bisect: the unwrap never existed in-repo — the 2026-08-18
  proving figure came from the pre-extraction hand-run gate.
- **UNPROVEN ≠ FAILED:** the not-extractable POC branch now reports the gate
  UNPROVEN (still exit 1, still never blessed — but no longer an accusation
  against the artifact). Retained `.part` messages state the byte size and
  the delete command.
- **UX:** `mov.sh --audio-keep` on the PAFF path is rejected (exit 2) instead
  of silently ignored.

## 1.15.1 — topline-semantics round (2026-08-26)

Cross-ref against the live plugins reference (code.claude.com/docs/en/
plugins-reference + plugin-marketplaces, fetched 2026-08-26):

- **`$schema` added to both manifests** — the docs now name official schemas
  (`json.schemastore.org/claude-code-plugin-manifest.json` and
  `…/claude-code-marketplace.json`; both verified live, HTTP 200
  application/json). This REVERSES the 1.15.0 Phase-0 decision below, which
  was correct on its evidence at the time (no URL was then verifiable on
  this bench) — the reversal is recorded, not hidden.
- `description` tightened to the docs' "brief, concise for marketplace
  display" guidance (~360 chars, history pointed at CHANGELOG.md);
  marketplace entry description aligned to match.
- `displayName` → **"Remux to MOV & Source Clinic"** (free-form per docs,
  not used for lookup) — the picker now names both storeys.
- Marketplace entry enriched with the recognized optional fields
  (`displayName`, `author`, `homepage`, `repository`, `license`).
- **`name` kept as `remuxing-to-mov`, deliberately**: it keys
  `enabledPlugins`, the install identity, and the `/remuxing-to-mov:*`
  command namespace. The docs' `renames` map (v2.1.193+) makes a rename
  *possible*, but identity stability is house doctrine (machine lines never
  rename) and the name still names the plugin's center of gravity; the wider
  scope lives in displayName/description/keywords, the surfaces built for it.
- `claude plugin validate` passes clean (plugin `--strict` and the whole
  marketplace — entry-level plugin.json checks included).

## 1.15.0 — the source-clinic round (2026-08-26)

The storey below the ladder: integrity checks and corrections **to the source
file in its own container** (.ts/.mkv) — re-wrap, never remux, never in place,
never touching the original. Origin: the 2019-VMA `feed.ts` cleanup case file.

- **Phase 0 (the orphaned 1.14 Phase 6):** `CHANGELOG.md` (this file);
  `plugin.json` description shrunk to two sentences; `.bak`/`.DS_Store` strays
  removed; `allowed-tools` comma-separated in both SKILL frontmatters; CI
  resurrected at the monorepo root (the plugin-level workflow never ran there —
  GitHub only reads `.github/workflows/` at the repo root); `references/knobs.md`
  env-knob table; SKILL.md path-convention note (`scripts/…` resolves under
  `${CLAUDE_PLUGIN_ROOT}/skills/remuxing-to-mov/`). Decision recorded: no
  `$schema` added — no verified schema URL exists on this bench and no sibling
  plugin carries one; inventing an unverifiable URL fails house doctrine.
  **[REVERSED in 1.15.1, same day: the live docs name the official
  schemastore URLs; verified and added — see the 1.15.1 entry.]**
- **verify-source.sh** — the source-domain verification battery as a unit:
  filtered-reference streamhash (per-stream identity of a *cut* proven as
  rigorously as a straight copy), census arithmetic vs the plan, head/tail
  decode checks, duration arithmetic, and the nothing-unexplained gate.
  Closes the "no lossless-identity prover for non-MOV outputs" hole
  (known-limits: verify.sh gate (d) is QTFF-shaped by design).
- **clock.sh** — the player-clock translator: player-clock time = container
  time − `format.start_time`; translates a "video starts at X" report into a
  raw timestamp address with bracketing keyframes and per-frame luma means.
- **zero-base.sh** — Tier-1 structural re-wrap: mpegts timeline zero-base
  (`-muxdelay 0 -muxpreload 0`) with PID/program layout preserved, the
  minimum-start floor stated up front (first-frame reorder delay; exact 0 is
  impossible with B-frames without inventing timing), and a null-muxer
  prediction pre-pass whose expected artifact set (equal-DTS +1-tick nudges)
  is announced before the build and reconciled after it.
- **lead-check.sh** — black-lead detection: luma-mean sweep + keyframe map +
  H.264 NAL-type census (IDR vs open-GOP I) + audio level across the candidate
  splice; names the exact cut address and what a cut would discard.
- **surgical-cut.sh** — the sanctioned non-IDR cut on MPEG-TS: deterministic
  packet selection (`noise=drop=` by video packet index / audio PTS,
  `-copyts` + `-output_ts_offset`, no seeking — both `-ss` forms are
  measured-unreliable on TS), leading-B rule applied, PID layout preserved.
  **Tier 2 consent:** refuses without `--discard-content` and prints the exact
  decodable-media loss statement.
- **dim-scan.sh** — whole-file frame-dimension sweep; the mid-stream
  SPS/resolution-change named limitation gains its detection half.
- **clean.sh + `/remuxing-to-mov:clean`** — the clinic driver: cheapest-first
  analysis battery, findings where every route stays in the source container,
  Tier-1 offered / Tier-2 named for the operator.
- Recorded candidates (named, not built): `wrap-split.sh` (≥2-wrap horizon),
  `derive-dts.sh --container mkv` (same-container MKV lane), bars-and-tone
  lead detection.
- **First-ever CI run, and what it taught (2026-08-26):** the resurrected
  workflow's maiden run failed on every leg — none of it from this round's
  code. Test 61 (1.14) had pinned exact decoder-chatter counts measured on
  the macOS bench ("2 decode lines") that Linux static builds count
  differently — re-pinned as build-measured *relationships* (count registers
  and equals the most-forgiving candidate at delta 0; decisive delta positive),
  never as constants. The ms-timebase alternation pin is now gated on the
  fixture's own minted shape (ffmpeg 6.1/7.1 mint it with uniform durations —
  nothing to preserve there, announced skip). And the **4.4 matrix leg was
  dropped: the supported floor is 6.1** — 4.4 failed 20 assertions across a
  dozen sub-suites because that 2021 build predates surfaces the plugin
  legitimately depends on; below the floor the claims are benched for, green
  would have meant papering over, not proving. One real behavioral finding
  came out of the same run: **ffmpeg 6.1/7.1 movenc rounds a ms-quantized
  source's alternating 41/42 ms deltas into a uniform duration table on a
  `--timescale` remux** — the C68 "alternation survives, source-baked, not
  smoothed" claim holds on ≥8.x only, and the suite now says so per version
  instead of asserting one bench's truth everywhere.

## 1.14.0 — the reorder-DTS round (2026-08-16..24)

The 54.6 GB 2023-VMA MKV incident: reordered field-coded H.264 in a DTS-less
container — ffmpeg reconstructs DTS with a frame-unit reorder depth applied as
a packet delay, short by exactly 2× on field packets. Essentially every 1080i
North-American HD feed muxed to MKV.

- **Rung 3-DERIVE (`derive-dts.sh` + vendored `derive-dts.py`, PyAV):**
  whole-file DTS derivation from the sorted PTS column (DTS[i] = (i−D)-th
  smallest PTS) — codec-agnostic, packets copied byte-for-byte; refuses outside
  its signature (exit 3, family-consistent); `--force` as announced operator
  override; attested precondition overrides via `lib-attest.sh`.
- **Measure right:** unit-aware reorder depth (`PF_DEPTH_*`, `PF_PPF`,
  `PF_DTS_SOURCE=carried|reconstructed` with printer annotations); both
  coded-rate ratio hypotheses tested and announced; modal sorted-PTS delta
  coded rate; presentation-order gap census (`DISC_P_*`) carries every
  dropped-time claim (the ~1000× overstatement fix).
- **Judge right:** `mux_census` three-verdict (missing=FAIL / expected
  surplus=announced PASS / unexpected surplus=REVIEW, never "missing");
  mux-confessions split video (hard stop verbatim) vs audio/subtitle nudges
  (announced REVIEW); gate (g) source-baseline subtraction.
- **Route right:** rungs chosen by measured profile, every verdict printing the
  measurements that drove it; junction fill model + POC-lattice gate in
  pairfill (max-run-2 displaced-timestamp class).

## 1.13.0 — the container axis (2026-08-15)

- **Rung 3-SWAP (`mp4-swap.sh`):** the same MPEG-2 4:2:2 bitstream AVFoundation
  destroys as `.mov` (`m2v1`+`glbl`) renders correctly as `.mp4` (`mp4v`+`esds`)
  — SSIM 0.9175+ on the exact failing timestamps, where all five MOV retags
  corrupted identically (movenc writes one generic sample-description body for
  every MPEG-2 fourcc). A fidelity FAIL routes here before Rung 4, ever.
- **Post-mux census (`RMX_CENSUS`)** at every mux site — ffmpeg was measured
  dropping 1 of 3 mapped streams at `-v warning`, silently, shipping green.
- **Scan-keyed fidelity:** 0.90 was progressive-tuned and false-FAILed healthy
  interlaced material; interlaced judged at 0.86 with per-plane Y/U/V split
  (the deficit is chroma-plane — field normalization measured and rejected).
- Audio gate corrected both directions: `ipcm` allowlisted; allowlist demoted
  from verdict to prior (off-list tags get the decode probe); MP2 with no PCM
  access track finally REVIEWs. Extension-keeping part files (`x.part.mov`).

## 1.12.0 — fidelity storey (2026-08-15)

- `playable-check.sh --fidelity`: renders ≠ renders correctly — bounded
  avconvert ProRes windows SSIM-compared against the ffmpeg reference decode.
- m2v1→xd5* decoder-dispatch retag advisory (advisory-only; auto-apply
  deferred pending bench). Movie-timescale overflow truth (2^31-tick warning
  onset; geometry-gated silent chapter-track drop past 2^32, warning
  suppressed on exactly the dangerous geometries — pre-announced).
- Post-hoc gap-collapse repair route for an already-collapsed MOV.

## 1.11.0 — keep-all audio, evidence-demoted gates (2026-08-13/14)

- `--audio-keep all` default (dropping buys no playability — TN3177); per-track
  `--audio auto`; DRC `-drc_scale 0` default on AC-3/E-AC-3 decodes.
- The categorical 4:2:2 refusal **falsified on macOS 26.6.1** and demoted to
  announce + build + post-build empirical playability proof. Backhaul timeline
  rot demoted from refusal to warn+build (the measured gates judge the artifact).
- VC-1/VP9/AV1 video and Dolby E audio refused pre-flight with routes (exit 11,
  `MOV_REFUSED`) at every entry point. `pcm_bluray`/`pcm_dvd` routed to PCM
  access (the copy-muxed HDMV track is undecodable). Mid-GOP starts auto-trimmed
  (`trim-to-idr.sh`). 200M probe windows with announced 1G retry. SOURCE DAMAGED
  keyed to transport evidence, never decode noise.

## 1.10.0 — backhaul gate at every entry point (2026-08-01)

- The 1.8.0 refusal gate enforced at every `.mov`-writing entry point (closed
  after a direct build produced a doomed 2017-feed MOV the front door would
  have refused).

## 1.9.0 — H.264 High 4:2:2 (2026-07-31)

- QT-undecodable gate widened to H.264 High 4:2:2 (both classes later
  re-measured and demoted in 1.11.0 — the registry records the reversal).

## 1.8.0 — ts-health (2026-07-30)

- `ts-health.sh` one-command capture scan (transport loss, missing timestamps,
  DTS rot, forward gaps, 33-bit PTS wrap, mid-GOP start, single-GOP,
  audio drift — every finding routed). Backhaul refusal gate (since demoted).
  `verify.sh --silence` content parity (the ~17-min injected-silence class).

## 1.7.0 — QTFF audit round 5 complete (2026-07-26)

- `rung4.sh` — the only sanctioned re-encode path (verbatim operator
  attestation + mdta provenance); verify.sh master-purity scan; waiver
  sidecars (`waiver.sh`); track-set-aware audio policy; Tahoe decode-set
  drift documented; ms-timebase doctrine.

## 1.6.0 — QTFF spec audit rounds 1–4 (2026-07-26)

- 62-claim registry (`qtff-claims.md`) with dated verdicts; pairfill
  boundedness gates; `--signaling` pasp check; VFR-safe duration gate.

## 1.5.0 — post-mortem teeth (2026-07-25)

- The pair-timestamped PAFF class (PES timestamps only on the first field of
  each pair; a straight copy makes the MOV muxer INVENT timing): `pairfill-paff.sh`
  keeps every real PTS; `rebuild-paff.sh` refuses reordered streams; the
  muxer-confession hard stop; whole-file output-timeline gate (d); scrub gate.

## 1.4.0 (2026-07-24)

- `/mov` one-command shortcut; discontinuity resync (`resync.sh`); E-AC-3
  recognized QT-native (copied single-track); opt-in QuickTime `mdta` metadata
  (`metadata.sh`); capability doctor (`doctor.sh`).

## 1.1.0 (2026-07-23)

- `/mov` command added; verify decode check hardened.

## 1.0.0 (2026-07-22)

- Initial release: lossless-first remux ladder, dual-track audio deliverable,
  verification gates, references.

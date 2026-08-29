# WO-1.16.5 — the observation channel

**Filed:** 2026-08-29, from `FOLLOWUP-1.16.5.md` (two items, one round).
**Outcome under test:** both 1.16.4 verdicts that were misread were misread the
same way — not because the harness lied, but because of *how it was observed*.
The audit's exit status was read through `| tail` (so the status was tail's),
and `12-probe-retry`'s contention red was closed by a standalone pass taken on
a quiet machine.

**One sentence:** Item 1 gives the mutation audit a verdict that survives being
observed (a machine line and a file on disk, agreeing with the exit code in
both directions); Item 2 ran the contention red down to a real defect — nine
`ffprobe | head -1` sites in `probe.sh`, invisible to their own class guard
because they sat behind a variable alias — and swept the class one alias deep.

---

## Item 1 — the audit's verdict is re-readable from disk

`tests/mutation-audit.sh` now ends every completed run with

```
MA_SUMMARY total=<N> bad=<N> verdict=pass|fail
```

on stdout **and** in `$OUTDIR/VERDICT`. The exit contract is unchanged (0 only
when `bad=0`); the file is a second channel, not a replacement. A stale
`VERDICT` left in a persisted `MA_OUTDIR` by an earlier tree state is removed
at start, for the same reason `baseline_one` re-takes its baselines: absent
means "this run reached no verdict", which is the honest answer for an env
failure (exit 2) that never reached a case.

Constitution V.4's checklist now names the outdir and reads the file.

**Pinned by** `tests/regression.d/90-harness-honesty.sh` §7 (6 assertions):
a clean run writes `verdict=pass` and exits 0; a run with an injected bad case
— a throwaway copy of the plugin whose `mut_temp_scan` is neutered, which is
exactly the `MUTATE-NOOP` shape 1.16.4 misread — writes `verdict=fail` and
exits nonzero. Both directions, because a file that always says pass is worse
than no file.

**Guard G49/P49.** `mut_suppress_ma_verdict` redirects the write to
`/dev/null` in a throwaway tree, leaving stdout and the exit code intact; §7
notices in both directions and the run goes red. The prose case (a comment
naming the write) stays CLEAN.

---

## Item 2 — the `12-probe-retry` contention red, run down

### The reproduction recipe

Not reproducible by looping the test alone. What worked, in order of force:

| Recipe | Result |
| :--- | :--- |
| 20 sequential `12-probe-retry` runs while the 85-case mutation audit ran alongside (the measured trigger) | **0/20 red** |
| 3 *concurrent* `12-probe-retry` runs × 3 rounds + 6 `dd if=/dev/zero of=/dev/null` spinners + a 400 MB disk-writer loop | **1/9 red** — §5, `default window rc=2 (want 0 or 10)` |
| 8–10 concurrent `scripts/mov.sh late-sps.ts` at the default window, same load | **2/8 and 2/10** refused pre-flight |
| 24 concurrent `scripts/probe.sh late-sps.ts --kv`, same load | **3/24 and 4/24** exit 1 |
| 12 concurrent `probe.sh --kv`, no spinners | 0/12 — the race is winnable |
| 16 concurrent `rtm_aud_manifest` calls | 0/16 — not the manifest probe |

Self-contention is the trigger, not background load: the audit runs its cases
in *separate* processes at `MA_JOBS=3` and never oversubscribed the box enough.
The failing assertion is `12-probe-retry` §5, and the transcript is one line:

```
>> REFUSED (pre-flight): probe.sh --kv failed (rc=1) or returned no audio
   manifest — cannot classify this source (EMPTY is not ABSENT). Nothing written.
```

`probe.sh` prints nothing on the way out, so the transcript names a symptom and
no cause. It was traced by running the *throwaway copy* under `set -x` with
`BASH_XTRACEFD` (the real tree is never written to), which ended:

```
++11: ffp -v error -select_streams a:0 -show_entries stream=codec_name … late-sps.ts
++11: head -1
+++11: rtm_err_guard
+++11: local rc=141 c
…
++11: exit 1
```

### The cause — classification (b), the script under test

`rc=141` is SIGPIPE. `probe_struct` held its query in a local:

```
local q="ffp -v error -select_streams"
vcodec=$($q v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)   # ×9
```

On a **program-bearing** transport stream ffprobe lists every stream twice —
the bare top-level view, then the in-program view — so each of those queries
writes **two** lines (measured: `select_streams v:0 codec_name -> 2 lines` on
`late-sps.ts`). `head -1` takes the first and closes the pipe; when ffprobe
loses that race it dies of SIGPIPE, `pipefail` promotes it, `set -e` fires, and
`lib-exit.sh`'s guard maps the stray to a bare `exit 1` — correctly, by the
exit-code contract, and silently. `mov.sh` then reads a failed `--kv` and
refuses a clean source at the front door.

This is the **1.15.2 SIGPIPE class**, for which `ffp1` was written and 91 §5
has guarded since 1.15.9 — by matching the literal token `ffp`. Behind `$q`,
nine armed sites read as zero for four minor versions.

**Not (a):** the test assumed nothing about a quiet machine; its §5 assertion
is on the exit code, and the exit code was honestly reporting a refusal.
**Not (c):** no shared path, no `mktemp` collision, no `RTM_*` leakage —
`rtm_aud_manifest` at 16-way concurrency is clean, and each run owns its
scratch.

### The fix, and the class swept (V.1)

`probe_struct`'s alias is now `ffp1` and the nine `| head -1` tails are gone.
`ffp1`'s awk reads to EOF, so the writer always completes. The `--kv` output is
**byte-identical** to a pre-fix good run.

The class was swept tree-wide first: exactly **one** variable in the whole tree
was ever assigned an ffprobe command line (`probe.sh:141`), and nine sites used
it. 91 §5 now sweeps one alias deep — it collects every variable assigned an
`ffp`/`ffprobe` command, then checks whether that variable is piped into an
early-exit reader. `ffp1` is deliberately not in the alternation: aliasing *it*
is the fix, not the defect.

**Green under the same induced load** (6 spinners, post-fix):

| Recipe | Before | After |
| :--- | :--- | :--- |
| 12 concurrent `mov.sh` at the default window | 2/8, 2/10 refused | **0/12** |
| 3 concurrent `12-probe-retry` × 3 rounds | 1/9 red | **0/9** |
| 24 concurrent `probe.sh --kv` + 4 spinners | 3/24, 4/24 | **0/24** |

**Pinned by** `tests/regression.d/115-probe-head-race.sh` (6 assertions): the
precondition (the queries really do write two lines), 24 concurrent `--kv` runs
under 4 self-owned spinners that must all exit 0 *and recover the real values*
(exit 0 with a hollowed-out manifest is the same bug in a different hat), and
the shape — the alias is `ffp1`, no `$q` pipes into `head`, and all nine query
sites survive the conversion (a "fix" that deleted them would satisfy the first
two checks and probe nothing).

**Guard G50/P50.** `mut_alias_ffp_head` appends an aliased `$_q … | head -1` to
a throwaway `clock.sh`, deliberately split across three lines so 91 §5's
*literal* arm cannot see it and only the new alias arm can claim the catch.

### Jurisdiction of this test's green (III.2)

Like test 73, this file cannot pin "red before" on every bench: the race is
scheduling-dependent and winnable. Its §1 green is scoped to *this* bench under
*that* load, and its §2 green is unconditional. The measured pre-fix rates
above are recorded in the test header so the next contention red has a
baseline to argue with.

---

## Bench

`bash tests/regression.sh` and `MA_OUTDIR=… bash tests/mutation-audit.sh` —
counts in `CHANGELOG.md` 1.16.5. Bench: macOS 26.6.1, ffmpeg 9.0.1.

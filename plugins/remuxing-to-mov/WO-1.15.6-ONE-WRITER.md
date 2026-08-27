# 1.15.6 Work Order — One Writer, Atomic Bless

> **Status (2026-08-27): filed and executed in the same session.** This is the
> checkup round packaged as "one writer" (CHECKUP-2026-08-27.md: **A2 + F11**),
> penciled there as "1.15.5" and shipping as **1.15.6** — WO-1.15.3's execution
> took 1.15.5. Execution record at the end.

**Bench:** ffmpeg/ffprobe 9.0.1, macOS (Darwin 25.6.0), zsh, APFS.
Pre-round tree: 6e90e20 (1.15.5). Tests this round: **86–87** (next free
numbers; 77–85 used).

---

## The findings (from CHECKUP-2026-08-27, both CONFIRMED with measured repros)

### A2 — no writer exclusivity: a second run corrupts an artifact the first run blesses

`lib-mux.sh` `rtm_part` mints a DETERMINISTIC part name (`out.part.mov`), the
muxes run `ffmpeg -y … "$PART"`, and no lock exists anywhere. Measured: run A
(298 MB) and run B started on the same OUT; A printed
`census: … plan matched … wrote: out.mov`, **rc=0**, and the delivered file
fails on first read (`Invalid NAL unit size …`) — the census and the `mv` are
not atomic against a second writer, so a verdict earned on one byte-stream
blesses another. Same exposure: `mov.sh`'s `idrtrim.tmp`/`premeta`,
`auto.sh`'s `.autobest`, waiver sidecars. And the SEQUENTIAL half: a stale
`.part` retained as FAIL evidence is silently truncated by the next run's
`-y` — the evidence the retention message told the operator to inspect.

### F11 — free disk space is checked nowhere

No `df`/statvfs in any script. A 24 GB build can burn an hour to an ENOSPC
exit-1 with a truncated `.part` — which the retention message then reports
with a byte size, inviting inspection of a file that is short for a
completely different reason. `rebuild-paff.sh` additionally stages ~1× the
source's media on the TMPDIR volume before its mux even starts.

---

## The fix — the checkup's rule 2, both halves

**"One writer, atomic bless. Unique part names (PID/nonce) or an exclusive
lock, and finalize must be race-safe."** The two halves protect different
things, so both land:

1. **Unique part names** (`rtm_part` → `out.part-<pid>-<epoch>.mov`,
   extension-keeping as before — D6 is about the SUFFIX, not determinism):
   kills the measured cross-truncation at the byte level AND the sequential
   evidence-truncation (a retry can no longer `-y` over a kept `.part`).
   `rtm_sidecar` stays deterministic on purpose — `premeta`/`autobest`
   must be re-derivable within a run, and the driver lock (below) is what
   protects them across runs. Test 45's exact-name pins are RE-RECORDED as
   relationship pins (same directory, `stem.part…ext` shape, two mints
   differ); the deviation is this round's deliverable, recorded here.

2. **A per-OUT writer lock** (`rtm_lock`/`rtm_unlock`, `lib-mux.sh`):
   `mkdir "<OUT>.lock"` — atomic on POSIX, no flock dependency (macOS ships
   none) — holding `pid` + `host` files. Second concurrent writer REFUSES at
   pre-flight, exit 2, nothing written, machine line
   `RTM_LOCK verdict=refused holder=<pid> dir=<lockdir>`, message naming the
   measured A2 corruption and the remedy. A lock whose recorded pid is dead
   ON THIS HOST is stolen with a one-line announcement (kill-9/reboot
   self-heal); an EMPTY pid file is treated as live (the holder's
   mkdir-to-pid-write window must never be stolen — prefer never-corrupt
   over auto-heal; the refusal names `rm -rf` for the truly-orphaned case).
   Re-entrancy for drivers: acquiring exports `RTM_LOCK_HELD=<lockdir>`;
   a child computing the same lockdir returns held-by-parent without
   owning, so `mov.sh`/`auto.sh`/`mp4-swap.sh` hold ONE lock across their
   children, their sidecars, and their post-build reads of OUT. Release is
   an EXIT trap installed at the acquisition site (after every arg guard —
   the lib-exit EXIT-trap caveat holds: reachable usage paths are
   unaffected); INT/TERM/HUP already route through `exit 1` (lib-exit), so
   a killed run releases too; only kill-9 leaves a lock, and that is the
   stale-steal case.

3. **`rtm_disk_preflight OUT SRC [STAGE_DIR]`** (F11): free bytes on OUT's
   volume (and the staging volume when given — `rebuild-paff`'s WORK) must
   be ≥ the source's size, else REFUSE exit 2 pre-flight with the
   arithmetic, machine line `RTM_DISK verdict=refused free= need= vol=`.
   Deliberately ONE rule (the TSH_LOSS_FAIL precedent: one knob so callers
   cannot disagree). The rule's stated assumption: a lossless remux writes
   roughly the source's size. For the genuinely-smaller-output classes
   (cuts, trims), `RTM_DISK_CHECK=0` is an OPERATOR knob (documented in
   knobs.md) — this is a resource heuristic, not an evidence gate, so a
   knob is legitimate where 1.15.2 Defect-B forbade one for evidence.
   A failed `df` announces "could not measure — proceeding unverified" and
   does not refuse (EMPTY ≠ ABSENT applies to refusals too: a broken meter
   is not a full disk). Test hook `RTM_DISK_FREE_KB` injects the reading.

4. **`rtm_writer_preflight OUT SRC [STAGE_DIR]`** = lock + disk, one call.
   Wired at the natural writer-begins point of every builder (the
   `rtm_part` site; read-only modes like `--print-plan` never reach it):
   remux, dual-track, resync, rebuild-paff (stage=$WORK, placed before the
   extraction — the big TMPDIR write), pairfill-paff, derive-dts,
   trim-to-idr (which also converts its 1.9-era inline part name to
   `rtm_part`), metadata, rung4, zero-base, surgical-cut (both extending
   their existing TMP traps). Drivers lock only (children disk-check):
   mov.sh (after OUT settles), auto.sh (before the stale-park `rm`),
   mp4-swap.sh (gains lib-mux), waiver.sh (its sidecar binds a verdict to
   OUT — a moving OUT must not be waivable).

**Recorded residual:** `batch.sh`'s ledger CSV is a report file, not an
artifact; two concurrent batch runs sharing a ledger path interleave it.
Not locked this round — recorded here so the next filing inherits it
knowingly.

---

## Regression tests

- **`86-one-writer.sh`** — rtm_part uniqueness (two mints differ; extension
  kept; old deterministic name gone from a real failed build's retention);
  lock refusal (foreign live lock → builder exits 2, nothing written,
  machine row, no steal of an empty-pid lock); stale steal (dead recorded
  pid → announced takeover, build proceeds); re-entrancy (RTM_LOCK_HELD →
  child proceeds without owning); release on success AND on failure exits
  (no lockdir left behind); driver holds one lock across children (grep +
  behavior). Red pre-round: helpers absent.
- **`87-disk-preflight.sh`** — RTM_DISK_FREE_KB=1 → refusal exit 2, nothing
  written, arithmetic + machine row + knob named; RTM_DISK_CHECK=0 →
  announced skip, build proceeds; no hooks → real df, clean build;
  rebuild-paff passes its staging dir. Red pre-round: helpers absent.

---

## Execution record (2026-08-27, same session as filing)

Executed against 6e90e20 (the 1.15.5 tree). Tests 86–87 written FIRST and
verified RED (86: 16 passed / **14 failed** — the reds being uniqueness,
lock, release, and the sequential evidence-truncation pin, which measured
the pre-round `-y` destroying the kept FAIL `.part` on retry; 87: 6 passed /
**11 failed** — every disk-pre-flight assertion), then green after the
fixes: 86 = 30/30, 87 = 17/17, both mode 755.

**Landed exactly as scoped above.** Fix-shape notes worth keeping:

- `rtm_free_bytes` prints NOTHING (not 0) when unmeasurable — the caller's
  "could not measure — proceeding unverified" announce is the EMPTY ≠
  ABSENT arm, pinned by 87 §4 with a non-numeric `RTM_DISK_FREE_KB`.
- The lock's steal loop steals AT MOST ONCE per acquisition (a second
  mkdir loss after a steal means a live racer won — refuse, never
  steal-fight).
- `rtm_part` uniqueness is PER PROCESS ($$ + epoch): two calls in one run
  return one name (every builder mints exactly once), two processes never
  collide, and a weeks-old kept part survives a recycled pid (the epoch).
  Pinned across processes in 86 §1 via `bash -c` mints.
- Test 45 §1/§3 re-pinned (exact deterministic names → shape pins +
  message-names-the-actual-kept-file), deviation recorded there and here.
  Every other suite reference to part files was already glob/absence-shaped.
- mov.sh's `idrtrim.tmp`/`premeta` and auto.sh's `.autobest` stay
  DETERMINISTIC (rtm_sidecar unchanged) — they must be re-derivable within
  a run, and the driver's held lock is what protects them across runs
  (86 §7 pins mov.sh refusing under a foreign live lock with no sidecar
  written).

**Gates:** suite **285/285** (283 carried + 2 new); high-risk neighbors
re-run individually first (13/14/22/45/63/68/70 — all green; the
exit-contract and signal lanes in 14 confirm the EXIT-trap release
composes with lib-exit); `claude plugin validate --strict` green on plugin
and marketplace.

**Residuals (recorded, not silent):** batch.sh's ledger CSV unlocked (a
report file — two concurrent batch runs on one ledger interleave it);
qt-groups.sh manages its own outputs outside rtm_part and was not named in
A2's exposure list — neither is locked this round. kill-9 leaves a lock by
design (the stale-steal path is the recovery). The disk rule's single
threshold (source size) can false-refuse a cut on a nearly-full disk —
that is what the announced `RTM_DISK_CHECK=0` knob is for.

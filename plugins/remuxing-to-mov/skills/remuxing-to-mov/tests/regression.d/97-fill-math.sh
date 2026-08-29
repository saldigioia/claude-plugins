#!/usr/bin/env bash
# 97-fill-math.sh — WO-1.15.20 S2: the sparse-unstamped pre-pass math, pinned
# in the unit lane (importlib, no PyAV, no media — the lane 1.15.2 opened).
#
# WHAT THE PRE-PASS IS. derive-dts.py computes DTS[i] = sorted_pts[i-D] by
# INDEXING the sorted PTS column, so a video packet carrying data but no PTS
# has no position in it. That refused the whole stream on the first such
# packet. The pre-pass reconstructs a SPARSE set of those packets from measured
# evidence first, so the derivation runs unchanged on a complete column. It
# does not loosen the precondition — it satisfies it.
#
# THE ONE EVIDENCE RULE IS THE PAIR-MATE, and §5 is why. A PAFF field pair is
# two ADJACENT coded pictures — the two fields of one frame — one field
# duration apart; reordering moves whole pairs, never a field out of its pair.
# When that pairing is PROVEN over the whole file, a hole's mate is identified
# and its value follows. When it is not proven, there is no evidence and the
# file is refused.
#
# §5 pins the rule that was REJECTED while building this, because a plausible
# rule that is wrong is worth a permanent guard: "both neighbours timestamped
# and exactly two field durations apart, so the value is forced". It is not
# forced. In CODED order a reorder anchor sits between two packets of a
# sequential run without disturbing their arithmetic at all — measured on this
# round's own fixture at coded 306/307/308. If that rule ever comes back, this
# section goes red.
#
# Standalone: bash tests/regression.d/97-fill-math.sh
# Exit 0 = all assertions pass; 1 = a regression; 2 = env failure.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"
command -v python3 >/dev/null || { echo "need python3"; exit 2; }

python3 - "$SC/derive-dts.py" <<'PY'
import importlib.util, sys
sys.dont_write_bytecode = True          # no scripts/__pycache__ litter in the repo
spec = importlib.util.spec_from_file_location("dd", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

P = F = 0
def ok(msg):
    global P; P += 1; print("  \033[32mPASS\033[0m  %s" % msg)
def no(msg):
    global F; F += 1; print("  \033[31mFAIL\033[0m  %s" % msg)
def check(cond, msg):
    ok(msg) if cond else no(msg)
def refuses(col, msg, **kw):
    try:
        m.fill_sparse(col, **kw)
        no(msg + " [it FILLED instead of refusing]")
        return ""
    except m.Refuse as e:
        ok(msg); return str(e)
def fills(col, msg, **kw):
    try:
        filled, stamps = m.fill_sparse(col, **kw)
        if any(v is None for v in filled):
            no(msg + " [a hole survived the fill]"); return None, None
        ok(msg); return filled, stamps
    except m.Refuse as e:
        no(msg + " [REFUSED: %s]" % str(e)[:70]); return None, None

STEP = 1800

def paff(nframes=200, order=None):
    """A PAFF column: frames reordered in adjacent swaps, each frame's two
    fields adjacent in coded order and one field duration apart."""
    order = order if order is not None else [k ^ 1 for k in range(nframes)]
    col = []
    for f in order:
        col += [f * 2 * STEP, f * 2 * STEP + STEP]
    return col

TRUE = paff()

print("== 1. the pairing hypothesis is PROVEN, or it is unavailable ==")
check(m._pair_parity(TRUE, STEP) == 0, "a reordered field-pair column proves parity 0")
seq = [i * STEP for i in range(400)]
check(m._pair_parity(seq, STEP) is None,
      "a sequential column proves NOTHING (both parities agree — unproven, not a guess)")
odd = paff(nframes=200, order=[k ^ 1 for k in range(200)])
odd = odd[1:]                            # shift the phase: pairs now begin on odd indices
check(m._pair_parity(odd, STEP) == 1, "a phase-shifted column proves the OTHER parity")

print()
print("== 2. a hole is reconstructed from its pair-mate, on either side ==")
for label, idx in (("second field (mate leads)", 5), ("first field (mate follows)", 4)):
    c = list(TRUE); c[idx] = None
    filled, stamps = fills(c, "fills a %s" % label)
    if filled:
        check(filled[idx] == TRUE[idx], "  …with the TRUE value (%d)" % TRUE[idx])
        check(len(stamps) == 1 and stamps[0][3] == "pair-mate", "  …recorded as pair-mate evidence")

print()
print("== 3. the class the field capture is: stride-2 clusters ==")
# 24 unstamped of 424,645 in three clusters, two with stride 2 — every member
# is one field of a distinct consecutive pair, so every one has a live mate.
# a longer column, so eight holes sit comfortably inside the sparse bound
# (8/2000 = 0.004 — the same order as the field capture's 5.65e-5 relative to
# the bound, rather than a fraction the bound itself would reject)
BIG = paff(nframes=1000)
holes = [4, 6, 8, 100, 102, 300, 302, 304]
c = list(BIG)
for j in holes: c[j] = None
filled, stamps = fills(c, "fills three stride-2 clusters (%d holes)" % len(holes))
if filled:
    check(all(filled[j] == BIG[j] for j in holes), "  …every value is the TRUE one")
    check(len(stamps) == len(holes), "  …one stamp row per hole (%d)" % len(holes))
    check([s[0] for s in stamps] == holes, "  …announced in coded order, positions intact")
    # the pin the WO asks for: a relationship, never a bench literal
    check(sum(1 for v in filled if v is not None) == len(BIG),
          "  …the column is complete: stamped + carried == packets")

print()
print("== 4. boundaries: the head packet, and a mate off the end ==")
c = list(TRUE); c[0] = None
filled, _ = fills(c, "the FIRST coded packet is reconstructed from the field that follows it")
if filled: check(filled[0] == TRUE[0], "  …with the TRUE value")
c = list(TRUE); c[len(TRUE) - 1] = None
filled, _ = fills(c, "the LAST coded packet is reconstructed from the field that leads it")
if filled: check(filled[-1] == TRUE[-1], "  …with the TRUE value")
# an odd-length column whose final packet is a FIRST field: its mate would be
# packet n, which does not exist. No evidence -> refuse, never extrapolate.
tail = TRUE[:-1]
c = list(tail); c[len(tail) - 1] = None
e = refuses(c, "a hole whose mate falls off the end refuses (no extrapolation)")
check("off the end" in e or "no timestamped pair-mate" in e, "  …and says the mate is missing")

print()
print("== 5. REJECTED: neighbour arithmetic is not evidence (the measured trap) ==")
# Coded 306/307/308 of this round's own fixture: PTS 1227600 / 1252800 /
# 1234800. The neighbours are exactly 2*step apart, and the packet between them
# is the next P ANCHOR — seven steps from where the cadence claims it is. A
# "bilateral cadence" rule proposed 1231200, a value carried by coded 301.
anchor_trap = list(seq)                  # sequential: pairing unprovable
anchor_trap[10] = None
e = refuses(anchor_trap, "a hole in an unprovable-pairing column is REFUSED, not summed")
check("field pairing" in e or "no timestamped pair-mate" in e,
      "  …because there is no pair-mate to read, whatever the neighbours look like")
# and the exact measured shape, in miniature
trap = [3 * STEP, 4 * STEP, None, 5 * STEP, 6 * STEP] * 40
e = refuses(trap, "the 306/307/308 anchor shape refuses rather than inventing a value")

print()
print("== 6. the sparse bound, and what lies past it ==")
c = list(TRUE); c[4] = None
fills(c, "one hole in %d packets is inside the bound" % len(TRUE))
e = refuses(c, "…and outside a bound tightened below it", max_frac=0.0001)
check("sparse bound" in e, "  …the refusal names the bound it failed")
half = []
for i in range(200): half += [i * 2 * STEP, None]
e = refuses(half, "a half-timestamped column (0.5) is refused as out of class")
check("pairfill" in e, "  …and is routed to pairfill, whose class that is")

print()
print("== 7. a reconstruction that collides is refused, never nudged ==")
c = list(TRUE); c[5] = None
c[200] = TRUE[5]                          # plant the value the fill would produce
e = refuses(c, "a fill landing on a carried PTS refuses the whole file")
check("collide" in e, "  …naming the collision, not adjusting the value")

print()
print("== 8. no reconstruction is evidence for another ==")
# two adjacent holes: each is the other's only mate. Filling one and then
# reading it back would fabricate a chain; both must be orphans.
c = list(TRUE); c[4] = None; c[5] = None
e = refuses(c, "two adjacent holes are BOTH orphans (no chaining)")
check("360" not in e and "side by side" in e, "  …and the refusal explains the shape")
check("4, 5" in e or "4" in e, "  …and names the coded positions")

print()
print("== 9. the derivation runs unchanged on the filled column ==")
c = list(TRUE)
for j in (4, 6, 100): c[j] = None
filled, stamps = m.fill_sparse(c)
dts, depth, step = m.derive_dts(filled)
check(step == STEP, "modal step survives the fill (%d)" % step)
check(all(dts[i] > dts[i - 1] for i in range(1, len(dts))), "derived DTS strictly monotonic")
check(all(dts[i] <= filled[i] for i in range(len(dts))), "derived DTS <= PTS everywhere")
check(sorted(filled) == sorted(TRUE), "the filled column IS the true timeline (multiset)")
# the whole point: the same column with the holes DROPPED derives a different,
# shorter timeline — the pre-pass is what makes the derivation the right one.
check(len(filled) == len(TRUE) and len([v for v in c if v is not None]) == len(TRUE) - 3,
      "…and dropping the holes instead would have lost 3 coded pictures")

print()
print("fill-math: %d passed, %d failed" % (P, F))
sys.exit(1 if F else 0)
PY

#!/usr/bin/env python3
# derive-dts.py — Rung 3-DERIVE core: whole-stream DTS derivation for a
# PTS-complete, reordered video stream whose container carries no trustworthy
# DTS (Matroska/raw-ES: none at all — every dts ffmpeg shows there is the
# demuxer's has_b_frames reconstruction, short by the field factor on the
# 2023-VMA field-coded class; or a carried-but-rotten column the caller has
# decided to discard). Hardened from fixdts.py, the 90-line script that
# repaired the real 54.6 GB incident capture (PTS preserved 3600/3600, DTS
# monotonic <= PTS, video MD5 identical).
#
# The derivation (unit-agnostic — frames, fields, whatever the packets are):
#   D      = max(i - rank(pts[i]))   over the WHOLE file's coded-order PTS —
#            the largest distance any coded picture travels between coded
#            position and presentation position. A windowed D is advisory
#            only; underestimating D is the one unsafe direction, so the
#            whole-file recompute here is mandatory (work-order decision #4).
#   DTS[i] = sorted_pts[i - D]       for i >= D
#   DTS[i] = sorted_pts[0] - (D - i) * step   for i < D (the pre-roll), where
#            step is the MODAL delta of the sorted PTS — the coded-picture
#            duration. NEVER 1 tick: a 1-tick pre-roll writes near-zero sample
#            durations into stts (the trap the incident report hit).
#
# SAFETY PROOF (why depth overestimation cannot corrupt): sorted_pts is
# monotonic by construction, so any D' >= actual keeps DTS strictly monotonic;
# and DTS[i] = sorted_pts[i-D'] <= sorted_pts[rank(pts[i])] = pts[i] whenever
# D' >= i - rank(pts[i]) for all i, which D' >= D guarantees. Both properties
# are ALSO asserted at runtime — the proof covers the derivation, the
# assertions cover the implementation.
#
# What is copied: every mapped packet byte-for-byte (PyAV copies the payload
# untouched — codec-agnostic, so mpeg2video/HEVC ride the same rung).
# Timestamps are rewritten ONLY on the video stream; every other stream gets
# the same uniform wall-clock shift (the pre-roll lift when DTS[0] < 0),
# converted into its own time base, so A/V sync is preserved exactly.
# Chapters: PyAV cannot write them — the shell driver re-attaches them with a
# -map_chapters pass and gates the result (repair -> chapters -> gates).
#
# THE SPARSE-UNSTAMPED PRE-PASS (WO-1.15.20 S2). The derivation above indexes
# the sorted PTS column, so a video packet with data but no PTS has no position
# in it and the whole stream used to be refused on the first such packet. That
# refusal REMAINS THE DEFAULT. What is new is one bounded exception: when the
# unstamped set is SPARSE and every member's value is forced by the timestamps
# of its immediate neighbours, fill_sparse() reconstructs those few PTS from
# that measured evidence FIRST, and the derivation then runs unchanged on a
# complete column. A hole whose value is not forced by evidence refuses the
# WHOLE FILE — never a partial fill, which is the invented-timing class with
# better manners.
#
# THIS IS NOT A LOOSENED GATE, and the distinction is the whole design. Raising
# the routing bound alone (PF_PTS_COMPLETE_MAX, lib-paff.sh) was investigated
# and rejected: it admits a file to a derivation that still cannot place its
# unstamped packets. The pre-pass does not widen the derivation's precondition
# — it SATISFIES it, by giving those packets a place from evidence before the
# derivation runs. Every gate downstream (monotonicity, DTS<=PTS, the packet-
# hash gates) runs afterwards, unchanged; stamps are container metadata and the
# essence is never touched.
#
# REFUSALS (exit 3, matching the driver's signature-refusal code):
#   * any video packet with data but no PTS that the sparse pre-pass cannot
#     evidence — see fill_sparse(); at ~0.5 unstamped that is the pairfill
#     class (half-timestamped PAFF) and this derivation would invent, not
#     derive.
#   * duplicate PTS — the derivation assumes a unique display timeline. A
#     reconstructed value that collides with a carried one refuses exactly as
#     a carried duplicate does.
# Exit codes: 0 ok | 1 failure | 2 usage | 3 refused | 10 PyAV missing.
#
# Usage: derive-dts.py INPUT OUTPUT [--limit N]
#   --limit N   bench mode: derive from and write only the first N video
#               packets (other streams cut at the same wall clock). The
#               output is a PARTIAL artifact — the driver never blesses it.
#
# The pure derivation lives in derive_dts() with no PyAV dependency so the
# regression suite can pin the math via importlib on a bench without PyAV.

import os
import sys
import collections


class Refuse(Exception):
    """Signature refusal — the stream must not pass through this derivation."""


def modal_step(sorted_pts):
    """The modal delta of the presentation-sorted PTS: the coded-picture
    duration. Never returns < 1 (a degenerate single-packet stream gets a
    1-tick step, but its pre-roll is empty anyway: depth 0)."""
    deltas = collections.Counter(
        sorted_pts[i] - sorted_pts[i - 1] for i in range(1, len(sorted_pts))
    )
    if not deltas:
        return 1
    return max(deltas.most_common(1)[0][0], 1)


def derive_dts(coded_pts):
    """coded_pts: the video PTS column in CODED order (whole file).
    Returns (dts_list, depth, step). Raises Refuse on duplicate PTS."""
    n = len(coded_pts)
    if n == 0:
        raise Refuse("no video packets with PTS — nothing to derive")
    srt = sorted(coded_pts)
    for i in range(1, n):
        if srt[i] == srt[i - 1]:
            raise Refuse(
                "duplicate PTS present (value %d) — the derivation assumes a "
                "unique display timeline; this stream needs diagnosis, not a "
                "restamp" % srt[i]
            )
    rank = {v: i for i, v in enumerate(srt)}
    depth = max(i - rank[v] for i, v in enumerate(coded_pts))
    depth = max(depth, 0)
    step = modal_step(srt)
    dts = [
        srt[i - depth] if i >= depth else srt[0] - (depth - i) * step
        for i in range(n)
    ]
    # the runtime half of the safety proof (see header)
    assert all(dts[i] > dts[i - 1] for i in range(1, n)), "DTS not strictly monotonic"
    assert all(dts[i] <= coded_pts[i] for i in range(n)), "DTS exceeds PTS"
    return dts, depth, step


# --- the sparse-unstamped pre-pass (WO-1.15.20 S2) --------------------------
# The default bound for "sparse": the fraction of video packets carrying data
# but no PTS that the pre-pass will consider filling at all. THIS IS A
# RELATIONSHIP, NOT A BENCH LITERAL. It is a cut in the empty band between the
# two timeline rungs' signatures:
#   * pairfill's pair signature begins at 0.35 (pf_half, lib-paff.sh), so this
#     bound sits 35x below the lowest fraction that rung will ever claim: a
#     file this pre-pass accepts can never be a half-timestamped PAFF source.
#   * the motivating 2024-VMA capture measured 24 unstamped of 424,645 packets
#     = 5.65e-5, ~177x below the bound: it is nowhere near tight against the
#     case that motivated it.
# Nothing derives 0.01 from the format, and it is not a tolerance the fills
# lean on — the whole-file evidence tests below, never this number, decide
# every individual reconstruction. Overridable as RTM_SPARSE_NOPTS_MAX.
RTM_SPARSE_NOPTS_MAX = 0.01

# The pair-parity hypothesis is PROVEN or it is unavailable; these are the
# thresholds for "proven". The winner must be near-total and the loser must be
# decisively worse — a hypothesis that merely wins on points is not evidence.
PAIR_PARITY_MIN_TESTS = 8
PAIR_PARITY_MIN_AGREE = 0.99
PAIR_PARITY_MAX_LOSER = 0.5

# How many offending positions a refusal names before it summarizes. The
# operator needs enough to recognize the shape (a cluster? the head? scattered?)
# without a 400k-line stderr.
REFUSAL_POSITIONS_SHOWN = 12


def _pair_parity(coded, step):
    """Which coded-index parity BEGINS a PAFF field pair, proven over the whole
    file — or None when the evidence does not settle it.

    A PAFF field pair is two ADJACENT coded pictures (the two fields of one
    frame) whose PTS differ by exactly one field duration; frame reordering
    moves whole pairs and never lifts a field out of its pair. So under the
    hypothesis "pairs begin at coded-index parity `off`", every adjacent
    (j-1, j) with (j-1) % 2 == off must satisfy pts[j] - pts[j-1] == step,
    while the opposite parity straddles two DIFFERENT frames — which is
    exactly where a reorder pyramid puts an arbitrary jump.

    UNPROVEN IS THE ORDINARY CASE: a frame-coded stream has no field pairs at
    all, and a stream that is sequential in coded order satisfies both parities
    equally. There is no fallback — an unproven pairing means fill_sparse() has
    no evidence for any hole and refuses the file. That is the intended
    outcome, not a hole in the coverage (see fill_sparse's REJECTED note).
    """
    n = len(coded)
    agree = [0, 0]
    tested = [0, 0]
    for j in range(1, n):
        a, b = coded[j - 1], coded[j]
        if a is None or b is None:
            continue
        off = (j - 1) % 2
        tested[off] += 1
        if b - a == step:
            agree[off] += 1
    for off in (0, 1):
        other = 1 - off
        if min(tested[off], tested[other]) < PAIR_PARITY_MIN_TESTS:
            continue
        if (agree[off] >= PAIR_PARITY_MIN_AGREE * tested[off]
                and agree[other] <= PAIR_PARITY_MAX_LOSER * tested[other]):
            return off
    return None


def fill_sparse(coded, max_frac=RTM_SPARSE_NOPTS_MAX):
    """coded: the video PTS column in CODED order over the WHOLE file, with
    None at every packet that carries data but no PTS.

    Returns (filled, stamps): `filled` has no None left, and `stamps` is a list
    of (index, mate_index, value, rule) — one row per reconstruction, in coded
    order — so every invented-from-evidence timestamp can be announced and
    recorded. With no holes at all this is the identity and stamps is empty.

    Raises Refuse rather than fill any hole whose value is not FORCED by
    measured evidence, and the refusal covers the whole file: a partial fill
    would be the invented-timing class with better manners.

    ONE evidence rule, because only one is sound: the PAIR-MATE. The whole-file
    field-pair parity must be PROVEN (see _pair_parity), which identifies the
    other field of the hole's OWN frame; that mate must carry a real PTS; and
    the hole's value is then one field duration away from it.

    REJECTED, AND THE REASON MATTERS (WO-1.15.20 S2, measured while building
    this): a "bilateral cadence" rule — both immediate neighbours timestamped
    and exactly two field durations apart, so the value looks arithmetically
    forced. It is not. In CODED order a reorder anchor can sit between two
    packets of a sequential run without disturbing their arithmetic at all.
    Measured on the round's own fixture: coded 306/307/308 read PTS 1227600 /
    1252800 / 1234800 — neighbours exactly 2*step apart, and the packet
    between them is the next P anchor, 7 steps away from where the cadence
    says it is. The rule proposed 1231200, a value already carried by coded
    301. Widening the window does not help: 305..309 satisfy a strict
    step-spaced run through the same anchor. Container arithmetic cannot
    distinguish "continues the run" from "is the next anchor"; only the essence
    could, and this rung never opens it. So a stream with no provable field
    pairing has no evidence here and is refused — that is the honest answer,
    not a gap to be filled by a plausible-looking sum.

    The evidence reads the ORIGINAL column, never a value this pass just wrote:
    no reconstruction is ever evidence for another reconstruction.

    PyAV-free on purpose: the unit lane pins this math via importlib on a bench
    without PyAV, exactly as it pins derive_dts().
    """
    n = len(coded)
    holes = [j for j, v in enumerate(coded) if v is None]
    if not holes:
        return list(coded), []
    known = [v for v in coded if v is not None]
    if len(known) < 2:
        raise Refuse(
            "%d of %d video packet(s) carry data but no PTS and only %d carry "
            "one — that is not evidence enough to reconstruct anything"
            % (len(holes), n, len(known)))
    frac = float(len(holes)) / n
    if frac > max_frac:
        raise Refuse(
            "%d of %d video packets (%.6g) carry data but no PTS — above the "
            "sparse bound %.6g. This is not the isolated-hole class the "
            "pre-pass reconstructs; near 0.5 it is the half-timestamped PAFF "
            "class instead, whose repair is pairfill-paff.sh (it keeps every "
            "real PTS and fills each pair-mate)"
            % (len(holes), n, frac, max_frac))
    step = modal_step(sorted(known))
    parity = _pair_parity(coded, step)

    proposals = {}                 # index -> (value, rule, mate)
    orphans = []                   # no evidence at all
    for j in holes:
        if parity is None:
            orphans.append(j)             # no provable pairing: no mate to read
            continue
        if j % 2 == parity:
            mate, sign = j + 1, -1        # j is a first field; its mate follows
        else:
            mate, sign = j - 1, +1        # j is a second field; its mate leads
        if not (0 <= mate < n) or coded[mate] is None:
            orphans.append(j)
            continue
        proposals[j] = (coded[mate] + sign * step, "pair-mate", mate)

    if orphans:
        raise Refuse(
            "%d of %d unstamped video packet(s) have no timestamped pair-mate "
            "to reconstruct from — the whole file is refused rather than "
            "partly filled (a partial fill is invented timing with better "
            "manners). Coded positions: %s. Three shapes land here: two "
            "unstamped packets side by side (each is the other's mate), a "
            "hole whose mate falls off the end of the file, and a stream "
            "whose field pairing this file does not prove at all — a "
            "frame-coded stream has no pair-mate to read, and its neighbours' "
            "arithmetic is not evidence (a reorder anchor imitates it)"
            % (len(orphans), len(holes), _positions(orphans)))
    # collisions are checked over the WHOLE proposal set at once, so a pair of
    # reconstructions that agree with each other is caught as surely as one
    # that lands on a carried PTS. The duplicate-PTS refusal in derive_dts()
    # stays armed behind this as the backstop.
    seen = {}
    for v in known:
        seen[v] = None
    collisions = []
    for j in sorted(proposals):
        v = proposals[j][0]
        if v in seen:
            collisions.append((j, v, seen[v]))
        else:
            seen[v] = j
    if collisions:
        raise Refuse(
            "%d reconstructed PTS collide with a timestamp already on the "
            "timeline — the derivation assumes a unique display timeline, and "
            "a collision means the evidence was misread, not that the value "
            "needs a nudge. %s"
            % (len(collisions), "; ".join(
                "packet %d -> %d (already %s)"
                % (j, v, "packet %d" % o if o is not None else "carried")
                for j, v, o in collisions[:REFUSAL_POSITIONS_SHOWN])))

    filled = list(coded)
    stamps = []
    for j in sorted(proposals):
        value, rule, mate = proposals[j]
        filled[j] = value
        stamps.append((j, mate, value, rule))
    return filled, stamps


def _positions(idxs):
    """A refusal's position list: enough to recognize the shape, then a count."""
    head = ", ".join(str(i) for i in idxs[:REFUSAL_POSITIONS_SHOWN])
    if len(idxs) > REFUSAL_POSITIONS_SHOWN:
        head += ", ... (%d more)" % (len(idxs) - REFUSAL_POSITIONS_SHOWN)
    return head


# subtitle codecs the MOV muxer can carry by copy; anything else is announced
# and skipped LOUDLY (house rule: no silent drops), never re-encoded.
MOV_SUB_CODECS = {"mov_text", "text", "tx3g"}


def _rtm_window(raw, floor):
    """Parse an RTM_* probe-window value ('200M', '5000000', '1G') to a plain
    integer. K/M/G are the decimal SI multipliers ffmpeg's own CLI applies to
    the same knobs. Anything absent or unparseable falls back to the FLOOR —
    never to libav's stock default (the floor's whole reason to exist)."""
    if not raw:
        return floor
    s = str(raw).strip()
    mult = 1
    if s and s[-1] in "kKmMgG":
        mult = {"k": 1000, "m": 1000000, "g": 1000000000}[s[-1].lower()]
        s = s[:-1]
    try:
        return int(s) * mult
    except ValueError:
        return floor


def rtm_open_options():
    """libavformat options for every READ-side av.open(): the lib-probe.sh
    200M probe-window floor, plumbed into the Python half of the rung
    (CHECKUP-2026-08-27 C8 / WO-1.15.4 — measured on the repo's own
    late-sps.ts: a stock 5 MB open sees 0x0 where the floor reads the real
    dimensions, and the mux then dies on a stream this rung misprobed).
    RTM_PROBESIZE is bytes, RTM_ANALYZEDURATION microseconds — the same env
    knobs, same 200M defaults, as the shell side. Values are plain integer
    strings so no libav suffix-parsing behavior is assumed."""
    return {
        "probesize": str(_rtm_window(os.environ.get("RTM_PROBESIZE"), 200000000)),
        "analyzeduration": str(_rtm_window(os.environ.get("RTM_ANALYZEDURATION"),
                                           200000000)),
    }


def main():
    args = [a for a in sys.argv[1:]]
    limit = None
    if "--limit" in args:
        i = args.index("--limit")
        try:
            limit = int(args[i + 1])
        except (IndexError, ValueError):
            sys.exit(2)
        del args[i:i + 2]
    if len(args) != 2:
        print("usage: derive-dts.py INPUT OUTPUT [--limit N]", file=sys.stderr)
        sys.exit(2)
    src, dst = args

    try:
        import av
    except ImportError:
        print(
            "PyAV is not importable by this python — run via the venv the "
            "driver checks (derive-dts.sh prints the bootstrap).",
            file=sys.stderr,
        )
        sys.exit(10)

    # --- pass 1: the WHOLE video PTS column, coded order --------------------
    # Holes (data but no PTS) are CARRIED as None rather than dropped: the
    # sparse pre-pass needs each hole's coded POSITION to find its neighbours,
    # and the old drop-and-count destroyed exactly that (WO-1.15.20 S2).
    inp = av.open(src, options=rtm_open_options())   # probe-window floor (C8)
    vin = inp.streams.video[0]
    column = []
    n_empty = 0
    for pkt in inp.demux(vin):
        if pkt.size == 0:
            n_empty += 1          # flush/padding packets: not coded pictures
            continue
        column.append(pkt.pts)    # None here IS the hole
        if limit and len(column) >= limit:
            break
    v_tb = vin.time_base
    inp.close()

    n_nopts = sum(1 for v in column if v is None)
    # The whole-file census is the AUTHORITATIVE one. Every routing decision
    # upstream (probe.sh, diagnose.sh, auto.sh) rides a head-window fraction
    # that is a hint only — 240 packets, quantum 1/240 — so a file can arrive
    # here and be refused, or arrive looking worse than it is. This count is
    # measured over every packet, and it decides (WO-1.15.20 S3).
    # an unparseable knob falls back to the default and SAYS so — a garbage
    # env value must not decide a timeline repair, and must not crash the rung
    # with a traceback either (the operator would read that as a broken file).
    max_frac = RTM_SPARSE_NOPTS_MAX
    raw = os.environ.get("RTM_SPARSE_NOPTS_MAX")
    if raw:
        try:
            max_frac = float(raw)
        except ValueError:
            print("   note: RTM_SPARSE_NOPTS_MAX=%r is not a number — using the "
                  "default %g" % (raw, RTM_SPARSE_NOPTS_MAX), file=sys.stderr)
    try:
        coded, stamps = fill_sparse(column, max_frac)
    except Refuse as e:
        print(">> REFUSED: %s" % e, file=sys.stderr)
        sys.exit(3)
    if stamps:
        print("-- sparse-unstamped pre-pass: %d of %d video packet(s) carried "
              "data but no PTS (%.3g of the file; bound %.3g) --"
              % (n_nopts, len(column), float(n_nopts) / len(column), max_frac))
        print("   each row below is a RECONSTRUCTION from a measured "
              "neighbour, not a carried timestamp:")
        for j, mate, value, rule in stamps:
            # one machine row per reconstruction: the artifact's provenance
            # record, AND the list output gate 2 needs — the output legitimately
            # carries PTS the source does not, and a gate must be told which
            # ones rather than be loosened to tolerate any.
            print("   DERIVE_STAMP idx=%d pts=%d mate=%d rule=%s"
                  % (j, value, mate, rule))
    try:
        dts, depth, step = derive_dts(coded)
    except Refuse as e:
        print(">> REFUSED: %s" % e, file=sys.stderr)
        sys.exit(3)
    n = len(coded)

    shift_ticks = max(0, -dts[0])
    shift_sec = shift_ticks * v_tb        # Fraction: exact wall-clock shift
    shift_ms = float(shift_sec) * 1000.0
    if n_empty:
        print("   note: %d zero-size video packet(s) skipped (flush/padding, "
              "not coded pictures)" % n_empty)
    print("packets=%d reorder_depth=%d shift_ms=%.3f" % (n, depth, shift_ms))
    print("DERIVE_PY packets=%d depth=%d step=%d shift_ticks=%d shift_ms=%.3f "
          "stamped=%d method=%s"
          % (n, depth, step, shift_ticks, shift_ms, len(stamps),
             "pair-mate" if stamps else "none"))

    # --- pass 2: copy every packet, rewrite timestamps ----------------------
    inp = av.open(src, options=rtm_open_options())   # probe-window floor (C8)
    vin = inp.streams.video[0]
    mapped = [vin]
    skipped = []
    for st in inp.streams:
        if st.index == vin.index:
            continue
        ty = st.type
        if ty == "video":
            skipped.append((st, "second video stream — this rung restamps "
                                "v:0 only; extract and remux others by hand"))
        elif ty == "audio":
            mapped.append(st)
        elif ty == "subtitle":
            name = st.codec_context.name if st.codec_context else "?"
            if name in MOV_SUB_CODECS:
                mapped.append(st)
            else:
                skipped.append((st, "subtitle codec %s is not MOV-copyable "
                                    "(never re-encoded here)" % name))
        else:
            # data/attachment tracks: a source chapter 'menu' is re-created by
            # the driver's -map_chapters pass; anything else is named here.
            skipped.append((st, "%s stream not carried (chapters are "
                                "re-attached by the driver)" % ty))
    for st, why in skipped:
        print("** WARNING: stream #%d DROPPED: %s" % (st.index, why))
    codecs = ",".join(
        (st.codec_context.name if st.codec_context else "?") for st in mapped
    )
    print("DERIVE_PLAN n=%d codecs=%s" % (len(mapped), codecs))

    out = av.open(dst, "w", format="mov", options={"movflags": "+faststart"})
    omap = {}
    for st in mapped:
        o = out.add_stream_from_template(st)
        # the SAME wall-clock shift, expressed in each stream's own time base
        omap[st.index] = (o, int(round(shift_sec / st.time_base)))
    cutoff_sec = (max(coded) * v_tb) if limit else None

    i = 0
    n_unplaced = 0
    for pkt in inp.demux(mapped):
        if pkt.size == 0:
            continue
        o, sh = omap[pkt.stream.index]
        if pkt.stream.index == vin.index:
            # no `pkt.pts is None` skip any more: pass 1 either reconstructed
            # the hole from evidence or refused the file (WO-1.15.20 S2), so
            # every data-bearing video packet has a place in the column and
            # the two passes stay index-aligned.
            if i >= n:
                break                     # --limit bench cut
            pkt.pts = coded[i] + sh
            pkt.dts = dts[i] + sh
            i += 1
        else:
            if pkt.pts is None and pkt.dts is None:
                n_unplaced += 1           # unplaceable: announced below
                continue
            base = pkt.pts if pkt.pts is not None else pkt.dts
            if cutoff_sec is not None and base * pkt.stream.time_base > cutoff_sec:
                continue                  # --limit: cut at the video wall clock
            pkt.pts = (base if pkt.pts is None else pkt.pts) + sh
            pkt.dts = pkt.pts if pkt.dts is None else pkt.dts + sh
        pkt.stream = o
        out.mux(pkt)
    out.close()
    inp.close()
    if n_unplaced:
        print("** WARNING: %d non-video packet(s) had neither PTS nor DTS and "
              "were not carried" % n_unplaced)
    if not limit and i != n:
        print(">> video packet count changed between passes (%d vs %d) — the "
              "source moved under us; output is NOT trustworthy" % (i, n),
              file=sys.stderr)
        sys.exit(1)
    print("wrote %s  (video packets remapped: %d/%d)" % (dst, i, n))


if __name__ == "__main__":
    main()

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
# REFUSALS (exit 3, matching the driver's signature-refusal code):
#   * any video packet with data but no PTS  — that is the pairfill class
#     (half-timestamped PAFF); this derivation would invent, not derive.
#   * duplicate PTS — the derivation assumes a unique display timeline.
# Exit codes: 0 ok | 1 failure | 2 usage | 3 refused | 10 PyAV missing.
#
# Usage: derive-dts.py INPUT OUTPUT [--limit N]
#   --limit N   bench mode: derive from and write only the first N video
#               packets (other streams cut at the same wall clock). The
#               output is a PARTIAL artifact — the driver never blesses it.
#
# The pure derivation lives in derive_dts() with no PyAV dependency so the
# regression suite can pin the math via importlib on a bench without PyAV.

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


# subtitle codecs the MOV muxer can carry by copy; anything else is announced
# and skipped LOUDLY (house rule: no silent drops), never re-encoded.
MOV_SUB_CODECS = {"mov_text", "text", "tx3g"}


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
    inp = av.open(src)
    vin = inp.streams.video[0]
    coded = []
    n_empty = 0
    n_nopts = 0
    for pkt in inp.demux(vin):
        if pkt.size == 0:
            n_empty += 1          # flush/padding packets: not coded pictures
            continue
        if pkt.pts is None:
            n_nopts += 1
            continue
        coded.append(pkt.pts)
        if limit and len(coded) >= limit:
            break
    v_tb = vin.time_base
    inp.close()

    if n_nopts > 0:
        print(
            ">> REFUSED: %d video packet(s) carry data but no PTS — this is the "
            "half-timestamped (pairfill) class, not the derive class. Route: "
            "scripts/pairfill-paff.sh (it KEEPS the real PTS and fills each "
            "pair-mate; deriving here would invent timestamps)." % n_nopts,
            file=sys.stderr,
        )
        sys.exit(3)
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
    print("DERIVE_PY packets=%d depth=%d step=%d shift_ticks=%d shift_ms=%.3f"
          % (n, depth, step, shift_ticks, shift_ms))

    # --- pass 2: copy every packet, rewrite timestamps ----------------------
    inp = av.open(src)
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
            if pkt.pts is None:
                continue                  # counted and refused in pass 1
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

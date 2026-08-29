#!/usr/bin/env python3
# poc-remux.py — Rung 3-POC: field-pair-aware lossless remux, timed from the
# bitstream's own declared display positions.
#
# WHAT IT IS FOR. A reorder-distributed PAFF capture: fields coded adjacently
# but NOT stamped one field duration apart, so every timestamp-delta heuristic
# reads "no pairing here" and every rung above this one refuses. Measured on
# the 2024 VMA capture (2026-08-29): 0 of 424,596 adjacent coded pairs differ
# by one field duration — literally true, and the wrong conclusion. Those
# fields ARE coded-adjacent and DO share frame_num; the source stamps each
# bottom field a constant three rungs BELOW its own top field.
#
# So this rung stops proxying and reads the two facts directly:
#   PAIRING   ISO/IEC 14496-15 — both fields of a complementary field pair go
#             in ONE sample. field_pic_flag=1, bottom_field_flag 0->1, same
#             frame_num, coded-adjacent. Players time playback off SAMPLES, so
#             one sample per field makes the container claim ~50/s over a
#             ~25/s decode: bit-perfect, and it stutters everywhere.
#   TIMING    pic_order_cnt states each picture's display position outright.
#             k = POC + C, C constant per (IDR epoch, bottom_field_flag).
#
# WHY THE PER-PARITY SPLIT IS MANDATORY: bottoms sit a constant offset below
# their own tops, so a single global C looks non-unanimous and the class is
# discarded as unproven — on a stream where it is provable to four nines. That
# is exactly how the naive version fails.
#
# WORKING IN FRAMES IS WHAT MAKES THE HOLES GO AWAY. After pairing, a bottom
# field's carried PTS is discarded (the frame takes the TOP field's), so on the
# motivating capture 23 of 24 unstamped packets stop mattering entirely — only
# the one frame-coded picture needed solving. Nothing is guessed: it is filled
# from its own POC or the file is refused.
#
# NOTHING IS RE-ENCODED. Packet payloads are copied byte for byte; only
# container timestamps are written, and only on the video stream. Every other
# stream gets the same uniform wall-clock shift, converted into its own time
# base, so A/V sync is preserved exactly.
#
# Usage: poc-remux.py IN OUT [--audio all|first|none] [--tag FOURCC]
#                            [--acodecs a,b,...] [--limit N] [--dry-run]
#   --acodecs  the CONTAINER's codec name per audio stream, in order, as the
#              driver read it from ffprobe. Not a preference — the authority.
#              See the mislabel note in pass 2.
# Exit: 0 built | 1 failure | 2 usage | 3 refused (no trusted evidence) |
#       10 PyAV missing

import collections
import os
import sys

MIN_SAMPLES, MIN_AGREE = 100, 0.999      # the unforgiving bar, unchanged
LATTICE_MIN_AGREE = 0.999                # PTS must actually sit on a lattice


class Refuse(Exception):
    """This rung must not write a timeline it cannot evidence."""


def modal(values):
    if not values:
        return None
    c = collections.Counter(values)
    return c.most_common(1)[0][0]


def measure_lattice(pts):
    """(step, off, agree) — the rung lattice the source's own timestamps sit on.

    NOTHING HERE IS A CONSTANT. The predecessor hardcoded this capture's
    1800/415, which is indistinguishable from being right by luck. step is the
    modal delta of the sorted distinct timestamps (one coded picture); off is
    the modal residue. `agree` is the fraction of stamped packets that actually
    land on it — the caller refuses below the bar rather than forcing a lattice
    the stream does not use.
    """
    known = sorted(set(v for v in pts if v is not None))
    if len(known) < 2:
        raise Refuse("fewer than two distinct timestamps — nothing to fit a lattice to")
    step = modal([known[i] - known[i - 1] for i in range(1, len(known))])
    if not step or step <= 0:
        raise Refuse("the modal timestamp delta is %r — no usable coded-picture duration" % step)
    stamped = [v for v in pts if v is not None]
    off = modal([v % step for v in stamped])
    on = sum(1 for v in stamped if (v - off) % step == 0)
    return step, off, float(on) / len(stamped)


def main():
    args = list(sys.argv[1:])
    audio = "all"
    tag = "avc1"
    acodecs = []
    limit = None
    dry = False
    if "--acodecs" in args:
        i = args.index("--acodecs")
        if i + 1 >= len(args):
            sys.stderr.write("--acodecs needs a comma-separated list\n")
            return 2
        acodecs = [x.strip() for x in args[i + 1].split(",") if x.strip()]
        del args[i:i + 2]
    for flag, conv in (("--audio", str), ("--tag", str), ("--limit", int)):
        if flag in args:
            i = args.index(flag)
            try:
                v = conv(args[i + 1])
            except (IndexError, ValueError):
                sys.stderr.write("%s needs a value\n" % flag)
                return 2
            if flag == "--audio":
                audio = v
            elif flag == "--tag":
                tag = v
            else:
                limit = v
            del args[i:i + 2]
    if "--dry-run" in args:
        dry = True
        args.remove("--dry-run")
    if audio not in ("all", "first", "none"):
        sys.stderr.write("--audio must be all|first|none\n")
        return 2
    if len(args) != 2:
        sys.stderr.write("usage: poc-remux.py IN OUT [--audio all|first|none] "
                         "[--tag FOURCC] [--limit N] [--dry-run]\n")
        return 2
    src, dst = args

    try:
        import av
    except ImportError:
        sys.stderr.write(
            "PyAV is not importable by this python — run via the venv the driver "
            "checks (poc-remux.sh prints the bootstrap).\n")
        return 10

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import h264poc

    # ------------------------------------------------------------ pass 1 ---
    # One demux, every fact: the timestamp column, the slice headers, the POC.
    # Nothing below re-reads the file (Constitution IV.2).
    inp = av.open(src, options={
        "probesize": os.environ.get("RTM_PROBESIZE", "200000000"),
        "analyzeduration": os.environ.get("RTM_ANALYZEDURATION", "200000000"),
    })
    vin = inp.streams.video[0]
    if str(getattr(vin.codec_context, "name", "")) != "h264":
        inp.close()
        sys.stderr.write(
            ">> REFUSED: this rung reads H.264 slice headers; this stream is %s. "
            "pic_order_cnt and complementary field pairs are H.264 facts, and "
            "there is no equivalent to read here.\n"
            % getattr(vin.codec_context, "name", "unknown"))
        return 3
    par = h264poc.Parser()
    unw = h264poc.PocUnwrapper()
    pts, poc, epoch, bottom, field, fnum = [], [], [], [], [], []
    n_empty = n_unparsed = 0
    for pkt in inp.demux(vin):
        if pkt.size == 0:
            n_empty += 1
            continue
        sh = par.parse_slice(bytes(pkt))
        pts.append(pkt.pts)
        if sh is None:
            n_unparsed += 1
            poc.append(None); epoch.append(None); bottom.append(None)
            field.append(None); fnum.append(None)
        else:
            p, e = unw.feed(sh)
            poc.append(p); epoch.append(e); bottom.append(sh["bottom"])
            field.append(sh["field_pic"]); fnum.append(sh["frame_num"])
        if limit and len(pts) >= limit:
            break
    inp.close()
    n = len(pts)
    if n == 0:
        sys.stderr.write(">> REFUSED: no coded video picture was read.\n")
        return 3

    cap_ok, cap_why = par.capability()
    print("-- pass 1: %d coded picture(s) (%d empty skipped, %d header(s) unparsed) --"
          % (n, n_empty, n_unparsed))
    print("   SPS: %s" % "; ".join(
        "id=%d profile=%d %dx%d poc_type=%d max_poc_lsb=%d frame_mbs_only=%d"
        % (v["sps_id"], v["profile_idc"], v["width"], v["height"], v["poc_type"],
           v["max_poc_lsb"], v["frame_mbs_only_flag"]) for v in par.sps.values()))
    if not cap_ok:
        sys.stderr.write(">> REFUSED: %s\n" % cap_why)
        return 3
    if cap_why != "-":
        print("   note: %s" % cap_why)

    try:
        step, off, agree = measure_lattice(pts)
    except Refuse as e:
        sys.stderr.write(">> REFUSED: %s\n" % e)
        return 3
    print("   measured rung lattice: step=%d ticks, offset=%d, %.5f of stamped "
          "packets land on it" % (step, off, agree))
    if agree < LATTICE_MIN_AGREE:
        sys.stderr.write(
            ">> REFUSED: only %.5f of this stream's timestamps sit on the "
            "measured lattice (step=%d offset=%d, bar %.4g). A rung index that "
            "most packets do not share is not a lattice, and every value this "
            "rung would place rests on it.\n" % (agree, step, off, LATTICE_MIN_AGREE))
        return 3
    k = [None if v is None else (v - off) // step for v in pts]

    # ---- group coded pictures into FRAMES (ISO/IEC 14496-15) --------------
    groups, singles = h264poc.pair_fields(
        [0 if f is None else f for f in field],
        [0 if b is None else b for b in bottom],
        [-1 if f is None else f for f in fnum])
    m = len(groups)
    pairs = sum(1 for g in groups if len(g) == 2)
    print("   ISO/IEC 14496-15 pairing: %d frame(s) from %d picture(s) "
          "— %d complementary pair(s), %d unpaired single(s)"
          % (m, n, pairs, singles))

    # ---- k = POC + C, per (epoch, parity) --------------------------------
    solver = h264poc.RungSolver(MIN_SAMPLES, MIN_AGREE)
    for i in range(n):
        solver.vote(epoch[i], bottom[i], k[i], poc[i])
    solver.solve()
    print("-- POC classes (every class, trusted or not — a rule that never fired "
          "must say so) --")
    for row in solver.report():
        print("   %s" % row)
    if not solver.trusted:
        sys.stderr.write(
            ">> REFUSED: no (IDR epoch, field parity) class cleared the evidence "
            "bar (>=%d votes, >=%.4g unanimity). Without a trusted class no "
            "picture's display position can be stated, and this rung fills "
            "nothing it cannot evidence.\n" % (MIN_SAMPLES, MIN_AGREE))
        return 3

    # ---- one rung per FRAME; fill the holes from POC ----------------------
    rk = [k[g[0]] for g in groups]      # each frame takes its FIRST field's rung
    nfill = 0
    fills = []
    for j in range(m):
        if rk[j] is None:
            lead = groups[j][0]
            d = solver.rung(epoch[lead], bottom[lead], poc[lead])
            if d is None:
                sys.stderr.write(
                    ">> REFUSED: frame %d (coded picture %d) carries no timestamp "
                    "and its (epoch %s, parity %s) class is not trusted — there is "
                    "no evidence for its display position, and a plausible-looking "
                    "sum is not evidence.\n"
                    % (j, lead, epoch[lead], "bottom" if bottom[lead] else "top"))
                return 3
            rk[j] = d
            nfill += 1
            fills.append((j, lead, d))

    # ---- duplicates: the later holder carries a stale pre-discontinuity value
    nmove = 0
    moves = []
    for _round in range(8):
        where = collections.defaultdict(list)
        for j, v in enumerate(rk):
            where[v].append(j)
        dups = {v: ix for v, ix in where.items() if len(ix) > 1}
        if not dups:
            break
        progressed = False
        for v, ix in sorted(dups.items()):
            lead = {j: groups[j][0] for j in ix}
            agreeing = [j for j in ix
                        if solver.rung(epoch[lead[j]], bottom[lead[j]], poc[lead[j]]) == v]
            keep = agreeing[0] if len(agreeing) == 1 else min(ix)
            for j in ix:
                if j == keep:
                    continue
                d = solver.rung(epoch[lead[j]], bottom[lead[j]], poc[lead[j]])
                if d is None or d == rk[j]:
                    continue
                moves.append((j, lead[j], rk[j], d))
                rk[j] = d
                nmove += 1
                progressed = True
        if not progressed:
            break
    if len(set(rk)) != m:
        stuck = sorted(v for v, c in collections.Counter(rk).items() if c > 1)
        sys.stderr.write(
            ">> REFUSED: %d display slot(s) are still claimed by more than one "
            "frame after POC adjudication (rungs %s). Two pictures on one slot is "
            "the defect verify.sh gate (j) exists to catch; it is not shipped.\n"
            % (len(stuck), stuck[:8]))
        return 3

    # ---- DTS from the sorted presentation column -------------------------
    fpts = [v * step + off for v in rk]
    srt = sorted(fpts)
    rank = {v: i for i, v in enumerate(srt)}
    depth = max(i - rank[v] for i, v in enumerate(fpts))
    fdts = [srt[i - depth] if i >= depth else srt[0] - (depth - i) * 2 * step
            for i in range(m)]
    assert all(fdts[i] > fdts[i - 1] for i in range(1, m)), "DTS not monotonic"
    assert all(fdts[i] <= fpts[i] for i in range(m)), "DTS exceeds PTS"

    # ---- ANCHOR ON THE EARLIEST DISPLAYED FRAME --------------------------
    # Not on the first CODED one. On a reordered stream they are different
    # pictures, and a container anchored on the coded head declares a start
    # above its own earliest composition time — the frame(s) before it then sit
    # outside the declared presentation (verify.sh gate (l)). The same constant
    # goes to every stream, so A/V sync is untouched.
    shift = min(fpts)
    fpts = [v - shift for v in fpts]
    fdts = [v - shift for v in fdts]
    print("-- timeline: %d frame(s), reorder depth %d, holes filled %d, stale "
          "moved %d --" % (m, depth, nfill, nmove))
    for j, lead, d in fills[:8]:
        print("   POC_FILL frame=%d coded=%d rung=%d pts=%d" % (j, lead, d, d * step + off))
    for j, lead, ov, nv in moves[:8]:
        print("   POC_ADJUDICATE frame=%d coded=%d rung %d -> %d" % (j, lead, ov, nv))
    print("   anchor: -%d ticks so the EARLIEST DISPLAYED frame maps to 0" % shift)
    print("POC_SUMMARY paired=%d singles=%d holes_filled=%d dups_moved=%d "
          "anchor=%d frames=%d pictures=%d depth=%d step=%d verdict=%s"
          % (pairs, singles, nfill, nmove, shift, m, n, depth, step,
             "planned" if dry else "building"))
    if dry:
        print(">> DRY RUN — nothing written.")
        return 0

    # ------------------------------------------------------------ pass 2 ---
    inp = av.open(src)
    vin = inp.streams.video[0]
    ains = list(inp.streams.audio)
    if audio == "none":
        ains = []
    elif audio == "first":
        ains = ains[:1]
    out = av.open(dst, "w", format="mov")
    try:
        vout = out.add_stream_from_template(vin)
    except AttributeError:
        vout = out.add_stream(template=vin)
    if tag:
        vout.codec_tag = tag
    aouts = {}
    for ai, a in enumerate(ains):
        # THE MISLABEL TRAP (measured 2026-08-29, and this rung WALKED INTO IT
        # on its first real run — verify.sh gate (i) is what caught it).
        #
        # PyAV resolves an MP2 stream through the **mp3float DECODER**, so
        # `codec_context.codec.name` reads "mp3float", a template copy inherits
        # codec id MP3, and the MOV gets a '.mp3' sample entry over Layer II
        # payload: bit-identical, decodes without an error, and Apple documents
        # '.mp3' as Layer 3. Asking PyAV what codec this is gets the DECODER's
        # answer, which is not the question.
        #
        # So the CONTAINER's own codec name is passed in by the driver (ffprobe
        # stream=codec_name) and used here. Setting codec_tag afterwards does
        # NOT work: the muxer validates tag against codec id in both directions
        # and rejects it.
        ao = None
        want = acodecs[ai] if ai < len(acodecs) else None
        if not want:
            try:
                want = a.codec_context.codec.name
            except Exception:
                want = None
            if want and want.endswith("float"):
                # a decoder name, not a codec name — refuse to guess from it
                print("   note: PyAV reports the DECODER %r for audio stream %d and the "
                      "driver passed no --acodecs; falling back to the input template, "
                      "which may mislabel the sample entry (verify.sh gate (i) will say so)"
                      % (want, ai))
                want = None
        if want:
            try:
                ao = out.add_stream(want, rate=a.rate)
                try:
                    ao.layout = a.layout
                except Exception:
                    pass
            except Exception as e:
                print("   note: add_stream(%r) failed (%s); falling back to the "
                      "input template — check gate (i) on the result" % (want, e))
                ao = None
        if ao is None:
            try:
                ao = out.add_stream_from_template(a)
            except AttributeError:
                ao = out.add_stream(template=a)
        aouts[a.index] = ao

    owner = {}
    for j, idxs in enumerate(groups):
        for pos, ci in enumerate(idxs):
            owner[ci] = (j, pos, len(idxs))

    vtb = float(vin.time_base)
    vi = nframe = na = 0
    pending = None
    for pkt in inp.demux(list({vin, *ains})):
        if pkt.size == 0:
            continue
        if pkt.stream.index == vin.index:
            if vi not in owner:
                break                      # --limit truncation
            j, pos, ln = owner[vi]
            data = bytes(pkt)
            key = pkt.is_keyframe
            if ln == 2 and pos == 0:
                pending = (j, data, key)
                vi += 1
                continue
            if ln == 2 and pos == 1:
                pj, pdata, pkey = pending
                data = pdata + data
                key = key or pkey
                pending = None
            np = av.Packet(data)
            np.pts = fpts[j]
            np.dts = fdts[j]
            np.time_base = vin.time_base
            np.stream = vout
            if key:
                np.is_keyframe = True
            out.mux(np)
            nframe += 1
            vi += 1
        else:
            if pkt.dts is None or pkt.pts is None:
                continue
            atb = float(pkt.time_base if pkt.time_base else pkt.stream.time_base)
            # the SAME wall-clock shift, expressed in this stream's own base —
            # computed from the VIDEO time base, never a hardcoded 90 kHz
            ash = int(round(shift * vtb / atb)) if atb else 0
            pkt.pts -= ash
            pkt.dts -= ash
            pkt.stream = aouts[pkt.stream.index]
            na += 1
            out.mux(pkt)
    out.close()
    inp.close()
    print("-- pass 2: %d frame(s) written, %d audio packet(s), from %d coded "
          "picture(s) --" % (nframe, na, vi))
    if nframe != m and limit is None:
        sys.stderr.write(
            ">> FAIL: wrote %d frame(s) for a plan of %d — the mux did not carry "
            "the plan. Nothing here is blessed on a count it cannot explain.\n"
            % (nframe, m))
        return 1
    print("POC_SUMMARY paired=%d singles=%d holes_filled=%d dups_moved=%d "
          "anchor=%d frames=%d pictures=%d depth=%d step=%d verdict=built"
          % (pairs, singles, nfill, nmove, shift, nframe, n, depth, step))
    return 0


if __name__ == "__main__":
    sys.exit(main())

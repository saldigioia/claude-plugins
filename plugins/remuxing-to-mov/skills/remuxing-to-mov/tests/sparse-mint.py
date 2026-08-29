#!/usr/bin/env python3
"""sparse-mint.py — mint the sparse-unstamped fixture class by rewriting PES
headers of an existing .ts IN PLACE (WO-1.15.20 S2, tests/make-fixtures.sh).

No muxer will write this class: libavformat refuses a video packet that
carries data but no PTS (-22, measured on mpegts and matroska alike), which is
why the class only ever arises AFTER multiplexing, when a transport
discontinuity destroys PES header timestamps. So this mints it the same way
reality does — byte surgery on a valid transport stream.

Both edits are length-preserving and touch PES header bytes only; every
payload byte, and so the whole coded bitstream, is left exactly where it was:

  * hole      PTS_DTS_flags -> 00 and the 5 (or 10) timestamp bytes overwritten
              with 0xFF, which is legal PES stuffing. PES_header_data_length is
              unchanged, so nothing downstream shifts.
  * timeline  the 33-bit PTS/DTS fields re-encoded in place (ISO/IEC 13818-1
              2.4.3.7 marker layout), same offsets, same widths.

The imposed timeline is a PAFF field-pair shape: coded packets are paired
(2k, 2k+1) as the two fields of one frame, one field duration apart, and whole
frames are reordered (k <-> k^1) so the opposite parity is decisively wrong.
That is what makes the pairing PROVABLE, which is the only evidence the
pre-pass will reconstruct a hole from.

  * stale     (--dups) a packet re-encoded with the PTS an EARLIER packet
              already holds. This is the duplicate-display-slot class as it
              actually arises: a packet carries a timestamp across a transport
              discontinuity, so two pictures claim one rung. Length-preserving
              like the rest; the payload is untouched.

Usage: sparse-mint.py IN.ts OUT.ts PTS_BASE STEP_TICKS HOLES_CSV [--dups A:B,...]
       --dups A:B  make coded packet B carry the PTS coded packet A holds.
                   Positions are coded-order indices, as HOLES_CSV are.
"""
import sys

def enc(v, prefix, buf, at):
    """One 33-bit timestamp, 5 bytes, ISO/IEC 13818-1 marker layout."""
    buf[at] = (prefix << 4) | ((v >> 29) & 0x0E) | 1
    buf[at + 1] = (v >> 22) & 0xFF
    buf[at + 2] = ((v >> 14) & 0xFE) | 1
    buf[at + 3] = (v >> 7) & 0xFF
    buf[at + 4] = ((v << 1) & 0xFE) | 1


def video_pes_sites(data):
    """Byte offset of every video PES header start, in transport order, and
    the PID they belong to. The first video-range stream_id seen wins, so a
    program with other elementary streams cannot pull the census off course."""
    sites, vpid = [], None
    for off in range(0, len(data), 188):
        if data[off] != 0x47:
            sys.exit("transport sync lost at byte %d — not a 188-byte TS" % off)
        if not (data[off + 1] >> 6) & 1:            # payload_unit_start_indicator
            continue
        pid = ((data[off + 1] & 0x1F) << 8) | data[off + 2]
        afc = (data[off + 3] >> 4) & 3
        if afc in (0, 2):                            # no payload
            continue
        p = off + 4
        if afc == 3:
            p += 1 + data[off + 4]                   # skip the adaptation field
        if p + 9 > off + 188 or data[p:p + 3] != b"\x00\x00\x01":
            continue
        if not (0xE0 <= data[p + 3] <= 0xEF):        # video stream_id range
            continue
        if vpid is None:
            vpid = pid
        if pid == vpid:
            sites.append(p)
    return sites, vpid


def main():
    argv = sys.argv[1:]
    dups = {}
    if "--dups" in argv:
        i = argv.index("--dups")
        for pair in argv[i + 1].split(","):
            if not pair.strip():
                continue
            a, b = pair.split(":")
            dups[int(b)] = int(a)          # victim -> the packet whose value it steals
        del argv[i:i + 2]
    if len(argv) != 5:
        sys.exit(__doc__.strip().splitlines()[-1])
    src, dst, base, step = argv[0], argv[1], int(argv[2]), int(argv[3])
    holes = set(int(x) for x in argv[4].split(",") if x.strip())
    data = bytearray(open(src, "rb").read())
    if len(data) % 188 or not data or data[0] != 0x47:
        sys.exit("input is not a bare 188-byte transport stream")
    sites, vpid = video_pes_sites(data)
    n = len(sites)
    if n < 2:
        sys.exit("found %d video PES packets — nothing to shape" % n)
    stray = sorted(h for h in holes if not 0 <= h < n)
    if stray:
        sys.exit("hole positions outside the %d-packet column: %s" % (n, stray))
    pairs = n // 2
    for i, p in enumerate(sites):
        k, side = i // 2, i % 2
        f = k ^ 1                       # swap adjacent frames: the reorder
        if f >= pairs:
            f = k                       # an odd tail frame maps to itself
        flags = (data[p + 7] >> 6) & 3
        if flags == 0:
            sys.exit("video PES %d carries no timestamp to rewrite" % i)
        if i in holes:
            data[p + 7] &= 0x3F                              # flags -> 00
            for q in range(10 if flags == 3 else 5):
                data[p + 9 + q] = 0xFF                       # legal PES stuffing
            continue
        if i in dups:
            # the stale-timestamp class: this packet carries the value the
            # packet at dups[i] holds, so two pictures claim one display slot.
            j = dups[i]
            jk, jside = j // 2, j % 2
            jf = jk ^ 1
            if jf >= pairs:
                jf = jk
            enc(base + (2 * jf + jside) * step, 0x3 if flags == 3 else 0x2, data, p + 9)
        else:
            enc(base + (2 * f + side) * step, 0x3 if flags == 3 else 0x2, data, p + 9)
        if flags == 3:
            # a coded-order DTS ramp two fields behind presentation: monotonic
            # by construction, and <= PTS for both members of every pair.
            enc(base + (i - 2) * step, 0x1, data, p + 14)
    open(dst, "wb").write(data)
    print("shaped %d video PES on pid %d (%d pairs, step %d), holes: %s, stale: %s"
          % (n, vpid, pairs, step, sorted(holes) or "none",
             sorted("%d<-%d" % (v, k) for k, v in dups.items()) or "none"))


if __name__ == "__main__":
    main()

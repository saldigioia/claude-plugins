#!/usr/bin/env python3
# nalhash.py — verify.sh gate (m): the essence ARBITER. Hashes a video track's
# VCL NAL PAYLOADS, ignoring Annex-B start-code length.
#
# WHY THIS EXISTS (measured 2026-08-29, feed.ts). Gate (b) hashes the byte
# stream that comes out of `filter_units=pass_types=1-5`. That is the right
# essence for almost every route — but merging two field access units into one
# MOV sample (ISO/IEC 14496-15: both fields of a complementary pair live in a
# SINGLE sample) legitimately turns a 4-byte start code into a 3-byte one. The
# coded picture data is identical to the bit; the byte stream is shorter by
# exactly one byte per merged pair. A raw byte hash therefore reports a false
# MISMATCH against a provably correct build.
#
# So this is an ARBITER, not a replacement: gate (b) runs first and costs
# nothing extra, and this pass is paid ONLY to adjudicate a mismatch. It
# strips start codes and hashes the NAL payloads, which no framing choice can
# change. Agreement here PROVES the essence survived; disagreement is a real
# essence difference and gate (b)'s FAIL stands.
#
# It is deliberately NOT the same fact as gate (b) restated: gate (b) proves
# "the bytes are identical", this proves "the coded pictures are identical".
# Where they disagree, the framing changed and the pictures did not.
#
# Usage: nalhash.py FILE [--bsf CHAIN] [--kv]
#   --bsf CHAIN  bitstream-filter chain (default: filter_units=pass_types=1-5;
#                an MP4/MOV input needs h264_mp4toannexb in front — the driver
#                supplies it, this script never guesses a container)
#   --kv         machine output only
# Emits:  NH_NALS=n NH_PAYLOAD=bytes NH_MD5=hex NH_OK=yes|no NH_WHY=-|…
# Exit:   0 hashed | 1 the extraction failed (NH_OK=no, reason named) | 2 usage
#
# EMPTY is not ABSENT (Constitution III.1): a failed ffmpeg is reported as
# NH_OK=no with its rc, never as an empty hash the caller could read as "no
# essence".

import hashlib
import subprocess
import sys

SC = b"\x00\x00\x01"
CHUNK = 1 << 22
FLUSH_AT = 1 << 24          # inside a NAL larger than this, flush what cannot
                            # contain a split start code (keep memory bounded)


def main(argv):
    path = None
    bsf = "filter_units=pass_types=1-5"
    kv = False
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--bsf":
            if i + 1 >= len(argv):
                sys.stderr.write("--bsf needs a chain\n")
                return 2
            bsf = argv[i + 1]
            i += 2
        elif a == "--kv":
            kv = True
            i += 1
        elif a.startswith("-"):
            sys.stderr.write("unknown opt: %s\n" % a)
            return 2
        else:
            if path is not None:
                sys.stderr.write("one FILE only (got: %s, %s)\n" % (path, a))
                return 2
            path = a
            i += 1
    if path is None:
        sys.stderr.write("usage: nalhash.py FILE [--bsf CHAIN] [--kv]\n")
        return 2

    p = subprocess.Popen(
        ["ffmpeg", "-nostdin", "-v", "error", "-i", path, "-map", "0:v:0",
         "-c", "copy", "-bsf:v", bsf, "-f", "h264", "-"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    md5 = hashlib.md5()
    nals = 0
    payload = 0
    buf = b""
    started = False
    while True:
        chunk = p.stdout.read(CHUNK)
        if not chunk:
            break
        buf += chunk
        pos = 0
        while True:
            j = buf.find(SC, pos)
            if j < 0:
                break
            # a preceding zero byte makes it a 4-byte start code; the payload
            # ends before it either way, which is the whole point
            nal_end = j - 1 if (j > 0 and buf[j - 1] == 0) else j
            if started:
                md5.update(buf[pos:nal_end])
                payload += nal_end - pos
            started = True
            nals += 1
            pos = j + 3
        if pos > 0:
            buf = buf[pos:]
        elif len(buf) > FLUSH_AT:
            if started:
                md5.update(buf[:-3])
                payload += len(buf) - 3
            buf = buf[-3:]
    p.stdout.close()
    err = p.stderr.read().decode("utf-8", "replace").strip()
    p.stderr.close()
    rc = p.wait()
    if started and buf:
        md5.update(buf)
        payload += len(buf)

    ok = "yes"
    why = "-"
    if rc != 0:
        ok, why = "no", "ffmpeg rc=%d" % rc
    elif nals == 0:
        ok, why = "no", "no VCL NAL parsed (wrong bsf chain for this container?)"

    if not kv:
        print("%-28s nals=%-9d payload_bytes=%-14d md5=%s"
              % (path.split("/")[-1], nals, payload, md5.hexdigest()))
        if ok == "no":
            sys.stderr.write("nalhash: %s\n" % why)
            if err:
                sys.stderr.write("  ffmpeg: %s\n" % err.splitlines()[0])
    print("NH_NALS=%d" % nals)
    print("NH_PAYLOAD=%d" % payload)
    print("NH_MD5=%s" % md5.hexdigest())
    print("NH_OK=%s" % ok)
    print("NH_WHY=%s" % why)
    return 0 if ok == "yes" else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

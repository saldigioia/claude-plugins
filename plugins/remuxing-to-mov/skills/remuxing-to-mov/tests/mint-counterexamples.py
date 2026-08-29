#!/usr/bin/env python3
"""mint-counterexamples.py — the two 2026-08-28 builds that were BIT-PERFECT
and unusable. They exist so gates (h) and (i) can be SEEN to fail (V.2), and
so the claim "an essence hash is necessary and not sufficient" is a fixture
somebody can run rather than a sentence somebody wrote.

Neither is a tool. Nothing in scripts/ imports this; it mints test material.

  field-per-sample   one MOV sample per coded FIELD. Minted by a plain
                     `ffmpeg -c copy` of a PAFF source — which is the finding:
                     the defect needs no exotic tool, the obvious command
                     produces it. ISO/IEC 14496-15 puts both fields of a
                     complementary pair in ONE sample, so the container ends up
                     claiming ~50/s over a ~25/s decode. Requires a real PAFF
                     source (--paff): field coding cannot be minted by libx264,
                     which does MBAFF, not PAFF.

  mislabelled-audio  a '.mp3' sample entry over MPEG-1 Layer II payload.
                     Minted by patching the stsd sample-entry fourcc of a real
                     '.mp2' build — byte-for-byte the artifact PyAV produced by
                     resolving MP2 through the mp3float DECODER and inheriting
                     codec id MP3 from the template. Patching is deterministic,
                     needs no PyAV, and ffmpeg's own muxer REFUSES to write the
                     combination ("Tag .mp3 incompatible with output codec id"),
                     which is why it has to be made after the fact.

usage: mint-counterexamples.py --out DIR [--paff SOURCE.ts] [--mp2 SOURCE.ts]
exit:  0 minted what it could (it says which) | 2 usage/env
"""
import argparse
import os
import subprocess
import sys


def run(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def mint_field_per_sample(src, outdir):
    """A plain copy of PAFF: one sample per coded field."""
    dst = os.path.join(outdir, "field-per-sample.mov")
    ref = os.path.join(outdir, "field-per-sample.src.ts")
    # video only, so the counter-example isolates the STRUCTURAL defect: with
    # audio in the file the old suite also flags naked MP2 and A/V duration,
    # and "the old gates were green" stops being a clean statement.
    r = run("ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-i", src,
            "-map", "0:v:0", "-c", "copy", "-f", "mpegts", ref)
    if r.returncode != 0:
        return None, "could not cut the reference source: %s" % r.stderr.strip()[:200]
    r = run("ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-i", ref,
            "-map", "0:v:0", "-c", "copy", "-tag:v", "avc1",
            "-avoid_negative_ts", "make_zero", dst)
    if r.returncode != 0:
        return None, "plain copy failed: %s" % r.stderr.strip()[:200]
    n = run("ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_entries", "packet=pts", "-of", "csv=p=0", dst).stdout
    samples = len([x for x in n.splitlines() if x.strip()])
    return dst, "%d samples" % samples


def mint_mislabelled_audio(src, outdir):
    """A '.mp3' sample entry over Layer II payload."""
    good = os.path.join(outdir, "mislabelled-audio.good.mov")
    dst = os.path.join(outdir, "mislabelled-audio.mov")
    ref = os.path.join(outdir, "mislabelled-audio.src.ts")
    r = run("ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-i", src,
            "-map", "0:a:0", "-c", "copy", "-f", "mpegts", ref)
    if r.returncode != 0:
        return None, "could not cut the reference source: %s" % r.stderr.strip()[:200]
    r = run("ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-i", ref,
            "-map", "0:a:0", "-c", "copy", good)
    if r.returncode != 0:
        return None, "the honest '.mp2' build failed: %s" % r.stderr.strip()[:200]
    data = open(good, "rb").read()
    hits = data.count(b".mp2")
    if hits != 1:
        # Refuse rather than patch the wrong bytes: a fixture that is not the
        # defect it claims to be is worse than no fixture (V.3).
        return None, ("found %d occurrences of the '.mp2' fourcc, expected exactly 1 "
                      "— refusing to guess which one is the sample entry" % hits)
    open(dst, "wb").write(data.replace(b".mp2", b".mp3", 1))
    tag = run("ffprobe", "-v", "error", "-select_streams", "a:0",
              "-show_entries", "stream=codec_tag_string,codec_name",
              "-of", "csv=p=0", dst).stdout.strip()
    return dst, "sample entry now reads %s over Layer II payload" % tag


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--paff", help="a real PAFF (field-coded H.264) source")
    ap.add_argument("--mp2", help="a source carrying MPEG-1 Layer II audio")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    if not a.paff and not a.mp2:
        sys.stderr.write("nothing to mint: give --paff and/or --mp2\n")
        return 2
    made = 0
    for label, src, fn in (("field-per-sample", a.paff, mint_field_per_sample),
                           ("mislabelled-audio", a.mp2, mint_mislabelled_audio)):
        if not src:
            print("%-20s SKIP (no source given)" % label)
            continue
        if not os.path.exists(src):
            print("%-20s SKIP (no such source: %s)" % (label, src))
            continue
        path, why = fn(src, a.out)
        if path is None:
            print("%-20s FAILED: %s" % (label, why))
        else:
            print("%-20s %s  (%s)" % (label, path, why))
            made += 1
    print("minted %d counter-example(s)" % made)
    return 0


if __name__ == "__main__":
    sys.exit(main())

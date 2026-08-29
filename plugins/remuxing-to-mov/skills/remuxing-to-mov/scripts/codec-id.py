#!/usr/bin/env python3
# codec-id.py — verify.sh gate (i): does the container's SAMPLE ENTRY describe
# the payload it is sitting on top of?
#
# WHY THIS EXISTS (measured 2026-08-29, feed.ts). A remux of MPEG-1 Layer II
# audio shipped with a '.mp3' sample entry. It was bit-identical to the source,
# so gates (a)/(b) proved it lossless; it decoded without one error, so gate
# (g) passed it — ffmpeg resolves '.mp3' to the mp3float decoder, which decodes
# Layer II happily, and Apple documents '.mp3' as Layer *3*. Every check the
# plugin had was blind to the mislabel, because the defect is in what the
# container DECLARES, not in what it stores.
#
# TWO HALVES, because they prove different things:
#   (i1) TAG <-> CODEC: the sample-entry fourcc must denote the codec the
#        container also names. Cheap (one ffprobe), covers every stream.
#   (i2) TAG <-> PAYLOAD: for formats that carry self-describing frame headers,
#        parse the payload itself and compare. MPEG-1/2 audio (layer + version
#        bits) and AC-3/E-AC-3 (bsid) are provable; AAC-in-esds and raw PCM are
#        not provable from the payload and are reported UNPROVEN, never passed
#        quietly (Constitution II.1 — a gate that cannot evaluate says so).
#
# Usage: codec-id.py FILE [--stream SPEC] [--kv]
#   --stream SPEC  ffmpeg stream specifier (default: every a: and v: stream)
# Emits one row per stream plus a summary:
#   CI_ROW idx=N type=… codec=… tag=… declared_layer=… payload=… verdict=ok|MISMATCH|unproven why=…
#   CI_STREAMS=n CI_OK=n CI_MISMATCH=n CI_UNPROVEN=n
# Exit: 0 no mismatch | 1 at least one MISMATCH | 2 usage/unreadable
#
# The tag->codec table below is THIS tool's fact and has one writer. It is NOT
# the QuickTime-native audio table (lib-paff.sh, Constitution IV.3) — that one
# answers "will QuickTime play this natively", a different question with a
# different answer set.

import json
import subprocess
import sys

# sample-entry fourcc -> the codec_name(s) it may legitimately denote.
# Sources: Apple QTFF sound/video sample description lists + the ISO
# registration authority. A tag absent here is UNKNOWN, which is reported as
# unproven, never as a mismatch: an unrecognized tag is missing knowledge here,
# not proven damage in the file (Constitution II.1).
TAG_CODEC = {
    # --- video -------------------------------------------------------------
    "avc1": {"h264"}, "avc3": {"h264"},
    "hvc1": {"hevc"}, "hev1": {"hevc"},
    # 'mp4v' is the GENERIC MPEG-4 visual sample entry: the esds descriptor's
    # objectTypeIndication selects the actual codec, and MPEG-2 and MPEG-1
    # video are both legal there. That is not a corner case here — it is this
    # plugin's own container-swap route (mp4-swap.sh: same bitstream, .mp4,
    # mp4v+esds). A narrower table accused that route of a mislabel it does not
    # have (measured 2026-08-29, caught by test 44).
    "mp4v": {"mpeg4", "mpeg2video", "mpeg1video", "mjpeg"},
    "mjpa": {"mjpeg"}, "jpeg": {"mjpeg"}, "mjpg": {"mjpeg"},
    "apch": {"prores"}, "apcn": {"prores"}, "apcs": {"prores"},
    "apco": {"prores"}, "ap4h": {"prores"}, "ap4x": {"prores"},
    "dvh5": {"dvvideo"}, "dvhp": {"dvvideo"}, "dvc ": {"dvvideo"},
    "m2v1": {"mpeg2video"}, "mp2v": {"mpeg2video"}, "hdv3": {"mpeg2video"},
    "v210": {"v210"}, "rle ": {"qtrle"},
    # --- audio -------------------------------------------------------------
    # '.mp3' is Apple-documented as Layer 3 ONLY. ffmpeg writes '.mp2' for
    # Layer II by its own convention (not in Apple's list — see
    # references/paff-poc.md); both are accepted as tags, and (i2) is what
    # decides whether the payload underneath agrees.
    ".mp3": {"mp3"}, ".mp2": {"mp2"}, ".mp1": {"mp1"},
    "mp4a": {"aac", "mp3", "mp2", "alac"},   # esds decides; (i2) reports unproven
    "ac-3": {"ac3"}, "ec-3": {"eac3"},
    "alac": {"alac"},
    "twos": {"pcm_s16be"}, "sowt": {"pcm_s16le"},
    "in24": {"pcm_s24be", "pcm_s24le"}, "in32": {"pcm_s32be", "pcm_s32le"},
    "fl32": {"pcm_f32be", "pcm_f32le"}, "fl64": {"pcm_f64be", "pcm_f64le"},
    "raw ": {"pcm_u8"}, "ulaw": {"pcm_mulaw"}, "alaw": {"pcm_alaw"},
    "ima4": {"adpcm_ima_qt"}, "lpcm": {"pcm_s16le", "pcm_s24le", "pcm_s32le",
                                       "pcm_f32le", "pcm_f64le", "pcm_s16be",
                                       "pcm_s24be", "pcm_s32be"},
}

# a tag that ASSERTS an MPEG audio layer: the payload must agree
TAG_LAYER = {".mp1": 1, ".mp2": 2, ".mp3": 3}
CODEC_LAYER = {"mp1": 1, "mp2": 2, "mp3": 3}
MPEG_VERSION = {0: "2.5", 1: None, 2: "2", 3: "1"}
MPEG_RATES = {3: [44100, 48000, 32000], 2: [22050, 24000, 16000],
              0: [11025, 12000, 8000]}
PAYLOAD_BYTES = 1 << 18       # enough for many frames; we only need headers


def ffprobe_streams(path):
    p = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries",
         "stream=index,codec_type,codec_name,codec_tag_string,sample_rate,"
         "channels,profile,bits_per_raw_sample",
         "-of", "json", path],
        capture_output=True, text=True)
    if p.returncode != 0:
        return None, "ffprobe rc=%d" % p.returncode
    try:
        return json.loads(p.stdout or "{}").get("streams", []), None
    except ValueError as e:
        return None, "unparsable ffprobe json (%s)" % e


def raw_payload(path, spec):
    """First PAYLOAD_BYTES of a stream's packets, copied, no decode."""
    p = subprocess.Popen(
        ["ffmpeg", "-nostdin", "-v", "error", "-i", path, "-map", spec,
         "-c", "copy", "-f", "data", "-"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    data = p.stdout.read(PAYLOAD_BYTES)
    p.stdout.close()
    p.kill()
    p.wait()
    return data


def mpeg_audio_frames(data):
    """(version, layer, rate, frames) from MPEG-1/2/2.5 audio frame headers.

    Requires several CONSECUTIVE agreeing headers before it reports anything:
    a single 0xFFE pattern occurs by chance inside compressed payload, and a
    verdict of MISMATCH must never rest on one coincidence.
    """
    best = None
    i = 0
    n = len(data)
    while i < n - 4:
        if data[i] != 0xFF or (data[i + 1] & 0xE0) != 0xE0:
            i += 1
            continue
        ver = (data[i + 1] >> 3) & 3
        lay = (data[i + 1] >> 1) & 3
        rate_i = (data[i + 2] >> 2) & 3
        if MPEG_VERSION.get(ver) is None or lay == 0 or rate_i == 3:
            i += 1
            continue
        rate = MPEG_RATES[ver][rate_i]
        layer = 4 - lay
        # walk forward frame by frame; agreement over several frames is the
        # evidence, not the first sync word
        agree = 1
        j = i
        for _ in range(8):
            nxt = _next_frame(data, j)
            if nxt is None:
                break
            if (data[nxt + 1] & 0xFE) != (data[i + 1] & 0xFE):
                break
            agree += 1
            j = nxt
        if best is None or agree > best[3]:
            best = (MPEG_VERSION[ver], layer, rate, agree)
        if agree >= 4:
            return best
        i += 1
    return best


BITRATES = {
    (1, 1): [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448],
    (1, 2): [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],
    (1, 3): [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],
    (2, 1): [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256],
    (2, 2): [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
}


def _next_frame(data, i):
    ver = (data[i + 1] >> 3) & 3
    lay = (data[i + 1] >> 1) & 3
    br_i = (data[i + 2] >> 4) & 0xF
    rate_i = (data[i + 2] >> 2) & 3
    pad = (data[i + 2] >> 1) & 1
    if lay == 0 or br_i in (0, 15) or rate_i == 3 or MPEG_VERSION.get(ver) is None:
        return None
    layer = 4 - lay
    vkey = 1 if ver == 3 else 2
    # MPEG-2/2.5 Layers II and III share one bitrate table; Layer I has its own
    table = BITRATES.get((vkey, layer) if vkey == 1 else (2, 1 if layer == 1 else 2))
    if table is None:
        return None
    br = table[br_i] * 1000
    rate = MPEG_RATES[ver][rate_i]
    if layer == 1:
        size = (12 * br // rate + pad) * 4
    else:
        spf = 1152 if (vkey == 1 or layer == 2) else 576
        size = (spf // 8) * br // rate + pad
    if size <= 4:
        return None
    j = i + size
    if j + 4 > len(data) or data[j] != 0xFF or (data[j + 1] & 0xE0) != 0xE0:
        return None
    return j


def ac3_bsid(data):
    """bsid from the first AC-3/E-AC-3 sync frame: <=8 is AC-3, 16 is E-AC-3."""
    for i in range(0, min(len(data), 1 << 16) - 6):
        if data[i] == 0x0B and data[i + 1] == 0x77:
            return data[i + 5] >> 3
    return None


def main(argv):
    path = None
    only = None
    kv = False
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--stream":
            if i + 1 >= len(argv):
                sys.stderr.write("--stream needs a specifier\n")
                return 2
            only = argv[i + 1]
            i += 2
        elif a == "--kv":
            kv = True
            i += 1
        elif a.startswith("-"):
            sys.stderr.write("unknown opt: %s\n" % a)
            return 2
        else:
            if path is not None:
                sys.stderr.write("one FILE only\n")
                return 2
            path = a
            i += 1
    if path is None:
        sys.stderr.write("usage: codec-id.py FILE [--stream SPEC] [--kv]\n")
        return 2

    streams, err = ffprobe_streams(path)
    if streams is None:
        # EMPTY is not ABSENT: an unreadable file is reported, never counted
        # as "no streams, therefore nothing wrong".
        print("CI_STREAMS=0")
        print("CI_OK=0")
        print("CI_MISMATCH=0")
        print("CI_UNPROVEN=0")
        print("CI_READ=no")
        print("CI_WHY=%s" % err)
        sys.stderr.write("codec-id: cannot read %s (%s)\n" % (path, err))
        return 2

    nok = nmis = nunp = 0
    seen = 0
    a_ord = v_ord = 0
    for s in streams:
        ctype = s.get("codec_type", "")
        if ctype not in ("audio", "video"):
            continue
        spec = None
        if ctype == "audio":
            spec = "0:a:%d" % a_ord
            a_ord += 1
        else:
            spec = "0:v:%d" % v_ord
            v_ord += 1
        if only and only not in (spec, spec.split(":", 1)[1], str(s.get("index"))):
            continue
        seen += 1
        codec = s.get("codec_name", "?")
        tag = s.get("codec_tag_string", "?")
        verdict = "unproven"
        why = "-"
        observed = "-"
        declared = "-"

        # ---- (i1) tag <-> codec ------------------------------------------
        allowed = TAG_CODEC.get(tag)
        if allowed is None:
            why = "tag '%s' is not in this tool's registry — unrecognized, not proven wrong" % tag
        elif codec not in allowed:
            verdict = "MISMATCH"
            why = ("sample entry '%s' denotes %s but the container names codec %s"
                   % (tag, "/".join(sorted(allowed)), codec))
        else:
            verdict = "ok"
            why = "tag '%s' agrees with codec %s" % (tag, codec)

        # ---- (i2) tag <-> payload ----------------------------------------
        if ctype == "audio" and verdict != "MISMATCH":
            want_layer = TAG_LAYER.get(tag, CODEC_LAYER.get(codec))
            if want_layer is not None:
                declared = "MPEG Layer %s" % want_layer
                fr = mpeg_audio_frames(raw_payload(path, spec))
                if fr is None or fr[3] < 4:
                    verdict = "unproven"
                    why = ("declares %s but no run of agreeing MPEG frame headers "
                           "was found in the sampled payload — layer unproven"
                           % declared)
                    observed = "no-frame-run"
                else:
                    observed = "MPEG-%s Layer %s @ %d Hz (%d agreeing frames)" % (
                        fr[0], fr[1], fr[2], fr[3])
                    if fr[1] != want_layer:
                        verdict = "MISMATCH"
                        why = ("sample entry declares Layer %s; the payload frame "
                               "headers say Layer %s — the container mislabels the "
                               "essence it stores (decoders that accept both hide this)"
                               % (want_layer, fr[1]))
                    else:
                        verdict = "ok"
                        why = "payload frame headers confirm %s" % declared
            elif codec in ("ac3", "eac3"):
                declared = codec
                b = ac3_bsid(raw_payload(path, spec))
                if b is None:
                    verdict = "unproven"
                    why = "no AC-3 sync frame in the sampled payload"
                    observed = "no-sync"
                else:
                    observed = "bsid=%d" % b
                    got = "eac3" if b == 16 else "ac3"
                    if got != codec:
                        verdict = "MISMATCH"
                        why = ("container names %s; the payload's bsid=%d is %s"
                               % (codec, b, got))
                    else:
                        verdict = "ok"
                        why = "payload bsid=%d confirms %s" % (b, codec)
            elif verdict == "ok":
                # tag/codec agree and the payload carries no self-describing
                # header this tool can read (AAC in esds, raw PCM): (i1) proven,
                # (i2) unprovable — say which.
                why += "; payload carries no readable frame header (i2 unprovable for %s)" % codec

        if verdict == "ok":
            nok += 1
        elif verdict == "MISMATCH":
            nmis += 1
        else:
            nunp += 1
        print("CI_ROW idx=%s type=%s codec=%s tag=%s declared=%s payload=%s "
              "verdict=%s why=%s"
              % (s.get("index"), ctype, codec, tag, declared, observed,
                 verdict, why))

    print("CI_STREAMS=%d" % seen)
    print("CI_OK=%d" % nok)
    print("CI_MISMATCH=%d" % nmis)
    print("CI_UNPROVEN=%d" % nunp)
    print("CI_READ=yes")
    print("CI_WHY=-")
    return 1 if nmis else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

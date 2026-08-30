#!/usr/bin/env python3
"""lib_faststart.py — the faststart policy, for the tree's two PyAV writers.

The shell side keeps this fact in lib-mux.sh (rtm_faststart_on / rtm_movflags /
rtm_faststart_announce). The PyAV writers — poc-remux.py and derive-dts.py —
need the same fact, and before 1.16.7 they disagreed with the shell AND with
each other: derive-dts.py hardcoded "+faststart", poc-remux.py set no movflags
at all. Two writers, three policies. This module is the one writer for the
Python half (1.15.14 doctrine: share the FACT, not the presentation).

POLICY. Every .mov-writing route defaults to faststart, the POC rung included.
The opt-out is MANUAL and ANNOUNCED — RTM_FASTSTART=0, or a route's
--no-faststart. Nothing turns it off on the file's behalf: not the output's
size, not "this one looks archival". An automatic opt-out would recreate the
unannounced divergence 1.16.7 exists to remove.

COST, measured 2026-08-29 (ffmpeg 9.0.1 / libavformat 63.1.101, macOS 26.6.1,
3.93 GiB output, external APFS SSD): libavformat performs the relocation IN
PLACE — it reopens the finished output for reading and shifts the media data
forward; no temp file appeared across 50 directory samples, and peak disk was
1.000x the output size. So the disk pre-flight budget is unchanged by faststart.
The cost is TIME: 8.1 s to mux, 10.9 s more to relocate (19.0 s wall).
"""

import os
import sys

ENV = "RTM_FASTSTART"


def resolve(no_faststart=False):
    """True when faststart is in force for this run.

    Either opt-out disables it: the route's --no-faststart flag, or
    RTM_FASTSTART=0 in the environment. Anything else (unset, "1", junk) is
    the default ON — a knob nobody set is not an opt-out.
    """
    if no_faststart:
        return False
    return os.environ.get(ENV, "1") != "0"


def options(on, extra=None):
    """The PyAV container-options dict for this policy.

    Returns {} rather than {"movflags": ""} when nothing is set: libavformat
    rejects an empty movflags VALUE ("Unable to parse movflags option value" —
    measured on this bench), so "no flags" has to mean "no option", exactly as
    the shell side builds an empty array rather than passing -movflags "".
    """
    flags = []
    if on:
        flags.append("+faststart")
    if extra:
        flags.extend(extra)
    return {"movflags": "".join(flags)} if flags else {}


def announce(route, on, out=None):
    """Print the announced choice + the machine line. Announced EITHER WAY."""
    w = out or sys.stdout
    if on:
        w.write("   faststart: ON — moov first, Apple's recommended creation order. The\n")
        w.write("   relocation is a second IN-PLACE pass: ~2x write I/O, no extra disk\n")
        w.write("   (measured peak 1.000x the output, 2026-08-29). Opt out with\n")
        w.write("   RTM_FASTSTART=0 or --no-faststart (announced, never automatic).\n")
        w.write("RTM_FASTSTART state=on route=%s\n" % route)
    else:
        w.write("   faststart: OFF (--no-faststart / RTM_FASTSTART=0) — moov is written\n")
        w.write("   LAST. The file is valid and durable, but it is not in Apple's\n")
        w.write("   recommended creation order and progressive/network playback stalls\n")
        w.write("   until the whole file has arrived. Operator opt-out.\n")
        w.write("RTM_FASTSTART state=off route=%s\n" % route)
    w.flush()

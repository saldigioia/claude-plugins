#!/usr/bin/env bash
# lib-probe.sh — the probe-window floor for every ffmpeg/ffprobe INPUT open.
# SOURCE this, don't run it. Loaded by lib-paff.sh and by every script that
# opens an input directly, so no call site can fall back to stock defaults.
#
# WHY: ffmpeg's stock probe window (-probesize 5M bytes / -analyzeduration 5M
# microseconds) is sized for web MP4s whose parameter sets sit at byte 0. This
# plugin's declared inputs are broadcast .ts/.mpg/.vob — a 32.4 Mbit/s BBC TS
# carried its first SPS ~6.4 MB in, past the 5 MB default: mov.sh died with
# "[mov] dimensions not set", plain ffprobe reported no streams at all, and —
# worse — the misprobe fed paff=no into strategy routing that a working probe
# later contradicted (paff=yes). A wrong probe doesn't just block the mux; it
# silently poisons rung selection. So every input open in scripts/ goes through
# these wrappers and inherits a 200M floor on both axes.
#
# Tunables (env; honored everywhere — the regression suite sets RTM_PROBESIZE=5M
# to reproduce the stock failure and prove the knob is really wired):
#   RTM_PROBESIZE        probe window in bytes         (default 200M = 200 MB)
#   RTM_ANALYZEDURATION  probe window in microseconds  (default 200M = 200 s)
#
# PLACEMENT IS LOAD-BEARING: both are INPUT options — ffmpeg applies them to
# the -i that FOLLOWS them; placed after the -i they would target the OUTPUT
# (rejected, or worse, misapplied). ffprobe takes exactly one input, so
# injecting right after the command name is always correct there; ffmpeg call
# sites splice "${FF_INPUT_OPTS[@]}" immediately before each -i whose probing
# matters (and never in front of an output path).
#
# COST: none on healthy files — probesize/analyzeduration are CEILINGS, not
# read-ahead: avformat stops the moment every stream's parameters are known.
# Only a source the stock window would have MISPROBED reads further, which is
# the point.
#
# Usage (house sourcing pattern — resolve your own dir so any CWD works):
#   . "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib-probe.sh"
#   ffp -v error -select_streams v:0 ... "$IN"        # ffprobe drop-in
#   ffmpeg -nostdin "${FF_INPUT_OPTS[@]}" -i "$IN" …  # before each ffmpeg -i
#
# Read-only: the wrappers widen how much of the source is READ during probing;
# they never change what is written.

# An array, not a string: a future spaced value must not word-split apart.
# Never empty, so "${FF_INPUT_OPTS[@]}" stays safe under bash 3.2 set -u.
FF_INPUT_OPTS=(-probesize "${RTM_PROBESIZE:-200M}" -analyzeduration "${RTM_ANALYZEDURATION:-200M}")

# ffprobe drop-in: one input per invocation -> inject first, pass through.
ffp () { ffprobe "${FF_INPUT_OPTS[@]}" "$@"; }

# ffp1 — first non-empty line of an ffprobe query, SIGPIPE-safe. awk reads to
# EOF, so ffprobe always completes its write: `head -1` under `pipefail`
# closes the pipe early and can take ffprobe down with SIGPIPE (exit 141),
# which `set -e` then promotes into a SILENT caller abort. Measured (1.15.2
# Defect A): `-show_entries program=` emits 1 program line + N blank
# program_stream lines, and on the field bench the 200M probe window lost the
# race 5/5 while the stock 5M window won it 5/5 — same 6-line output both
# ways. Use ffp1 for any query that can emit more than one line; on
# single-line queries it is byte-identical to `ffp ... | head -1`.
ffp1 () { ffp "$@" | awk 'NF && !g { print; g=1 }'; }

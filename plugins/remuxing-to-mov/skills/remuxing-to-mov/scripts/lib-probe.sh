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

# C locale, tree-wide: under a comma-decimal locale (de_DE etc.) macOS awk
# truncates float INPUT at the period and prints comma decimals, which re-enter
# other awk program texts and ffmpeg args — measured (CHECKUP-2026-08-27 A3):
# verify gate (f) silently passed a 2.543 s A/V desync, ts-health died rc=2
# with no output. ffprobe itself always emits C-locale periods; the corruption
# is purely consumer-side, so one pin here (sourced by every entry point that
# opens an input) closes it. Entry points that don't source this lib carry
# their own copy of this line.
export LC_ALL=C

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

# rtm_aud_manifest IN [ERRFILE] — THE per-track audio manifest. ONE WRITER
# (1.15.13 rule 2). This query, this parse and the WO 3.4 view-merge lived in
# TWO copies — probe.sh and remux.sh — and WO 3.4 was applied to one of them:
# the probe.sh copy then reported PR_AUD_n_LANG=und for four eng tracks for
# four versions (1.15.10, found in the field). Fixing the copy did not fix the
# copying, so the fact now has a single home and both drivers consume it.
#
# stdout: one line per track, already merged, in track order:
#     ord|codec|channels|layout|lang
# Values are RAW: an unknown layout stays EMPTY here on purpose. The fallback
# is presentation and belongs to the consumer — probe.sh prints "unknown",
# remux.sh synthesizes "Nch" for its curation key, and neither may impose its
# choice on the other.
# rc: ffprobe's own exit status, passed through untouched. EMPTY != ABSENT
# (WO-1.15.4 A1): a FAILED probe must never be readable as "no audio", so the
# caller decides how loudly to refuse — this function only declines to guess.
# ERRFILE (optional) captures ffprobe stderr for callers that quote it.
rtm_aud_manifest () {
  local _in="${1:?rtm_aud_manifest needs INPUT}" _err="${2:-/dev/null}" _raw _rc
  # `if` context, not `set +e`: a failing probe must not disarm the caller's
  # errexit for the lines that follow it.
  if _raw=$(ffp -v error -select_streams a         -show_entries stream=index,codec_name,channels,channel_layout:stream_tags=language         -of compact=p=0:nk=0 "$_in" 2>"$_err"); then _rc=0; else _rc=$?; fi
  [ "$_rc" -eq 0 ] || return "$_rc"
  printf '%s\n' "$_raw" | awk -F'|' '
    # BEGIN{n=0} is load-bearing: an UNINITIALIZED n used as an array subscript
    # is the empty string (not 0) in POSIX awk, silently storing record 0 at
    # C[""] while n++ still counts it. Both former copies carried this note;
    # the 1.15.10 port hit the trap on its first fixture anyway.
    BEGIN{ n=0 }
    NF{
      c="unknown"; ch=0; lay=""; lang="und"; idx=""
      for(i=1;i<=NF;i++){ eq=index($i,"="); k=substr($i,1,eq-1); v=substr($i,eq+1)
        if(k=="index")idx=v; else if(k=="codec_name")c=v; else if(k=="channels")ch=v
        else if(k=="channel_layout")lay=v; else if(k=="tag:language")lang=v }
      # WO 3.4 merge. A program-bearing TS lists every stream TWICE (a bare
      # top-level view, then the in-program view) and only ONE carries the PMT
      # tags — language. Dedupe by index, MERGING field-by-field: a KNOWN value
      # beats the parser placeholder (unknown/0/empty/und), never whole-record
      # replacement, so a tagged view with a missing layout cannot clobber a
      # known one whichever arrives first. When both views know, the EARLIER
      # wins and the record keeps its slot, so a:N order and every
      # order-derived tie-break hold. Pinned by tests 34 and 92.
      if(idx!=""){
        if(idx in pos){ o=pos[idx]
          if(C[o]=="unknown" && c!="unknown") C[o]=c
          if(CH[o]+0==0     && ch+0!=0)      CH[o]=ch
          if(L[o]==""       && lay!="")      L[o]=lay
          if(G[o]=="und"    && lang!="und")  G[o]=lang
          next }
        pos[idx]=n
      }
      C[n]=c; CH[n]=ch; L[n]=lay; G[n]=lang; n++
    }
    END{ for(i=0;i<n;i++) printf "%d|%s|%s|%s|%s\n", i, C[i], CH[i], L[i], G[i] }'
}

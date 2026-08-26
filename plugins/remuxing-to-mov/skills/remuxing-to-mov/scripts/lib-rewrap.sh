#!/usr/bin/env bash
# lib-rewrap.sh — shared plumbing for SAME-CONTAINER (mpegts) re-wraps: the
# source clinic's zero-base and surgical-cut rungs. SOURCED, never executed
# (like lib-probe.sh / lib-paff.sh / lib-mux.sh). Callers must have sourced
# lib-probe.sh first (ffp / FF_INPUT_OPTS).
#
# Two jobs:
#
# 1. LAYOUT PRESERVATION (rewrap_layout): a naive TS->TS copy renumbers PIDs
#    and the PMT to ffmpeg defaults. The clinic's contract is a SIBLING of the
#    source, so the probed stream PIDs, PMT PID and service id ride into the
#    mux (the case-file recipe: -streamid per stream, -mpegts_pmt_start_pid,
#    -mpegts_service_id). The transport_stream_id is not ffprobe-exposed on
#    this bench — the muxer default applies, announced. Multi-program sources
#    are the caller's pre-flight refusal (the mpegts muxer cannot reconstruct
#    a multi-program layout from -map 0; known-limits.md names the
#    isolate-one-program route).
#
# 2. THE PREDICTION CONTRACT (rewrap_predict / rewrap_nudges): a null-muxer
#    copy pre-pass predicts exactly what a real mux will hit — the feed.ts
#    case measured 9 equal-DTS collision sites in the pre-pass and exactly 9
#    one-tick nudges in the build. The clinic announces the expected artifact
#    set BEFORE building and reconciles the build's mux log against it after:
#    observed != predicted is a verdict, not a shrug. Both passes ride
#    -copyts so collision arithmetic is identical on both sides.
#
# Hard-stop discipline is unchanged: the pair-timestamped-PAFF confessions
# (`pts has no value` / `Timestamps are unset`) remain the mux-invented-timing
# class — rewrap_hard_confessions counts ONLY those, and any count > 0 means
# the artifact is never blessed. Equal-DTS "Non-monotonic DTS ... changing to"
# nudges are the SEPARATE, predicted class (+1 tick, presentation untouched —
# measured in the case file); rewrap_nudges counts only them.

# rewrap_layout FILE — probes the mpegts layout; fills the caller's globals:
#   RW_STREAMID_OPTS[]  -streamid OUTIDX:PID per mapped stream (source order)
#   RW_MUX_OPTS[]       -mpegts_pmt_start_pid / -mpegts_service_id when probed
#   RW_LAYOUT_NOTE      one human line describing what is preserved
rewrap_layout () {
  local f="$1" line n=0 pid pmt svc
  RW_STREAMID_OPTS=(); RW_MUX_OPTS=(); RW_LAYOUT_NOTE=""
  while IFS=, read -r _idx pid; do
    case "$pid" in 0x*)
      RW_STREAMID_OPTS+=(-streamid "$n:$((pid))")
      ;;
    esac
    n=$((n+1))
  done < <(ffp -v error -show_entries stream=index,id -of csv=p=0 "$f" 2>/dev/null | \
           awk -F, 'NF>=2{ if(seen[$1]++) next; print }')
  pmt=$(ffp -v error -show_entries program=pmt_pid -of csv=p=0 "$f" 2>/dev/null | head -1 | tr -d ,)
  svc=$(ffp -v error -show_entries program=program_num -of csv=p=0 "$f" 2>/dev/null | head -1 | tr -d ,)
  case "$pmt" in ''|*[!0-9]*) pmt="";; esac
  case "$svc" in ''|*[!0-9]*) svc="";; esac
  [ -n "$pmt" ] && RW_MUX_OPTS+=(-mpegts_pmt_start_pid "$pmt")
  [ -n "$svc" ] && RW_MUX_OPTS+=(-mpegts_service_id "$svc")
  RW_LAYOUT_NOTE="stream PIDs preserved: $((${#RW_STREAMID_OPTS[@]} / 2)); PMT pid ${pmt:-default}; service id ${svc:-default}; transport_stream_id: muxer default (not ffprobe-exposed)"
}

# rewrap_predict FILE [BSF_V] [BSF_A] — null-muxer copy pre-pass; prints the
# predicted equal-DTS nudge count on stdout (one number). Filters, when given,
# replay the caller's intended selection so the prediction covers the packets
# that will actually meet the muxer.
rewrap_predict () {
  local f="$1" fv="${2:-}" fa="${3:-}" log args=()
  [ -n "$fv" ] && args+=(-bsf:v "$fv")
  [ -n "$fa" ] && args+=(-bsf:a "$fa")
  log="$(mktemp)"
  ffmpeg -nostdin -v warning "${FF_INPUT_OPTS[@]}" -copyts -i "$f" -map 0 -c copy \
    ${args[@]+"${args[@]}"} -f null - 2>"$log" || true
  rewrap_nudges "$log"
  rm -f "$log"
}

# rewrap_nudges LOGFILE — count of equal-DTS monotonicity nudges (the
# predicted +1-tick class), and ONLY those.
rewrap_nudges () { grep -ci 'non-monotonic dts' "$1" || true; }

# rewrap_hard_confessions LOGFILE — count of invented-timing confessions (the
# hard-stop class). Any nonzero: never bless.
rewrap_hard_confessions () {
  grep -ciE 'pts has no value|timestamps are unset' "$1" || true
}

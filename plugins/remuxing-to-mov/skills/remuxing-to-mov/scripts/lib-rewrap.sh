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
# 2. THE PREDICTION CONTRACT (rewrap_predict / rewrap_nudges): a TRUE DRY RUN
#    of the caller's build — same mpegts muxer, same timestamp arithmetic
#    (-muxdelay 0 -muxpreload 0), same layout opts, bytes discarded — predicts
#    exactly what the real mux will hit. The clinic announces the expected
#    artifact set BEFORE building and reconciles the build's mux log against
#    it after: observed != predicted is a verdict, not a shrug.
#    HISTORY (1.15.2 Defect B): through 1.15.1 the pre-pass ran `-f null -`
#    with -copyts and WITHOUT the muxdelay/muxpreload/layout opts — a
#    different mux than the one that runs. On the 2022-08-28 field source it
#    predicted 0 collision sites against 11 observed; the contract gate would
#    have FAILED a build whose artifacts were fully explained. A gate that
#    measures a different thing than it admits is worse than no gate — the
#    pre-pass now mirrors the build by construction. Callers therefore run
#    rewrap_layout FIRST (the prediction needs RW_STREAMID_OPTS/RW_MUX_OPTS).
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
  # ffp1, NEVER `| head -1`: program= emits 1 program line + N blank
  # program_stream lines, and head's early close SIGPIPEs ffprobe under the
  # callers' `set -euo pipefail` — a silent exit-141 abort with zero
  # diagnostic, measured on the 2022-08-28 field source (1.15.2 Defect A).
  pmt=$(ffp1 -v error -show_entries program=pmt_pid -of csv=p=0 "$f" 2>/dev/null | tr -d ,)
  svc=$(ffp1 -v error -show_entries program=program_num -of csv=p=0 "$f" 2>/dev/null | tr -d ,)
  case "$pmt" in ''|*[!0-9]*) pmt="";; esac
  case "$svc" in ''|*[!0-9]*) svc="";; esac
  [ -n "$pmt" ] && RW_MUX_OPTS+=(-mpegts_pmt_start_pid "$pmt")
  [ -n "$svc" ] && RW_MUX_OPTS+=(-mpegts_service_id "$svc")
  RW_LAYOUT_NOTE="stream PIDs preserved: $((${#RW_STREAMID_OPTS[@]} / 2)); PMT pid ${pmt:-default}; service id ${svc:-default}; transport_stream_id: muxer default (not ffprobe-exposed)"
}

# rewrap_predict FILE [BSF_V] [BSF_A] — TRUE dry-run pre-pass: the caller's
# own mpegts build with the bytes thrown away; prints the predicted equal-DTS
# nudge count on stdout (one number). Filters, when given, replay the caller's
# intended selection so the prediction covers the packets that will actually
# meet the muxer. Call rewrap_layout FIRST — the prediction mirrors
# RW_STREAMID_OPTS/RW_MUX_OPTS. A caller whose build carries options beyond
# the shared `-muxdelay 0 -muxpreload 0` + layout set mirrors them here via
#   RW_PREDICT_IN_OPTS[]   input-side  (e.g. -copyts)
#   RW_PREDICT_OUT_OPTS[]  output-side (e.g. -output_ts_offset N)
# — the same arrays its real build must then splice, so the two commands
# cannot drift apart. (`-f null -` + -copyts predicted a DIFFERENT mux than
# the one that runs: 1.15.2 Defect B. Cost: the pre-pass now performs real
# mpegts muxing to a discarded sink — still stream-copy, no encode; more CPU
# than the null muxer, same passes. Deliberately no skip knob: a gate that can
# be skipped silently is Defect B again.)
rewrap_predict () {
  local f="$1" fv="${2:-}" fa="${3:-}" log args=()
  [ -n "$fv" ] && args+=(-bsf:v "$fv")
  [ -n "$fa" ] && args+=(-bsf:a "$fa")
  log="$(mktemp)"
  ffmpeg -nostdin -v warning "${FF_INPUT_OPTS[@]}" \
    ${RW_PREDICT_IN_OPTS[@]+"${RW_PREDICT_IN_OPTS[@]}"} -i "$f" -map 0 -c copy \
    ${args[@]+"${args[@]}"} \
    -muxdelay 0 -muxpreload 0 \
    ${RW_PREDICT_OUT_OPTS[@]+"${RW_PREDICT_OUT_OPTS[@]}"} \
    ${RW_STREAMID_OPTS[@]+"${RW_STREAMID_OPTS[@]}"} \
    ${RW_MUX_OPTS[@]+"${RW_MUX_OPTS[@]}"} \
    -f mpegts -y /dev/null 2>"$log" || true
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

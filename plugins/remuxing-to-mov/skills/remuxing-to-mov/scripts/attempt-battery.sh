#!/usr/bin/env bash
# attempt-battery.sh — MEASURE whether the mux fails, instead of predicting it.
#
# WHY THIS EXISTS (measured 2026-08-29). Three sessions in a row refused to
# remux a 25 GB PAFF capture on the reasoning "the MOV muxer cannot write a
# packet with no PTS, so it invents one, so the confession gate refuses the
# output, so the write is a foregone waste". Every clause was plausible. The
# conclusion was false: all nine plain `-c copy` variants below return rc=0 and
# write every packet. What ffmpeg silently produces instead is a WRONG
# TIMELINE — an unstamped packet gets pts=dts, which is both the wrong display
# slot and a collision with a rung another packet holds. That is a Tier-2
# defect (verify.sh gates (d)/(j) catch it), not a reason to refuse the
# attempt (TIERS.md, Tier 3 row T3.1).
#
# So this script is the standing replacement for ever predicting a mux
# failure: run it and read the answer. It is the "cached deterministic
# attempt" evidence a Tier-3 pre-flight refusal is allowed to rest on — and
# the way to find out that no such cache exists.
#
# It writes ONLY into its own scratch directory and never touches IN.
# By default it runs on a HEAD SLICE (RTM_BATTERY_SECONDS, default 60) so the
# answer costs seconds on a 25 GB source; --whole-file runs the real thing.
#
# Usage: scripts/attempt-battery.sh INPUT [--out DIR] [--seconds N] [--whole-file] [--kv]
# Exit:  0 the battery ran (read the table — variants that fail are DATA, not
#          this script's failure) | 2 usage/env | 1 could not read INPUT at all
#
# Machine rows (one per variant, append-only):
#   AB_ROW name=… rc=N pkts=N dur=… vhash=same|differs|none confess=yes|no
#   AB_VARIANTS=n AB_RC0=n AB_LOSSLESS=n AB_SRC_PKTS=n AB_SCOPE=head:Ns|whole-file
set -uo pipefail
export LC_ALL=C
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-exit.sh"
RTM_EXIT_OK="0 1 2"
. "$SELF_DIR/lib-probe.sh"   # ffp/FF_INPUT_OPTS: one probe-window policy
. "$SELF_DIR/lib-paff.sh"    # RTM_CONFESSION_RE: one vocabulary for the muxer's confessions

IN=""; OUTDIR=""; SECS="${RTM_BATTERY_SECONDS:-60}"; WHOLE=0; KV=0
while [ $# -gt 0 ]; do case "$1" in
  --out)        OUTDIR="${2:?--out needs a directory}"; shift 2;;
  --seconds)    SECS="${2:?--seconds needs a value}"; shift 2;;
  --whole-file) WHOLE=1; shift;;
  --kv)         KV=1; shift;;
  -*) echo "unknown opt: $1" >&2; exit 2;;
  *) [ -z "$IN" ] || { echo "one INPUT only (got: $IN, $1)" >&2; exit 2; }; IN="$1"; shift;;
esac; done
[ -n "$IN" ] || { echo "usage: attempt-battery.sh INPUT [--out DIR] [--seconds N] [--whole-file] [--kv]" >&2; exit 2; }
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }
case "$SECS" in ''|*[!0-9]*) echo "--seconds must be a whole number (got: $SECS)" >&2; exit 2;; esac

OWNED=0
if [ -z "$OUTDIR" ]; then OUTDIR="$(mktemp -d)"; OWNED=1; fi
mkdir -p "$OUTDIR" || { echo "cannot create $OUTDIR" >&2; exit 2; }
# III.3 (never read where you did not write): only this run's own scratch is
# ever removed, and only when this run created it.
cleanup () { [ "$OWNED" -eq 1 ] && [ "${RTM_BATTERY_KEEP:-0}" != 1 ] && rm -rf "$OUTDIR"; }
trap cleanup EXIT

# `-t` is an ffmpeg option; ffprobe windows with -read_intervals. Passing the
# ffmpeg flag to ffprobe made the reference count read 0, which then reported
# "cannot read a video packet" for a perfectly readable file — the shape this
# whole round is about, in the tool built to prevent it.
SCOPE="head:${SECS}s"; TRIM=(-t "$SECS"); PTRIM=(-read_intervals "%+${SECS}")
[ "$WHOLE" -eq 1 ] && { SCOPE="whole-file"; TRIM=(); PTRIM=(); }

src_pkts=$(ffp -v error -select_streams v:0 ${PTRIM[@]+"${PTRIM[@]}"} \
             -show_entries packet=pts -of csv=p=0 "$IN" 2>/dev/null | grep -c . || true)
src_hash=$(ffmpeg -nostdin -v error ${FF_INPUT_OPTS[@]+"${FF_INPUT_OPTS[@]}"} -i "$IN" \
             ${TRIM[@]+"${TRIM[@]}"} -map 0:v:0 -c copy -f streamhash -hash md5 - 2>/dev/null | cut -d, -f3)
if [ "${src_pkts:-0}" -eq 0 ]; then
  echo ">> cannot read a video packet from $IN — the battery has nothing to attempt." >&2
  echo "AB_VARIANTS=0"; echo "AB_RC0=0"; echo "AB_LOSSLESS=0"; echo "AB_SRC_PKTS=0"; echo "AB_SCOPE=$SCOPE"
  exit 1
fi

[ "$KV" -eq 1 ] || {
  echo "== attempt battery: $IN =="
  echo "   scope=$SCOPE  source video packets=$src_pkts  vhash=${src_hash:-none}"
  echo "   Every row below is a MEASUREMENT of what the muxer actually does."
  echo "   A row that succeeds retires any claim that this source cannot be muxed;"
  echo "   the timeline it produces is verify.sh's question, not this script's."
  echo
  printf '   %-22s %-5s %-9s %-12s %-10s %s\n' VARIANT rc PACKETS DURATION VHASH CONFESSION
  echo "   (VHASH compares the raw packet byte stream, which re-framing changes on a"
  echo "    correct copy — it is NOT a losslessness verdict. verify.sh gates (b)/(m) are.)"
}

nvar=0; nrc0=0; nloss=0
run_variant () {
  local name="$1"; shift
  local out="$OUTDIR/$name.mov" err rc n dur hash ess confess=no
  rm -f "$out"
  err=$(ffmpeg -nostdin -hide_banner -y -loglevel warning "$@" "$out" 2>&1); rc=$?
  if [ -s "$out" ]; then
    n=$(ffp -v error -select_streams v:0 -show_entries packet=pts -of csv=p=0 "$out" 2>/dev/null | grep -c . || true)
    dur=$(ffp -v error -show_entries format=duration -of csv=p=0 "$out" 2>/dev/null)
    hash=$(ffmpeg -nostdin -v error -i "$out" -map 0:v:0 -c copy -f streamhash -hash md5 - 2>/dev/null | cut -d, -f3)
  else n=0; dur="-"; hash=""; fi
  if [ "${n:-0}" -eq 0 ]; then ess=none
  elif [ -n "$hash" ] && [ "$hash" = "$src_hash" ]; then ess=same; nloss=$((nloss+1))
  else ess=differs; fi
  # the muxer's own confession vocabulary has ONE writer (lib-paff.sh) — this
  # script reads it, never restates it
  # no early-exit reader over a pipe (the SIGPIPE class, 94 §10): grep consumes
  # all of it and its verdict is read from the status, not from a closed pipe
  printf '%s\n' "$err" | grep -iE "$RTM_CONFESSION_RE" >/dev/null 2>&1 && confess=yes
  [ "$rc" -eq 0 ] && nrc0=$((nrc0+1))
  nvar=$((nvar+1))
  [ "$KV" -eq 1 ] || {
    printf '   %-22s %-5s %-9s %-12s %-10s %s\n' "$name" "$rc" "${n:-0}" "${dur:--}" "$ess" "$confess"
    [ -n "$err" ] && printf '%s\n' "$err" | sort -u | head -3 | sed 's/^/        | /'
  }
  echo "AB_ROW name=$name rc=$rc pkts=${n:-0} dur=${dur:--} vhash=$ess confess=$confess" >> "$OUTDIR/rows.kv"
}

: > "$OUTDIR/rows.kv"
I=(${FF_INPUT_OPTS[@]+"${FF_INPUT_OPTS[@]}"} -i "$IN")
T=(${TRIM[@]+"${TRIM[@]}"})
# `0:a?` and not `0:a`: an audio-less source made every variant exit 234 and the
# battery reported "0 of 9 muxed" — a false CACHED DETERMINISTIC ATTEMPT, which
# is precisely the evidence a Tier-3 refusal is allowed to rest on. A measuring
# tool that manufactures the answer it is asked for is worse than none.
run_variant plain            "${I[@]}" "${T[@]}" -map 0:v:0 -map 0:a? -c copy
run_variant genpts           -fflags +genpts "${I[@]}" "${T[@]}" -map 0:v:0 -map 0:a? -c copy
run_variant igndts           -fflags +igndts "${I[@]}" "${T[@]}" -map 0:v:0 -map 0:a? -c copy
run_variant genpts_igndts    -fflags +genpts+igndts "${I[@]}" "${T[@]}" -map 0:v:0 -map 0:a? -c copy
run_variant avoid_neg        "${I[@]}" "${T[@]}" -map 0:v:0 -map 0:a? -c copy -avoid_negative_ts make_zero
run_variant copyts           -copyts "${I[@]}" "${T[@]}" -map 0:v:0 -map 0:a? -c copy
run_variant maxinter0        "${I[@]}" "${T[@]}" -map 0:v:0 -map 0:a? -c copy -max_interleave_delta 0
run_variant passthrough      "${I[@]}" "${T[@]}" -map 0:v:0 -map 0:a? -c copy -fps_mode passthrough
run_variant genpts_avoidneg  -fflags +genpts "${I[@]}" "${T[@]}" -map 0:v:0 -map 0:a? -c copy -avoid_negative_ts make_zero

cat "$OUTDIR/rows.kv"
echo "AB_VARIANTS=$nvar"
echo "AB_RC0=$nrc0"
echo "AB_LOSSLESS=$nloss"
echo "AB_SRC_PKTS=$src_pkts"
echo "AB_SCOPE=$SCOPE"
[ "$KV" -eq 1 ] || {
  echo
  if [ "$nrc0" -gt 0 ]; then
    echo ">> $nrc0 of $nvar variants MUXED this source (scope $SCOPE). 'The mux fails' is"
    echo "   not true of this file. Whether the resulting TIMELINE is correct is a"
    echo "   separate question with its own answer: scripts/verify.sh SRC OUT."
  else
    echo ">> 0 of $nvar variants muxed this source (scope $SCOPE) — a CACHED DETERMINISTIC"
    echo "   ATTEMPT (TIERS.md Tier 3): a pre-flight refusal may cite this measurement,"
    echo "   and must re-verify it when ffmpeg changes ($(ffmpeg -version 2>/dev/null | head -1))."
  fi
  [ "$OWNED" -eq 1 ] && [ "${RTM_BATTERY_KEEP:-0}" != 1 ] \
    && echo "   (artifacts discarded; RTM_BATTERY_KEEP=1 or --out DIR keeps them)"
}
exit 0

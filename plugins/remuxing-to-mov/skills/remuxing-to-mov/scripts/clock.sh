#!/usr/bin/env bash
# clock.sh — the player-clock translator. Users report PLAYER-clock time;
# ffprobe reports CONTAINER time; the two differ by format.start_time, and
# every "video starts at X" / "the glitch is at X" diagnosis must convert
# between them before concluding anything (the feed.ts lesson, 2026-08-26:
# one conversion turned a vague complaint into an exact packet address —
# player 1.360 = container 1.560 on a start_time 0.200 capture).
#
#   container_time = player_time + format.start_time
#
# Given a player-clock report, this prints the raw container address, the
# keyframes bracketing it (demux-only windowed scan), and per-frame mean luma
# around it (bounded decode, signalstats) — enough to see at a glance whether
# the reported moment is a keyframe boundary, a black lead, or mid-GOP.
# A convenient identity: `-ss` BEFORE `-i` is itself relative to start_time
# (the WO 1.3 measured origin), so the decode window seeks by the PLAYER time
# directly — the same conversion, exercised.
#
# Usage: scripts/clock.sh INPUT PLAYER_TIME
# Report-only: reads the file, writes nothing, never decides. Interpretation
# (black-lead? cut here?) belongs to lead-check.sh / the operator.
# Exit: 0 report printed | 2 usage/unreadable.
# Machine line (stable API — extend only):
#   CLOCK_SUMMARY player= start_time= raw= key_before= key_after= frames=
#     luma_min= luma_max=
# Tunables: RTM_CLOCK_WINDOW (half-width of the scan/decode window, secs,
# default 3; the keyframe scan widens once x4, announced, if none is found).
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-exit.sh"   # exit-code contract trap: no stray code escapes
IN="${1:?usage: clock.sh INPUT PLAYER_TIME}"
PT="${2:?need PLAYER_TIME (seconds, as the player displays it)}"
[ $# -le 2 ] || { echo "unknown opt: $3" >&2; exit 2; }   # F6 (WO-1.15.9): never shrug at strays
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }
case "$PT" in ''|*[!0-9.]*) echo "PLAYER_TIME must be numeric seconds: $PT" >&2; exit 2;; esac
. "$SELF_DIR/lib-probe.sh"  # ffp/FF_INPUT_OPTS: raised probe window on every input open

W="${RTM_CLOCK_WINDOW:-3}"

ST=$(ffp1 -v error -show_entries format=start_time -of default=nw=1:nk=1 "$IN" 2>/dev/null)
case "$ST" in ''|N/A) ST=0; echo "   note: container reports no start_time — treating it as 0";; esac
RAW=$(awk "BEGIN{printf \"%.6f\", ($PT)+($ST)}")

echo "== clock: $IN =="
echo "   player-clock ${PT}s + format.start_time ${ST}s = CONTAINER time ${RAW}s"
echo "   (ffprobe/packet addresses use container time; players rebase start_time away)"

# --- bracketing keyframes (demux-only, windowed; widen once if dry) ---------------
scan_keys () { # scan_keys HALF_WIDTH -> "kb=<t|na> ka=<t|na>"
  local w="$1" lo hi
  lo=$(awk "BEGIN{v=($RAW)-($w); if(v<0)v=0; printf \"%.3f\", v}")
  hi=$(awk "BEGIN{printf \"%.3f\", ($RAW)+($w)}")
  { ffp -v error -select_streams v:0 -read_intervals "${lo}%${hi}" \
      -show_entries packet=pts_time,flags -of csv=p=0 "$IN" 2>/dev/null || true; } | \
  awk -F, -v raw="$RAW" '
    NF && index($2,"K") && $1!="N/A" {
      t=$1+0
      if(t<=raw){ if(!hb || t>kb){kb=t; hb=1} } else { if(!ha || t<ka){ka=t; ha=1} }
    }
    END{ printf "kb=%s ka=%s\n", (hb?kb:"na"), (ha?ka:"na") }'
}
eval "$(scan_keys "$W")"
if [ "$kb" = na ] && [ "$ka" = na ]; then
  echo "   no keyframe within +/-${W}s — widening the scan once to +/-$((W*4))s"
  eval "$(scan_keys $((W*4)))"
fi
echo "   keyframes: last at/before ${RAW}s -> ${kb}s | first after -> ${ka}s"
[ "$kb" = na ] && echo "   (none found at/before the address in the widened window — a long GOP or the file head)"

# --- per-frame luma around the address (bounded decode) ---------------------------
# -ss before -i is relative to start_time, i.e. it TAKES the player time; -copyts
# keeps raw container timestamps on the decoded frames so the report addresses
# match ffprobe.
SS=$(awk "BEGIN{v=($PT)-1; if(v<0)v=0; printf \"%.3f\", v}")
SPAN=$(awk "BEGIN{printf \"%.3f\", ($PT)-($SS)+($W)}")
# computed OUTSIDE the echo: a $(awk "...{...}") nested inside a double-quoted
# string re-parses its quoting and brace-expands the program (measured here —
# the awk text split on the comma inside {})
WEND=$(awk "BEGIN{printf \"%.3f\", ($SS)+($SPAN)}")
echo "-- frames around the address (decode window player ${SS}s..${WEND}s) --"
# No -copyts here: with -ss before -i it made -t stop against ABSOLUTE output
# timestamps (measured: a 10s-offset fixture decoded 3 frames of a 4s window).
# Decoded frames restart near 0 at the seek point instead, and the container
# address is reconstructed as pts + start_time + seek — the same conversion
# this tool exists to make explicit.
BASE=$(awk "BEGIN{printf \"%.6f\", ($ST)+($SS)}")
FRAMES=$(ffmpeg -nostdin -v error "${FF_INPUT_OPTS[@]}" -ss "$SS" -i "$IN" \
    -map 0:v:0 -t "$SPAN" -vf signalstats,metadata=print:file=- -f null - 2>/dev/null | \
  awk -F'[:= ]+' -v base="$BASE" '/pts_time/{t=$NF} /YAVG/{printf "%.6f %.1f\n", t+base, $NF}' || true)
NFR=$(printf '%s' "$FRAMES" | grep -c . || true)
if [ "${NFR:-0}" -eq 0 ]; then
  echo "   <no frames decoded in the window — pre-IDR region, damage, or past EOF>"
  LMIN=na; LMAX=na
else
  printf '%s\n' "$FRAMES" | awk -v raw="$RAW" '{
      mark=""; d=$1-raw; if(d<0)d=-d
      if(d<0.021) mark="   <-- the reported moment"
      printf "   pts %-12s luma-mean %6.1f%s\n", $1, $2, mark }'
  LMIN=$(printf '%s\n' "$FRAMES" | awk 'NR==1||$2<m{m=$2} END{printf "%.1f", m}')
  LMAX=$(printf '%s\n' "$FRAMES" | awk '$2>m{m=$2} END{printf "%.1f", m}')
  echo "   luma range in window: $LMIN .. $LMAX (black lead-ins sit low — ~16-48; program picture high)"
fi

echo "CLOCK_SUMMARY player=$PT start_time=$ST raw=$RAW key_before=$kb key_after=$ka frames=${NFR:-0} luma_min=$LMIN luma_max=$LMAX"

#!/usr/bin/env bash
# rebuild-paff.sh — Rung 3: rebuild a broken timeline from the elementary stream.
# For field-coded (PAFF) H.264 whose container timing is too broken for genpts.
# Video stays BIT-IDENTICAL; only the access-unit structure + timestamps are re-derived.
#
# SCOPE LIMIT (post-mortem 2026-07-25): re-stamping at a constant rate sets
# PTS = DTS, i.e. presentation order = DECODE order. On a stream that carries a
# reorder pyramid (B-fields / B-frames: PTS-DTS offsets vary, backward PTS steps)
# that plays the pictures shuffled — a different way of being broken, and one the
# default verify tier CANNOT see (bits identical, decode clean, scrub clean).
# So this script now REFUSES a source whose surviving timestamps show reordering:
#   * real PTS survives (e.g. on the first field of each pair) -> use
#     scripts/pairfill-paff.sh, which keeps it;
#   * no timestamps survive at all -> reordering is undetectable and this rebuild
#     is the least-bad option; it proceeds with a warning — eyeball motion after.
# Override with --force only when you have proven decode order == display order.
#
# Usage: scripts/rebuild-paff.sh INPUT OUTPUT.mov FIELD_RATE [TIMESCALE] [--force]
#   FIELD_RATE examples (each field-picture is one AU at the field rate):
#     1080i59.94 -> 60000/1001     1080i50 -> 50
#     720p59.94  -> 60000/1001     29.97p  -> 30000/1001   23.976p -> 24000/1001
#   TIMESCALE defaults to a clean whole value derived from common rates.
#
# Safety: set -e gates every step; intermediates go in a temp dir and are kept on
# failure for inspection; output is written atomically. The SOURCE is never touched.
# Exit: 0 ok; 2 usage; 3 refused (reordered stream — wrong repair for this class);
#       11 refused by the backhaul gate (QT-undecodable profile — no .mov route).
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-exit.sh"   # exit-code contract trap (WO 1.4): no stray code escapes
RTM_EXIT_OK="0 1 2 3 10 11" # + this script's documented pre-contract 3 (reorder REFUSED; suite-pinned)
IN="${1:?usage: rebuild-paff.sh INPUT OUTPUT.mov FIELD_RATE [TIMESCALE] [--force]}"
OUT="${2:?need OUTPUT.mov}"; RATE="${3:?need FIELD_RATE e.g. 60000/1001}"; shift 3
TS=""; FORCE=0
while [ $# -gt 0 ]; do case "$1" in
  --force) FORCE=1; shift;;
  *) [ -n "$TS" ] && { echo "unknown opt: $1" >&2; exit 2; }; TS="$1"; shift;;
esac; done
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }
[ "$(cd "$(dirname "$IN")" && pwd)/$(basename "$IN")" != "$(cd "$(dirname "$OUT")" 2>/dev/null && pwd)/$(basename "$OUT")" ] \
  || { echo "refusing to overwrite the source in place" >&2; exit 2; }
. "$SELF_DIR/lib-probe.sh"  # ffp/FF_INPUT_OPTS: raised probe window on every input open
. "$SELF_DIR/lib-paff.sh"
. "$SELF_DIR/lib-mux.sh"    # rtm_part (extension-keeping atomics), mux_census (D5)

# backhaul gate (1.11: advises + warns, refuses nothing — the 4:2:2 advisory
# defers to the post-build proof, rot WARNs and builds) — this script writes a
# .mov, so the advisory fires even on a direct call; a gated caller
# (mov.sh/auto.sh) exports RTM_BACKHAUL_GATED=1 and skips it.
backhaul_gate "$IN" || exit $?

# --- pre-flight: does the source carry presentation reordering this restamp would flatten? ---
eval "$(pf_reorder_scan "$IN")"
if [ "$PF_REORDER" = yes ] && [ "$FORCE" -ne 1 ]; then
  eval "$(pf_detect "$IN")"
  echo ">> REFUSING: the source's surviving timestamps show a reorder pyramid" >&2
  DTSQ=""; [ "${PF_DTS_SOURCE:-carried}" = reconstructed ] && DTSQ=" (demuxer-reconstructed — not a source property)"
  echo "   (pts!=dts on $PF_PTSNEDTS pkt(s), $PF_BACKPTS backward PTS step(s), max offset $PF_MAXOFF_TICKS ticks${DTSQ})." >&2
  echo "   A constant-rate restamp sets PTS=DTS and would play pictures in DECODE" >&2
  echo "   order — motion shuffled, and invisible to the default verify tier." >&2
  if [ "${PF_HALF_TS:-no}" = yes ]; then
    echo "   This stream is the half-timestamped pair class. The correct repair keeps" >&2
    echo "   every real PTS and fills the pair-mates:" >&2
    echo "     scripts/pairfill-paff.sh \"$IN\" \"$OUT\"" >&2
  else
    echo "   Real PTS survives — keep it. A PTS-complete reordered stream is the" >&2
    echo "   Rung 3-DERIVE class: scripts/derive-dts.sh \"$IN\" \"$OUT\" derives the DTS" >&2
    echo "   column from the sorted PTS (codec-agnostic, video bits untouched) — that," >&2
    echo "   or a scrub-gated plain copy, never this flattening restamp. --force" >&2
    echo "   overrides ONLY if you have proven decode order == display order." >&2
  fi
  exit 3
fi
if [ "$PF_REORDER" = yes ]; then
  echo "** --force: restamping a REORDERED stream at a constant rate — presentation"
  echo "** order will equal decode order. Prove motion is correct before shipping."
elif [ "${PF_TS_BOTH:-0}" -eq 0 ]; then
  echo "** no packet carries both PTS and DTS — reordering is undetectable from the"
  echo "** container. Proceeding (least-bad option); check motion by eye afterwards."
fi

# default timescale from the rate if not given
if [ -z "$TS" ]; then case "$RATE" in
  60000/1001|60) TS=60000;; 50) TS=50000;; 30000/1001|30) TS=30000;;
  24000/1001|24) TS=24000;; 25) TS=25000;; *) TS=60000;; esac
fi

WORK="$(mktemp -d)"   # NOT auto-deleted, so a failed run leaves intermediates to inspect
echo "work dir (inspect on failure): $WORK"

# 1) video -> raw Annex-B H.264. TS/PS already Annex-B; AVCC (MKV/MOV) needs the bsf.
isavc=$(ffp -v error -select_streams v:0 -show_entries stream=is_avc -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1 || true)
BSF=""; [ "$isavc" = true ] && BSF="-bsf:v h264_mp4toannexb"
# shellcheck disable=SC2086
ffmpeg -nostdin -y "${FF_INPUT_OPTS[@]}" -i "$IN" -map 0:v:0 -c:v copy $BSF -f h264 "$WORK/v.h264"

# 2) audio -> PCM/WAV per track (starts at sample 0, stays aligned; a single-track
#    rebuild would silently drop SAP/secondary audio)
# sort -u: TS program duplication can list the same stream twice (see ingest-compatibility.md)
# EMPTY ≠ ABSENT (CHECKUP-2026-08-27 A1 / WO-1.15.4): the census probe is
# captured WITH its exit status — the old `| grep -c . || true` read a FAILED
# probe as NA=0 and rebuilt video-only under "note: no audio streams found".
# A probe failure refuses pre-flight (exit 2, nothing written); only a
# successful empty probe means a genuinely audio-free source. Counting rides
# awk (NF), not grep -c, whose rc-1-on-zero-matches is what bred the || true.
set +e
NA_RAW=$(ffp -v error -select_streams a -show_entries stream=index -of csv=p=0 "$IN" 2>/dev/null); na_rc=$?
set -e
if [ "$na_rc" -ne 0 ]; then
  echo ">> REFUSED (pre-flight): the audio census probe FAILED (ffprobe rc=$na_rc) —" >&2
  echo "   cannot distinguish 'no audio' from 'probe broke'; a video-only rebuild on a" >&2
  echo "   guessed census is the silent track-drop class. No OUTPUT written (extracted" >&2
  echo "   intermediates remain in $WORK)." >&2
  exit 2
fi
NA=$(printf '%s\n' "$NA_RAW" | sort -u | awk 'NF{n++} END{print n+0}')
AIN=(); AMAP=(); AMETA=()
i=0
while [ "$i" -lt "$NA" ]; do
  ffmpeg -nostdin -y "${FF_INPUT_OPTS[@]}" -i "$IN" -map "0:a:$i" -c:a pcm_s16le "$WORK/a$i.wav"
  AIN+=(-i "$WORK/a$i.wav"); AMAP+=(-map "$((i+1)):0")
  # PRESERVE the real per-track language; default to eng only if the source has
  # none (PS/.mpg carry none). Hard-coding eng would silently relabel FR/ES/commentary.
  lang=$(ffp -v error -select_streams "a:$i" -show_entries stream_tags=language -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
  case "$lang" in ""|und|unknown) lang=eng;; esac
  AMETA+=("-metadata:s:a:$i" "language=$lang")
  i=$((i+1))
done
[ "$NA" -gt 0 ] || echo "note: no audio streams found; rebuilding video only"

# 3) rebuild from zero at the field rate
cp=$(ffp -v error -select_streams v:0 -show_entries stream=color_primaries -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1 || true)
MOVFLAGS="+faststart"; { [ -n "$cp" ] && [ "$cp" != unknown ]; } && MOVFLAGS="+faststart+write_colr"
PART="$(rtm_part "$OUT")"; MUXLOG="$WORK/mux.log"   # extension-keeping (D6)
# ${arr[@]+...} expansions keep bash 3.2 (macOS default) happy under set -u with empty arrays
if ! ffmpeg -nostdin -y -hide_banner -nostats -fflags +genpts -r "$RATE" "${FF_INPUT_OPTS[@]}" -i "$WORK/v.h264" ${AIN[@]+"${AIN[@]}"} \
    -map 0:0 ${AMAP[@]+"${AMAP[@]}"} -c:v copy -c:a pcm_s16le \
    ${AMETA[@]+"${AMETA[@]}"} \
    -video_track_timescale "$TS" \
    -movflags "$MOVFLAGS" -f mov \
    "$PART" 2>"$MUXLOG"; then
  echo ">> mux FAILED:"; sed 's/^/   /' "$MUXLOG" | tail -8
  exit 1
fi
[ -s "$MUXLOG" ] && sed 's/^/   mux: /' "$MUXLOG" | tail -6
# NOTE on mux warnings: "Timestamps are unset" is EXPECTED here — this rung
# deliberately discards the container timestamps and re-derives timing from the
# imposed constant rate (raw-elementary packets carry durations only). The
# confession hard-stop applies to COPY muxes (remux.sh/dual-track.sh), where
# preserving source timing is the contract. For a deliberate restamp the proof
# is the OUTPUT timeline itself — gate it before blessing (post-mortem 2026-07-25):
EXPDUR=$(awk "BEGIN{n=split(\"$RATE\",r,\"/\"); rd=(n>1)?r[2]:1; printf \"%d\", $TS*rd/r[1]}")
eval "$(ffp -v error -select_streams v:0 -show_entries packet=pts,dts,duration -of csv=p=0 "$PART" 2>/dev/null | \
  awk -F, -v e="$EXPDUR" 'NF{
      n++
      if($1=="N/A"||$1=="") nap++
      if($2=="N/A"||$2==""){ nad++ } else { d=$2+0; if(hav){ if(d<pd) back++; else if(d==pd) dup++ } pd=d; hav=1 }
      if($3!="N/A" && $3!="" && $3+0!=e) od++
    }
    END{ printf "RG_N=%d RG_NAPTS=%d RG_NADTS=%d RG_BACK=%d RG_DUP=%d RG_OFFDUR=%d\n", n+0, nap+0, nad+0, back+0, dup+0, od+0 }')"
echo "   output timeline: packets=$RG_N N/A=$RG_NAPTS/$RG_NADTS backward=$RG_BACK dup=$RG_DUP off-cadence-durations=$RG_OFFDUR (want 0/0/0/0/<=1 @ ${EXPDUR} ticks)"
if [ "${RG_NAPTS:-1}" -ne 0 ] || [ "${RG_NADTS:-1}" -ne 0 ] || [ "${RG_BACK:-1}" -ne 0 ] || [ "${RG_DUP:-1}" -ne 0 ] || [ "${RG_OFFDUR:-9}" -gt 1 ]; then
  echo ">> HARD STOP: the rebuilt timeline is not the clean constant-rate ramp this"
  echo "   rung promises. NOT blessing the output; kept at $PART (log: $MUXLOG)."
  exit 1
fi
# POST-MUX CENSUS (D5, 1.13): this rung re-muxes from N+1 separate inputs (the
# elementary video plus one WAV per audio track) — exactly the shape where a
# quietly unmapped input goes unnoticed. Video codec comes from the elementary
# stream; every audio track is pcm_s16le by construction.
RB_C="$(ffp -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)"   # the SOURCE codec, not the artifact reading itself
i=0; while [ "$i" -lt "$NA" ]; do RB_C="$RB_C,pcm_s16le"; i=$((i+1)); done
census_rc=0
mux_census "$PART" "$((1 + NA))" "$RB_C" rebuild-paff "$IN" || census_rc=$?
if [ "$census_rc" -ne 0 ] && [ "$census_rc" -ne 10 ]; then
  echo "   NOT blessing the output; kept at $PART (log: $MUXLOG; intermediates in $WORK)."
  exit 1
fi
mv -f "$PART" "$OUT"

echo "wrote: $OUT"
echo "verify with: scripts/verify.sh \"$IN\" \"$OUT\""
echo "if verify passes, remove intermediates by hand: rm -rf \"$WORK\""
# REVIEW propagation (1.14): an unexpected-surplus census blesses the complete
# artifact and exits 10 ("look"), never 1 — nothing planned is missing.
exit "$census_rc"

#!/usr/bin/env bash
# lead-check.sh — detect the BLACK LEAD-IN signature at the head of a capture
# and name the exact deterministic cut address. The recurring broadcast shape
# (feed.ts case file, 2026-08-26): the capture opens on a black GOP (often the
# file's only true IDR — where the encoder chain started), the feed splices to
# program picture at the next keyframe (an open-GOP I), and the audio is
# already hot under the black — so players show black at 0:00 and the user
# reports "video starts at X". ts-health cannot see this class (it never
# decodes); this probe pays for one bounded head decode to close that gap.
#
# What it measures (head window = RTM_LEAD_WINDOW seconds, default 8):
#   * per-frame mean luma (signalstats) — black run vs program brightness
#     (threshold RTM_LEAD_LUMA_BLACK, default 48; the measured case ran
#     16-42 black against ~150 program);
#   * the video packet map (demux) — the keyframe at the luma jump, addressed
#     by PACKET INDEX + PTS (the surgical-cut currency; never a seek);
#   * the splice boundary class via gop-probe.sh (closed IDR vs open-GOP I —
#     an open boundary has leading B's that must go with the cut);
#   * candidate leading-B packets: coded-order packets AFTER the splice
#     keyframe whose PTS precedes it (decoder-discarded, but if kept they
#     poison format.start_time — the case-file leading-B rule);
#   * audio level across the splice (astats) — hot audio means a cut DISCARDS
#     real program audio, and this probe says exactly how much.
#
# REPORT-ONLY: writes nothing, decides nothing. A found lead names the
# scripts/surgical-cut.sh route with its measured arguments and states the
# Tier-2 rule: that cut discards decodable media and runs only with
# --discard-content from the operator.
#
# Usage: scripts/lead-check.sh INPUT
# Exit: 0 CLEAN (no lead) | 10 LEAD FOUND | 1 cannot measure | 2 usage.
# Machine line (stable API — extend only):
#   LEADCHECK_SUMMARY verdict=clean|lead black_frames= black_secs=
#     splice_idx= splice_pts_t= gop=closed|open|unknown leadb=none|A-B
#     audio_hot=yes|no|na audio_discard_s=
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-exit.sh"   # exit-code contract trap: no stray code escapes
IN="${1:?usage: lead-check.sh INPUT}"
[ $# -le 1 ] || { echo "unknown opt: $2" >&2; exit 2; }
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }
. "$SELF_DIR/lib-probe.sh"  # ffp/FF_INPUT_OPTS: raised probe window on every input open
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT   # only our own scratch; never the source

W="${RTM_LEAD_WINDOW:-8}"
BLACK="${RTM_LEAD_LUMA_BLACK:-48}"

echo "== lead-check: $IN (head ${W}s, black-luma ceiling $BLACK) =="

ST=$(ffp -v error -show_entries format=start_time -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
case "$ST" in ''|N/A) ST=0;; esac
TB=$(ffp -v error -select_streams v:0 -show_entries stream=time_base -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
TICK=${TB##*/}; case "$TICK" in ''|*[!0-9]*) TICK=90000;; esac

# --- head packet map (demux only): index,pts_time,flags up to the window ----------
LIMIT=$(awk "BEGIN{printf \"%.3f\", ($ST)+($W)}")
ffp -v error -select_streams v:0 -read_intervals "%${LIMIT}" \
    -show_entries packet=pts_time,flags -of csv=p=0 "$IN" 2>/dev/null | \
  awk -F, '{ printf "%d %s %s\n", NR-1, ($1==""?"N/A":$1), $2 }' > "$TMP/vmap"
NPKT=$(grep -c . "$TMP/vmap" || true)
NNA=$(awk '$2=="N/A"{n++} END{print n+0}' "$TMP/vmap")
[ "${NPKT:-0}" -gt 0 ] || { echo "no video packets in the head window" >&2; exit 1; }
[ "$NNA" -gt 0 ] && echo "   note: $NNA untimestamped packet(s) in the window (PAFF pair mates ride their partner — operator review of any packet-index range is required)"

# --- luma sweep (bounded decode of the head window) -------------------------------
# decoded frame timestamps come out rebased to ~0 — and MEASURED here, the CLI
# rebases the video by the VIDEO stream's own start, not format.start_time (an
# audio-led start_time left an 11 ms skew that picked the wrong splice
# keyframe). So the luma series is aligned to the packet map by their first
# entries: base = first mapped video PTS - first decoded PTS. No seek happens,
# so the first decoded frame IS the map's first presentation frame.
ffmpeg -nostdin -v error "${FF_INPUT_OPTS[@]}" -i "$IN" -map 0:v:0 -t "$W" \
    -vf signalstats,metadata=print:file=- -f null - 2>/dev/null | \
  awk -F'[:= ]+' '/pts_time/{t=$NF} /YAVG/{printf "%.6f %.1f\n", t, $NF}' > "$TMP/luma.raw"
VFIRST=$(awk '$2!="N/A"{ if(!h || ($2+0)<m){m=$2+0; h=1} } END{ if(h) printf "%.6f", m }' "$TMP/vmap")
LFIRST=$(awk 'NR==1{ printf "%.6f", $1+0; exit }' "$TMP/luma.raw")
VBASE=$(awk "BEGIN{printf \"%.6f\", (${VFIRST:-0})-(${LFIRST:-0})}")
awk -v b="$VBASE" '{ printf "%.6f %.1f\n", $1+b, $2 }' "$TMP/luma.raw" > "$TMP/luma"
NFR=$(grep -c . "$TMP/luma" || true)
[ "${NFR:-0}" -gt 0 ] || { echo "head decode produced no frames — cannot measure luma" >&2; exit 1; }
# black run from frame 0 (presentation order — signalstats sees display order)
eval "$(sort -n "$TMP/luma" | awk -v black="$BLACK" '
  NR==1 { if($2<=black){run=1; nb=1; last=$1} else run=0; first=$1; next }
  run && $2<=black { nb++; last=$1; next }
  run && $2> black { run=0; bright=$1; bl=$2 }
  END{ printf "nb=%d black_end=%s bright_at=%s bright_luma=%s first_pts=%s\n", nb+0, (nb?last:"na"), (bright?bright:"na"), (bl?bl:"na"), first }')"
LMIN=$(awk 'NR==1||$2<m{m=$2} END{printf "%.1f", m}' "$TMP/luma")
LMAX=$(awk '$2>m{m=$2} END{printf "%.1f", m}' "$TMP/luma")
echo "   frames decoded: $NFR; luma range $LMIN..$LMAX; leading black frames: ${nb:-0}"

if [ "${nb:-0}" -eq 0 ]; then
  echo ">> CLEAN: the first frame is not black (luma > $BLACK) — no lead-in to cut."
  echo "LEADCHECK_SUMMARY verdict=clean black_frames=0 black_secs=0 splice_idx=na splice_pts_t=na gop=na leadb=none audio_hot=na audio_discard_s=0"
  exit 0
fi
if [ "$bright_at" = na ]; then
  echo ">> the ENTIRE head window is black (luma <= $BLACK for all $NFR frames)."
  echo "   Widen RTM_LEAD_WINDOW, or this is dead air, not a lead — nothing to cut to."
  echo "LEADCHECK_SUMMARY verdict=lead black_frames=$nb black_secs=na splice_idx=na splice_pts_t=na gop=unknown leadb=none audio_hot=na audio_discard_s=na"
  exit 10
fi
BLACK_SECS=$(awk "BEGIN{printf \"%.3f\", ($bright_at)-($first_pts)}")
echo "   black lead: ${nb} frame(s), ${first_pts}s..${black_end}s; program picture at ${bright_at}s (luma ${bright_luma})"

# --- the splice keyframe, addressed by packet index + PTS -------------------------
# the keyframe AT or nearest BELOW the first bright frame's pts
eval "$(awk -v b="$bright_at" '
  index($3,"K") && $2!="N/A" && ($2+0)<=(b+0.001) { ki=$1; kp=$2 }
  END{ printf "splice_idx=%s splice_pts=%s\n", (kp!=""?ki:"na"), (kp!=""?kp:"na") }' "$TMP/vmap")"
if [ "$splice_idx" = na ]; then
  echo ">> LEAD FOUND but no keyframe at/under the luma jump in the packet map —"
  echo "   the program picture may enter mid-GOP. Manual review (clock.sh around ${bright_at}s)."
  echo "LEADCHECK_SUMMARY verdict=lead black_frames=$nb black_secs=$BLACK_SECS splice_idx=na splice_pts_t=na gop=unknown leadb=none audio_hot=na audio_discard_s=na"
  exit 10
fi
SPLICE_TICKS=$(awk "BEGIN{printf \"%.0f\", ($splice_pts)*$TICK}")
echo "   splice keyframe: video packet index $splice_idx, pts ${splice_pts}s ($SPLICE_TICKS ticks)"

# --- boundary class (gop-probe.sh — the existing, tested classifier) --------------
GOP=unknown
set +e; gpo=$(bash "$SELF_DIR/gop-probe.sh" "$IN" "$splice_pts" 2>&1); gprc=$?; set -e
case "$gprc" in
  0)  GOP=closed; echo "   boundary: CLOSED (full sync) — a cut here is self-contained";;
  10) GOP=open;   echo "   boundary: OPEN GOP (partial sync) — leading B's reference the black GOP";;
  *)  echo "   boundary: gop-probe could not classify (rc=$gprc)";;
esac

# --- candidate leading-B packets (coded order after the keyframe, PTS before it) --
LEADB=none
eval "$(awk -v ki="$splice_idx" -v kp="$splice_pts" '
  ($1+0)>ki && $2!="N/A" && ($2+0)<(kp+0) { if(a==""){a=$1} b=$1; n++ }
  ($1+0)>ki && $2!="N/A" && ($2+0)>=(kp+0) && a!="" { exit }
  END{ printf "lb_from=%s lb_to=%s lb_n=%d\n", (a==""?"na":a), (a==""?"na":b), n+0 }' "$TMP/vmap")"
if [ "$lb_from" != na ]; then
  LEADB="${lb_from}-${lb_to}"
  echo "   leading-B candidates: packets $LEADB ($lb_n timestamped; PAFF mates in range ride along)"
  echo "   (decoder-discarded if kept, but their PTS precede the splice and poison"
  echo "   format.start_time — the case-file rule is: drop them with the lead)"
fi

# --- audio across the splice ------------------------------------------------------
AHOT=na; ADISC=na
FIRST_APTS=$(ffp -v error -select_streams a:0 -read_intervals '%+#1' \
               -show_entries packet=pts_time -of csv=p=0 "$IN" 2>/dev/null | head -1 | tr -d ,)
if [ -n "$FIRST_APTS" ] && [ "$FIRST_APTS" != N/A ]; then
  ADISC=$(awk "BEGIN{v=($splice_pts)-($FIRST_APTS); if(v<0)v=0; printf \"%.3f\", v}")
  SSREL=$(awk "BEGIN{v=($splice_pts)-($ST)-1; if(v<0)v=0; printf \"%.3f\", v}")
  # -v info, not error: astats logs its summary at AV_LOG_INFO — at -v error the
  # measurement never prints and the probe would silently read "no audio".
  # D2 sibling (CHECKUP-2026-08-27 / WO-1.15.4): the decode is CAPTURED with
  # its rc — in statement position a mid-decode failure was a silent ERR exit
  # 1 (this script's "cannot measure" code, with no message). A failed probe
  # announces itself and keeps audio_hot=na (unmeasured, not "quiet"); the
  # first-line pick rides awk, whose read-to-EOF cannot SIGPIPE the producer.
  set +e
  ARMS_RAW=$(ffmpeg -nostdin -v info -hide_banner -nostats "${FF_INPUT_OPTS[@]}" -ss "$SSREL" -i "$IN" -map 0:a:0 -t 2 \
      -af astats=measure_overall=RMS_level:measure_perchannel=none -f null - 2>&1); arms_rc=$?
  set -e
  if [ "$arms_rc" -ne 0 ]; then
    echo "   audio probe FAILED mid-decode (ffmpeg rc=$arms_rc) — audio_hot UNMEASURED (na),"
    echo "   not 'quiet'; the cut command below omits the audio-drop argument on purpose."
    AHOT=na
  else
    ARMS=$(printf '%s\n' "$ARMS_RAW" | sed -n 's/.*RMS level dB: *//p' | awk 'NF && !g { print; g=1 }')
    case "$ARMS" in
      ''|-inf) AHOT=no;;
      *) awk "BEGIN{exit !(($ARMS) > -45)}" && AHOT=yes || AHOT=no;;
    esac
    echo "   audio across the splice: RMS ${ARMS:--inf} dB -> hot=$AHOT; a cut to picture-start discards ${ADISC}s of audio"
  fi
else
  echo "   no audio stream (or no audio timestamps) — video-only cut"
  ADISC=0
fi

# --- the route --------------------------------------------------------------------
echo ">> LEAD FOUND. The deterministic cut (packet-index/PTS selection, no seeking):"
CUTCMD="scripts/surgical-cut.sh \"$IN\" OUT.ts --video-drop-lt $splice_idx"
[ "$LEADB" != none ] && CUTCMD="$CUTCMD --video-drop-between $lb_from $lb_to"
[ "$ADISC" != na ] && [ "$ADISC" != 0 ] && CUTCMD="$CUTCMD --audio-drop-lt-pts $SPLICE_TICKS"
CUTCMD="$CUTCMD --discard-content"
echo "     $CUTCMD"
echo "   TIER 2 — this cut DISCARDS DECODABLE MEDIA (${BLACK_SECS}s of black video"
[ "$AHOT" = yes ] && echo "   and ${ADISC}s of REAL, HOT program audio under it)." || echo "   and ${ADISC}s of audio under it)."
echo "   surgical-cut.sh refuses without --discard-content: that trade is the"
echo "   operator's, never this tool's. The untouched original retains everything."
[ "$GOP" = unknown ] && echo "   NOTE: boundary class unknown — prove it before cutting (gop-probe.sh)."
echo "LEADCHECK_SUMMARY verdict=lead black_frames=$nb black_secs=$BLACK_SECS splice_idx=$splice_idx splice_pts_t=$SPLICE_TICKS gop=$GOP leadb=$LEADB audio_hot=$AHOT audio_discard_s=$ADISC"
exit 10

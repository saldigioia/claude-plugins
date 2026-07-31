#!/usr/bin/env bash
# diagnose.sh — run the glitch-diagnosis ladder in order and print a verdict.
# Usage: scripts/diagnose.sh INPUT
# Ladder: (1) decode-to-null integrity + non-monotonic-DTS scan
#         (2) MKV strict-mux test (catches MISSING timestamps)
#         (3) packet DTS monotonicity scan (catches backward AND duplicate DTS)
# Executable form of references/timeline-repair.md. "Non-monotonic" includes
# DUPLICATE (equal) DTS — ffmpeg flags "X >= X" as invalid, and a field-coded
# stream on a non-integer timebase produces these throughout.
set -euo pipefail
IN="${1:?usage: diagnose.sh INPUT}"
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-paff.sh"   # shared PAFF detection
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT   # only our own scratch; never the source

echo "== diagnosing: $IN =="

# Field-coded (PAFF) + timestamp-profile check up front — it changes every
# verdict below. Two facts pick the repair (post-mortem 2026-07-25):
#   * untimestamped fraction ~0.5 = the PAIR class (only the first field of each
#     pair has PES timestamps) — the detector now counts these packets, so the
#     rate no longer false-reads 1x on exactly this class;
#   * a reorder pyramid (pts!=dts / backward PTS) makes the constant-rate rebuild
#     WRONG (PTS=DTS plays decode order) — the real PTS must be KEPT (pairfill).
eval "$(pf_detect "$IN")"
eval "$(pf_reorder_scan "$IN")"
if [ "$PF_FIELD_RATE" = unknown ]; then
  RB="scripts/rebuild-paff.sh \"$IN\" OUT.mov <FIELD_RATE> <TIMESCALE>  (pick from the field-rate table)"
else
  RB="scripts/rebuild-paff.sh \"$IN\" OUT.mov $PF_FIELD_RATE $PF_TIMESCALE"
fi
PFILL="scripts/pairfill-paff.sh \"$IN\" OUT.mov"
# preferred repair for a broken timeline on THIS stream
if [ "$PF_HALF_TS" = yes ] || [ "$PF_REORDER" = yes ]; then REPAIR="$PFILL"; else REPAIR="$RB"; fi
if [ "$PF_PAFF" = yes ]; then
  echo "** FIELD-CODED (PAFF) H.264: coded-pic rate ${PF_CODED_RATE}/s ~= 2x frame rate ${PF_NOMINAL_FPS}/s."
  echo "** genpts is guilty-until-proven here. **"
fi
if awk "BEGIN{exit !(${PF_NOPTS_FRAC:-0}>0)}"; then
  echo "** ${PF_NOPTS_FRAC} of video packets carry NO timestamps (half_ts=$PF_HALF_TS)."
  [ "$PF_HALF_TS" = yes ] && echo "**   ~half untimestamped = the PAIR signature: each one is the mate of the timestamped field before it -> $PFILL"
fi
echo "** reorder pyramid: $PF_REORDER (pts!=dts on $PF_PTSNEDTS pkt(s), $PF_BACKPTS backward PTS step(s), max offset $PF_MAXOFF_TICKS ticks)"
[ "$PF_REORDER" = yes ] && echo "**   real PTS must be KEPT — a constant-rate restamp (rebuild-paff) would play fields in DECODE order (shuffled motion, invisible to default verify)."

# backhaul/contribution profile facts — they reframe every verdict below.
CONT=$(ffprobe -v error -show_entries format=format_name -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
PIX=$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
IS_TS=no; case "$CONT" in *mpegts*) IS_TS=yes;; esac
if [ "$PF_CODEC" = mpeg2video ] && [ "$PIX" = yuv422p ]; then
  echo "** QT-UNDECODABLE PROFILE: MPEG-2 4:2:2 (yuv422p). AVFoundation/QuickTime has no"
  echo "** working decode path for this profile (controlled comparison 2026-07-30: a"
  echo "** flawless-timeline, fully-verified 4:2:2 MOV still distorts; Main/4:2:0 plays)."
  echo "** Every verdict below governs whether a verified lossless MASTER can be built —"
  echo "** NOT QuickTime playability. QuickTime playback = scripts/rung4.sh (attested"
  echo "** re-encode), the only sanctioned path. mov.sh refuses this profile early (exit 11)."
fi

# (1) decode-to-null: separates real decode damage from timestamp defects.
echo "-- (1) decode-to-null integrity --"
ffmpeg -nostdin -v error -i "$IN" -map 0:v:0 -f null - 2>"$TMP/null.err" || true
ndecode=$(grep -ciE 'error while decoding|concealing|invalid data' "$TMP/null.err" || true)
nmono=$(grep -ciE 'non.?monotonical' "$TMP/null.err" || true)
sort "$TMP/null.err" | uniq -c | sort -rn | head -8 | sed 's/^/   /'
echo "   decode-damage lines: ${ndecode:-0} | non-monotonic-DTS warnings: ${nmono:-0}"
if [ "${ndecode:-0}" -ge 5 ]; then
  echo ">> VERDICT: SOURCE DAMAGED (dropped/corrupt packets). No remux repairs this. Re-capture."
  exit 0
fi
echo "   (a few mmco/ref-frame lines are benign and carry through losslessly)"

# (2) strict mux to MKV — Matroska refuses the absent timestamps MOV swallows.
echo "-- (2) MKV strict-mux test --"
if ffmpeg -nostdin -v error -i "$IN" -map 0:v:0 -map "0:a?" -c copy "$TMP/t.mkv" 2>"$TMP/mkv.err"; then
  echo "   MKV mux OK -> timestamps are present (not missing)."
  mkv_ok=1
else
  echo "   MKV mux FAILED:"; sed 's/^/     /' "$TMP/mkv.err" | tail -3
  if grep -qiE 'timestamp.*unset|unknown timestamp' "$TMP/mkv.err"; then
    if [ "$PF_PAFF" = yes ] || [ "$PF_HALF_TS" = yes ]; then
      echo ">> VERDICT: MISSING TIMESTAMPS on FIELD-CODED (PAFF) H.264."
      echo "   Skip genpts (guilty-until-proven on PAFF); a straight copy makes the MOV"
      echo "   muxer INVENT the timeline (the shipped-broken-file class)."
      if [ "$PF_HALF_TS" = yes ]; then
        echo "   Pair signature (~half the packets untimestamped) -> keep every real PTS"
        echo "   and fill the pair-mates:"
        echo "   $PFILL"
        [ "$PF_REORDER" = yes ] && echo "   (reorder pyramid present — rebuild-paff.sh would shuffle motion; it now refuses this class)"
      elif [ "$PF_REORDER" = yes ]; then
        echo "   Reorder pyramid present -> keep the surviving PTS: $PFILL"
        echo "   (constant-rate rebuild would play fields in decode order)"
      else
        echo "   No reorder detected -> field-rate rebuild is safe: $RB"
      fi
    else
      echo ">> VERDICT: MISSING TIMESTAMPS. Try Rung-2 genpts (remux.sh --genpts);"
      echo "   if it still glitches, full rebuild: $RB"
      [ "$PF_REORDER" = yes ] && echo "   NOTE: reorder pyramid present — if genpts output misbehaves, prefer $PFILL (keeps real PTS) over a flattening rebuild."
    fi
    exit 0
  fi
  mkv_ok=0
fi

# (3) packet DTS monotonicity (backward OR duplicate). <= catches equal DTS.
echo "-- (3) DTS monotonicity scan --"
read -r ndup nback < <(ffprobe -v error -select_streams v:0 -read_intervals "%+#5000" \
  -show_entries packet=dts -of csv=p=0 "$IN" 2>/dev/null | \
  awk -F, 'NR>1 && $1!="N/A" && p!="N/A"{ if($1<p)bk++; else if($1==p)du++ } {p=$1}
    END{print (du+0), (bk+0)}')
echo "   first 5000 packets: duplicate(equal) DTS=${ndup:-0}  backward DTS=${nback:-0}"

# (4) forward-gap (discontinuity) scan — timestamps that are present AND monotonic
# but JUMP forward (dropped frames). Steps (1)-(3) and the MKV mux all PASS these;
# only a delta scan finds them. They are the class that silently desyncs raw PCM
# audio on a blind copy (MOV PCM can't hold a gap) — the remux-sync post-mortem.
echo "-- (4) discontinuity (forward-gap) scan --"
eval "$(disc_scan "$IN")"
echo "   forward gaps: ${DISC_COUNT:-0}  (dropped ~${DISC_MISSING:-0}s; frame=${DISC_FRAMEDUR:-?}s)"
# same demux pass, whole file: the DTS-rot counters the windowed step-(3) scan
# can miss when the defects sit mid-file at splice points (the 2009/2012 class)
echo "   whole-file DTS rot: backward=${DISC_BACK:-0}  duplicate=${DISC_DUP:-0}"

# --- verdict ---
# rot condition includes the WHOLE-FILE counters from step (4): the windowed
# step-(3) scan read 0 on the 2009/2012 backhaul feeds whose defects sat
# mid-file at splice points.
if [ "${nmono:-0}" -ge 10 ] || [ "${ndup:-0}" -gt 0 ] || [ "${nback:-0}" -gt 0 ] || [ "${DISC_BACK:-0}" -gt 0 ] || [ "${DISC_DUP:-0}" -gt 0 ]; then
  if [ "$PF_CODEC" = mpeg2video ] && [ "$IS_TS" = yes ] && [ "${DISC_COUNT:-0}" -gt 0 ]; then
    echo ">> VERDICT: BACKHAUL TIMELINE ROT — mpegts/mpeg2video with ${DISC_COUNT} forward"
    echo "   gap(s) (~${DISC_MISSING:-0}s dropped) PLUS non-monotonic DTS (whole-file"
    echo "   backward=${DISC_BACK:-0} duplicate=${DISC_DUP:-0}; windowed dup=${ndup:-0} back=${nback:-0};"
    echo "   decode warnings=${nmono:-0}). NO lossless MOV route survives verify on this"
    echo "   class: a plain copy makes the MOV muxer invent timing (mux-confession hard"
    echo "   stop), and a resync build leaves near-zero sample durations that gate (d)"
    echo "   correctly fails — the invented-timeline signature. Do NOT route this to"
    echo "   resync.sh. mov.sh refuses it up front (exit 11). Honest routes:"
    echo "     keep     the .ts — it is already the archival master"
    echo "     playback ffmpeg -i \"$IN\" -map 0:v:0 -map '0:a?' -c copy OUT.mkv"
    echo "              (Matroska stores per-block timestamps — the discontinuous"
    echo "               timeline survives honestly; plays in IINA/VLC/mpv)"
    echo "     rung4    scripts/rung4.sh — operator-attested re-encode, the only"
    echo "              sanctioned path to a QuickTime-native deliverable"
  else
    echo ">> VERDICT: NON-MONOTONIC / DUPLICATE DTS (broken timeline, common on a"
    echo "   field-coded stream muxed on a non-integer timebase). Repair for THIS"
    echo "   stream's timestamp profile: $REPAIR"
    [ "$REPAIR" = "$PFILL" ] && echo "   (real PTS survives / reorder present -> keep it; a constant-rate rebuild would flatten the pyramid)"
  fi
elif [ "${mkv_ok:-1}" -eq 1 ]; then
  if [ "$PF_PAFF" = yes ]; then
    echo ">> VERDICT: timing PASSES the mux tests, but this is FIELD-CODED (PAFF)"
    echo "   H.264 — the strict-mux test proves timestamps are present and monotonic,"
    echo "   NOT that the timeline is seekable. That gap is exactly where the silent"
    echo "   corruption lives. Treat plain copy / genpts as provisional:"
    if [ "$PF_REORDER" = yes ]; then
      echo "     first:     plain copy (keeps the true timeline) gated by the scrub test:"
      echo "                scripts/verify.sh \"$IN\" OUT.mov   (fails on a glitchy scrub)"
      echo "     repair:    $PFILL   (keeps real PTS; rebuild-paff would shuffle motion)"
    else
      echo "     reliable:  $RB"
      echo "     or verify a copy with the scrub gate before trusting it:"
      echo "                scripts/verify.sh \"$IN\" OUT.mov   (fails on a glitchy scrub)"
    fi
  elif [ "${DISC_COUNT:-0}" -gt 0 ]; then
    echo ">> VERDICT: DISCONTINUOUS SOURCE — ${DISC_COUNT} forward timestamp gap(s),"
    echo "   first @ ${DISC_FIRST}s (~${DISC_MISSING}s dropped). Video timing is otherwise"
    echo "   sound, so the mux 'succeeds' — but a blind -c copy COLLAPSES these gaps in"
    echo "   raw PCM audio, sliding it out of sync with the picture. Do NOT plain-copy"
    echo "   PCM here. Gap-fill the audio (video stays bit-identical):"
    echo "     scripts/resync.sh \"$IN\" OUT.mov"
    echo "   Then confirm: scripts/verify.sh \"$IN\" OUT.mov  (the duration-parity gate)."
  else
    echo ">> VERDICT: timing looks sound -> plain copy (Rung 0): scripts/remux.sh."
    echo "   (If MOV still glitches despite this, repair by profile: $REPAIR)"
  fi
else
  echo ">> VERDICT: timestamps problematic (MKV refused) -> repair: $REPAIR"
fi
# A discontinuous source still needs an audio gap-fill even when the video path is
# a rebuild (PAFF / non-monotonic) — flag it so it isn't missed on those branches.
if [ "${DISC_COUNT:-0}" -gt 0 ] && { [ "${nmono:-0}" -ge 10 ] || [ "${ndup:-0}" -gt 0 ] || [ "${nback:-0}" -gt 0 ] || [ "$PF_PAFF" = yes ]; }; then
  echo "   ALSO: ${DISC_COUNT} discontinuit(ies) present — if any audio track is raw PCM,"
  echo "   gap-fill it (scripts/resync.sh) so audio stays pinned through the rebuild."
fi

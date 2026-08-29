#!/usr/bin/env bash
# surgical-cut.sh — the sanctioned way to cut MPEG-TS at a non-IDR-bound,
# frame-targeted address WITHOUT re-encoding and without leaving the source
# container: deterministic packet selection, no seeking at all (the feed.ts
# Phase-4 recipe, 2026-08-26). Both `-ss` forms are measured-unreliable for
# precision cuts on TS — output-side -ss waits for a keyframe by its own rules
# and skipped past the target GOP; input-side -ss binary-searches a container
# with no index and overshot the same way — so every drop decision here is
# made by VIDEO PACKET INDEX or AUDIO PTS, both read from a prior census
# (lead-check.sh emits them), replayed through the `noise` bsf under -copyts.
# Index selection is what the PAFF pair class REQUIRES (untimestamped mates
# break any pts-expression on half the packets), and it in turn requires the
# no-seek whole-file pass: that constraint is a feature, not a cost.
#
# THE LEADING-B RULE (case-file, measured): at an open-GOP cut the leading
# B-pictures are decoder-discarded (no visual glitch) but their PTS precede
# the target keyframe and poison format.start_time — drop them (and their
# untimestamped PAFF mates) by index: --video-drop-between.
#
# TIER 2 — CONTENT-DISCARDING (the clinic consent model): unlike trim-to-idr
# (which removes only undecodable pre-roll), this cut discards DECODABLE
# media — black lead video and, typically, real program audio that is already
# hot under it. It therefore REFUSES to run without the operator's explicit
# --discard-content, and prints the exact loss statement (seconds of video
# and audio removed) before building. The untouched original retains
# everything; that is what makes the trade reversible.
#
# Usage: scripts/surgical-cut.sh INPUT OUTPUT.ts --video-drop-lt N
#          [--video-drop-between A B]   the leading-B range (inclusive)
#          [--audio-drop-lt-pts TICKS]  audio packets before this raw PTS
#          [--offset SECS|auto]         -output_ts_offset (auto = land the
#                                       first kept video packet's DTS at 0)
#          --discard-content            the Tier-2 consent flag (required)
# Gates (atomic .part -> mv only after ALL of them):
#   * mux-log: 0 hard confessions; monotonicity nudges == the null-muxer
#     prediction (lib-rewrap.sh contract);
#   * first output video packet: keyframe-flagged AND byte-identical in size
#     to the source packet at index N (the trim-to-idr same-coded-AU gate);
#   * post-mux census (D5) + the full verify-source battery with the SAME
#     drop expressions as the filtered reference — hash equality proves the
#     mux added, altered and reordered nothing beyond the declared selection.
# Exit (house contract): 0 DONE | 10 REVIEW | 1 FAIL | 2 usage/pre-flight.
# Machine line (stable API — extend only):
#   SCUT_SUMMARY out= vdrop_lt= vdrop_between= adrop_lt_pts= offset=
#     predicted_nudges= observed_nudges= verdict=
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-exit.sh"   # exit-code contract trap: no stray code escapes
IN="${1:?usage: surgical-cut.sh INPUT OUTPUT.ts --video-drop-lt N [--video-drop-between A B] [--audio-drop-lt-pts TICKS] [--offset SECS|auto] --discard-content}"
OUT="${2:?need OUTPUT.ts (same container family as the input)}"; shift 2
VLT=""; VBA=""; VBB=""; APTS=""; OFF=auto; CONSENT=0
while [ $# -gt 0 ]; do case "$1" in
  --video-drop-lt) VLT="${2:?--video-drop-lt needs N}"; shift 2;;
  --video-drop-between) VBA="${2:?--video-drop-between needs A B}"; VBB="${3:?--video-drop-between needs A B}"; shift 3;;
  --audio-drop-lt-pts) APTS="${2:?--audio-drop-lt-pts needs TICKS}"; shift 2;;
  --offset) OFF="${2:?--offset needs SECS or auto}"; shift 2;;
  --discard-content) CONSENT=1; shift;;
  *) echo "unknown opt: $1" >&2; exit 2;;
esac; done
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }
[ -n "$VLT" ] || { echo "--video-drop-lt N is required (lead-check.sh measures it)" >&2; exit 2; }
case "$VLT" in *[!0-9]*) echo "--video-drop-lt must be a packet index" >&2; exit 2;; esac
. "$SELF_DIR/lib-probe.sh"  # ffp/FF_INPUT_OPTS: raised probe window on every input open
. "$SELF_DIR/lib-mux.sh"    # rtm_part + mux_census (D5)
rtm_sibling_guard "$IN" "$OUT" || exit 2   # TIER 1 T1.11 write beside the source, never onto it (one writer: lib-mux.sh)
. "$SELF_DIR/lib-rewrap.sh" # layout preservation + the prediction contract
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT   # only our own scratch; never the source

echo "== surgical-cut: $IN -> $OUT =="

CONT=$(ffp1 -v error -show_entries format=format_name -of default=nw=1:nk=1 "$IN" 2>/dev/null)
case "$CONT" in *mpegts*) ;; *)
  echo "not an mpegts-family source (container=$CONT) — the deterministic-index recipe" >&2
  echo "is measured on mpegts; other containers route through the remux ladder" >&2
  echo "(references/cutting-concat.md)." >&2
  exit 2;;
esac
NPROG=$(ffp1 -v error -show_entries format=nb_programs -of default=nw=1:nk=1 "$IN" 2>/dev/null)
if [ "${NPROG:-1}" -gt 1 ] 2>/dev/null; then
  echo "multi-program TS ($NPROG programs): isolate the program first (known-limits.md):" >&2
  echo "  ffmpeg -nostdin -i \"$IN\" -map 0:p:<PROGRAM_NUM> -c copy PROG.ts" >&2
  exit 2
fi
# herestring, never `ffmpeg | grep -q`: grep -q closes the pipe early and a
# SIGPIPE under pipefail reads back as a false "missing" (the doctor.sh rule)
SC_BSFS=$(ffmpeg -hide_banner -bsfs 2>/dev/null || true)
grep -qw noise <<<"$SC_BSFS" || { echo "this ffmpeg lacks the 'noise' bitstream filter" >&2; exit 2; }

# --- the target packet: pts/dts/size from the census (never a seek) ---------------
eval "$(ffp -v error -select_streams v:0 -read_intervals "%+#$((VLT+2))" \
          -show_entries packet=pts,dts,size,flags -of csv=p=0 "$IN" 2>/dev/null | \
        awk -F, -v k="$VLT" 'NR==k+1{ printf "k_pts=%s k_dts=%s k_size=%s k_key=%d\n", $1, $2, $3, (index($4,"K")>0) }')"
[ -n "${k_size:-}" ] || { echo "video packet index $VLT is beyond the probe window/file" >&2; exit 2; }
if [ "${k_key:-0}" -ne 1 ]; then
  echo "the packet at index $VLT is NOT keyframe-flagged — a cut there decodes as" >&2
  echo "garbage until the next keyframe. Re-measure with lead-check.sh (it addresses" >&2
  echo "the splice KEYFRAME), or pick the keyframe index deliberately." >&2
  exit 2
fi
TB=$(ffp1 -v error -select_streams v:0 -show_entries stream=time_base -of default=nw=1:nk=1 "$IN" 2>/dev/null)
TICK=${TB##*/}; case "$TICK" in ''|*[!0-9]*) TICK=90000;; esac
K_REF="${k_dts:-}"; { [ -z "$K_REF" ] || [ "$K_REF" = N/A ]; } && K_REF="$k_pts"
if [ "$OFF" = auto ]; then
  { [ -z "$K_REF" ] || [ "$K_REF" = N/A ]; } && { echo "target packet carries no timestamp — pass --offset explicitly" >&2; exit 2; }
  OFF=$(awk "BEGIN{printf \"%.6f\", -($K_REF)/$TICK}")
fi
echo "   target: video packet $VLT (pts=${k_pts:-na} dts=${k_dts:-na} size=${k_size}B, keyframe); offset ${OFF}s"

# --- the loss statement + Tier-2 consent ------------------------------------------
FIRST_VPTS=$(ffp1 -v error -select_streams v:0 -read_intervals '%+#1' -show_entries packet=pts -of csv=p=0 "$IN" 2>/dev/null | tr -d ,)
VLOSS=na
[ -n "$FIRST_VPTS" ] && [ "$FIRST_VPTS" != N/A ] && [ -n "$k_pts" ] && [ "$k_pts" != N/A ] && \
  VLOSS=$(awk "BEGIN{printf \"%.3f\", (($k_pts)-($FIRST_VPTS))/$TICK}")
ALOSS=na
if [ -n "$APTS" ]; then
  FIRST_APTS=$(ffp1 -v error -select_streams a:0 -read_intervals '%+#1' -show_entries packet=pts -of csv=p=0 "$IN" 2>/dev/null | tr -d ,)
  [ -n "$FIRST_APTS" ] && [ "$FIRST_APTS" != N/A ] && \
    ALOSS=$(awk "BEGIN{v=(($APTS)-($FIRST_APTS))/$TICK; if(v<0)v=0; printf \"%.3f\", v}")
fi
echo "   LOSS STATEMENT — this cut discards DECODABLE media:"
echo "     video: $VLT packet(s) before the target (~${VLOSS}s of picture)"
[ -n "$VBA" ] && echo "     video: plus the leading-B range $VBA-$VBB ($((VBB-VBA+1)) packet(s))"
[ -n "$APTS" ] && echo "     audio: everything before raw PTS $APTS (~${ALOSS}s per stream)" \
                || echo "     audio: untouched (no --audio-drop-lt-pts) — EXPECT A/V skew if audio starts earlier"
echo "     The untouched original retains all of it."
if [ "$CONSENT" -ne 1 ]; then
  echo ">> REFUSED: this is a Tier-2 content-discarding cut. Removing decodable media" >&2
  echo "   is the operator's trade, never this tool's — re-run with --discard-content" >&2
  echo "   to make that call explicitly. Nothing was written." >&2
  exit 2   # TIER 1 T1.7 the operator's own --discard-content consent gate
fi

# --- drop expressions (the declared selection — also the verification reference) --
VEXPR="lt(n\\,$VLT)"
[ -n "$VBA" ] && VEXPR="$VEXPR+between(n\\,$VBA\\,$VBB)"
FILTV="noise=drop=$VEXPR"
FILTA=""
[ -n "$APTS" ] && FILTA="noise=drop=lt(pts\\,$APTS)"
echo "   selection: -bsf:v '$FILTV'${FILTA:+ -bsf:a '$FILTA'} (replayed verbatim by verify-source)"

# --- layout, then the prediction contract -----------------------------------------
# layout FIRST (1.15.2 Defect B): the pre-pass is a true dry run of the build
# below — same mpegts muxer, same filters, and the SAME extra options, mirrored
# through the RW_PREDICT_* arrays the build then splices itself so the two
# command lines cannot drift apart.
rewrap_layout "$IN"
echo "   layout: $RW_LAYOUT_NOTE"
RW_PREDICT_IN_OPTS=(-copyts)
RW_PREDICT_OUT_OPTS=(-output_ts_offset "$OFF")
echo "-- prediction pre-pass (true dry run: same mpegts mux, filtered, bytes discarded) --"
PRED=$(rewrap_predict "$IN" "$FILTV" "$FILTA")
echo "   predicted monotonicity nudges: ${PRED:-0}"

# --- build ------------------------------------------------------------------------
trap 'rm -rf "$TMP"; rtm_unlock' EXIT   # re-armed: TMP cleanup + writer-lock release (WO-1.15.6 A2)
rtm_writer_preflight "$OUT" "$IN" || exit 2
PART="$(rtm_part "$OUT")"
MUXLOG="$TMP/mux.log"
BARGS=(-bsf:v "$FILTV")
[ -n "$FILTA" ] && BARGS+=(-bsf:a "$FILTA")
if ! ffmpeg -nostdin -y -hide_banner -nostats -v warning "${FF_INPUT_OPTS[@]}" \
      "${RW_PREDICT_IN_OPTS[@]}" -i "$IN" \
      -map 0 -c copy "${BARGS[@]}" \
      "${RW_PREDICT_OUT_OPTS[@]}" -muxdelay 0 -muxpreload 0 \
      ${RW_STREAMID_OPTS[@]+"${RW_STREAMID_OPTS[@]}"} \
      ${RW_MUX_OPTS[@]+"${RW_MUX_OPTS[@]}"} \
      -f mpegts "$PART" 2>"$MUXLOG"; then
  echo ">> build FAILED:"; sed 's/^/   /' "$MUXLOG" | tail -8; rm -f "$PART"; exit 1
fi
HARD=$(rewrap_hard_confessions "$MUXLOG")
OBS=$(rewrap_nudges "$MUXLOG")
if [ "${HARD:-0}" -gt 0 ]; then
  echo ">> HARD STOP: the mux log confesses invented timing ($HARD line(s)). NOT" >&2
  echo "   blessing; evidence kept at $PART and $PART.muxlog. Route: scripts/diagnose.sh." >&2
  cp "$MUXLOG" "$PART.muxlog" 2>/dev/null || true
  exit 1
fi
if [ "${OBS:-0}" -ne "${PRED:-0}" ]; then
  echo ">> FAIL: prediction contract breached — predicted $PRED nudge site(s), observed" >&2
  echo "   $OBS. Evidence kept at $PART; mux log at $PART.muxlog." >&2
  cp "$MUXLOG" "$PART.muxlog" 2>/dev/null || true
  exit 1
fi
echo "   mux: observed nudges=$OBS == predicted $PRED; hard confessions: 0"

# --- gates ------------------------------------------------------------------------
# (a) first output video packet = THE target coded AU (keyframe + exact byte size —
#     the trim-to-idr same-AU gate: "starts on a key" alone would wave through a
#     cut that landed on the wrong keyframe)
eval "$(ffp -v error -select_streams v:0 -read_intervals '%+#1' \
          -show_entries packet=size,flags -of csv=p=0 "$PART" 2>/dev/null | \
        awk -F, 'NR==1{printf "o_size=%s o_key=%d\n", $1, (index($2,"K")>0)} END{if(NR==0) print "o_size=0 o_key=0"}')"
if [ ! -s "$PART" ] || [ "${o_size:-0}" = 0 ]; then
  rm -f "$PART"; echo ">> FAIL: cut produced no video" >&2; exit 1
fi
if [ "${o_key:-0}" -ne 1 ] || [ "$o_size" != "$k_size" ]; then
  echo ">> FAIL: first output packet is not the target AU (key=$o_key size=${o_size}B," >&2
  echo "   want key=1 size=${k_size}B). NOT blessing; kept at $PART." >&2
  exit 1
fi
echo "   gate (a): first output packet = the target keyframe AU (key, ${o_size}B)"
# (b) post-mux census (D5): every source stream present, codec-identical
SC_C=$(ffp -v error -show_entries stream=index,codec_name -of csv=p=0 "$IN" 2>/dev/null | \
       awk -F, 'NF{ if(seen[$1]++) next; printf "%s%s", s, $2; s="," }')
SC_N=$(printf '%s' "$SC_C" | awk -F, '{print ($0=="" ? 0 : NF)}')
census_rc=0
mux_census "$PART" "$SC_N" "$SC_C" surgical-cut "$IN" || census_rc=$?
if rtm_census_failed "$census_rc"; then
  echo "   NOT blessing; kept at $PART." >&2
  exit 1
fi
# (c) the verify-source battery with the identical selection. A mid-head
#     leading-B drop leaves one DTS-only hole where the discarded slots sat
#     (presentation contiguous — the case-file benign class): explained.
GAPD=0; [ -n "$VBA" ] && GAPD=1
TRIM="$VLOSS"; [ "$TRIM" = na ] && TRIM=0
echo "-- verification battery (verify-source.sh, filtered reference) --"
VARGS=(--filter-v "$FILTV" --trim-head "$TRIM" --expect-gaps-delta "$GAPD")
[ -n "$FILTA" ] && VARGS+=(--filter-a "$FILTA")
set +e
bash "$SELF_DIR/verify-source.sh" "$IN" "$PART" "${VARGS[@]}"
vrc=$?
set -e
case "$vrc" in
  0)  VERDICT=ok;;
  10) VERDICT=review;;
  *)  echo ">> verification FAILED (rc=$vrc). NOT blessing; evidence kept at $PART." >&2; exit 1;;
esac
if rtm_census_review "$census_rc"; then VERDICT=review; fi

mv -f "$PART" "$OUT"
echo "wrote: $OUT"
echo "   kept media byte-identical to the source (filtered-reference hash); the"
echo "   original is untouched and retains everything this cut discarded."
VB_STR=none; [ -n "$VBA" ] && VB_STR="$VBA-$VBB"
echo "SCUT_SUMMARY out=$OUT vdrop_lt=$VLT vdrop_between=$VB_STR adrop_lt_pts=${APTS:-none} offset=$OFF predicted_nudges=${PRED:-0} observed_nudges=${OBS:-0} verdict=$VERDICT"
[ "$VERDICT" = review ] && exit 10
exit 0

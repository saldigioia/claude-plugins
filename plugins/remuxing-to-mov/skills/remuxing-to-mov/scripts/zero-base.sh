#!/usr/bin/env bash
# zero-base.sh — Tier-1 structural re-wrap: rebase an mpegts capture's timeline
# to the legal floor WITHOUT re-encoding, without changing container, without
# touching the source. The feed.ts Fix-v1 recipe (case file 2026-08-26), as a
# gated rung: `-muxdelay 0 -muxpreload 0` stream copy, PID/program layout
# preserved (lib-rewrap.sh), every kept byte proven by verify-source.sh.
#
# THE FLOOR, STATED UP FRONT (case-file lesson 6): the minimum achievable
# start is the first video frame's REORDER DELAY (its PTS-DTS gap). MPEG-TS
# cannot represent negative DTS, so with B-frames in flight format.start_time
# lands at that delay, not 0.000000 — players rebase it away (the player clock
# reads 0). Getting ffprobe to PRINT zero would require inventing DTS: refused
# on doctrine. This script computes and announces the floor BEFORE building.
#
# THE PREDICTION CONTRACT (case-file step 4; re-grounded 1.15.2 Defect B): a
# TRUE DRY RUN — the build's own mpegts mux with the bytes discarded — counts
# the DTS monotonicity-collision sites first, the script announces the
# expected artifact set (the measured class: CLI-filled mate DTS collide as
# equals and take a +1-tick nudge, presentation timestamps untouched), and
# after the build the mux log's observed nudge count must EQUAL the
# prediction — a surprise on either side is a verdict, not a shrug.
#
# WHAT IT REFUSES (pre-flight, nothing written — the dual-track exit-2
# precedent for impossible contracts):
#   * non-mpegts sources (matroska/MP4 start at zero by construction or are
#     the remux ladder's business);
#   * multi-program TS (the muxer cannot reconstruct that layout from -map 0;
#     isolate one program first — known-limits.md);
#   * pair-timestamped PAFF (pf_detect half_ts/paff=yes): measured on the
#     2022-08-28 field source (1.15.2 Item C), the TS->TS copy makes the
#     mpegts muxer confess 'Timestamps are unset' — the invented-timing
#     hard-stop class — AFTER building 23.68 GB, for a prize of 40 ms on a
#     start_time every player rebases away. Refuse before building; the .mov
#     route is pairfill-paff.sh and the .ts source is already the master;
#   * timeline rot (whole-file backward/duplicate DTS > 0): zero-base is NOT
#     a timeline repair — diagnose.sh routes those (derive-dts.sh et al.).
#
# Usage: scripts/zero-base.sh INPUT OUTPUT.ts
#   OUTPUT stays in the mpegts family (give it the source's own extension).
# Exit (house contract): 0 DONE | 10 REVIEW | 1 FAIL | 2 usage/pre-flight.
# Machine line (stable API — extend only):
#   ZB_SUMMARY out= start_src= start_out= floor= predicted_nudges=
#     observed_nudges= verdict=
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-exit.sh"   # exit-code contract trap: no stray code escapes
IN=""; OUT=""; PREFLIGHT_ONLY=0; SRC_TSH=""
while [ $# -gt 0 ]; do case "$1" in
  # --preflight-only: run THIS script's own refusal logic, write nothing, and
  # report whether the source is eligible (0) or refused (2). Exists so other
  # drivers can ASK instead of re-deriving the conditions — clean.sh used to
  # model them and fell two axes behind twice (F12 multi-program; both PAFF
  # arms). One authority, asked directly, cannot fall behind itself.
  --preflight-only) PREFLIGHT_ONLY=1; shift;;
  # --src-tsh: reuse a caller's saved `ts-health.sh SRC --kv` (verify-source's
  # convention — one scanner, one truth), so asking does not re-run the
  # whole-file rot scan the caller already paid for.
  --src-tsh) SRC_TSH="${2:?--src-tsh needs FILE}"; shift 2;;
  -*) echo "unknown opt: $1" >&2; exit 2;;
  *) if   [ -z "$IN"  ]; then IN="$1"
     elif [ -z "$OUT" ]; then OUT="$1"
     else echo "unexpected extra argument: $1" >&2; exit 2; fi; shift;;
esac; done
[ -n "$IN" ] || { echo "usage: zero-base.sh INPUT OUTPUT.ts [--preflight-only] [--src-tsh FILE]" >&2; exit 2; }
if [ "$PREFLIGHT_ONLY" -eq 1 ]; then
  # never created — only its NAME is inspected by the same-path/extension checks
  OUT="${OUT:-$IN.preflight-probe.ts}"
else
  [ -n "$OUT" ] || { echo "need OUTPUT.ts (same container family as the input)" >&2; exit 2; }
fi
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }
[ -z "$SRC_TSH" ] || [ -f "$SRC_TSH" ] || { echo "no such --src-tsh file: $SRC_TSH" >&2; exit 2; }
[ "$(cd "$(dirname "$IN")" && pwd)/$(basename "$IN")" != "$(cd "$(dirname "$OUT")" 2>/dev/null && pwd)/$(basename "$OUT")" ] \
  || { echo "refusing to overwrite the source in place" >&2; exit 2; }
. "$SELF_DIR/lib-probe.sh"  # ffp/FF_INPUT_OPTS: raised probe window on every input open
. "$SELF_DIR/lib-paff.sh"   # pf_detect: the pair-timestamped-PAFF pre-flight
. "$SELF_DIR/lib-mux.sh"    # rtm_part: extension-keeping atomic part files
. "$SELF_DIR/lib-rewrap.sh" # layout preservation + the prediction contract
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT   # only our own scratch; never the source

if [ "$PREFLIGHT_ONLY" -eq 1 ]; then
  echo "== zero-base pre-flight only (report; nothing will be written): $IN =="
else
  echo "== zero-base: $IN -> $OUT =="
fi

# --- pre-flight -------------------------------------------------------------------
CONT=$(ffp1 -v error -show_entries format=format_name -of default=nw=1:nk=1 "$IN" 2>/dev/null)
case "$CONT" in *mpegts*) ;; *)
  echo "not an mpegts-family source (container=$CONT)." >&2
  echo "zero-base is the mpegts re-wrap: matroska/MP4 timelines start at zero by" >&2
  echo "construction or belong to the remux ladder (scripts/remux.sh)." >&2
  exit 2;;
esac
NPROG=$(ffp1 -v error -show_entries format=nb_programs -of default=nw=1:nk=1 "$IN" 2>/dev/null)
if [ "${NPROG:-1}" -gt 1 ] 2>/dev/null; then
  echo "multi-program TS ($NPROG programs): the mpegts muxer cannot reconstruct that" >&2
  echo "layout from -map 0 — isolate the program first (known-limits.md):" >&2
  echo "  ffmpeg -nostdin -i \"$IN\" -map 0:p:<PROGRAM_NUM> -c copy PROG.ts" >&2
  exit 2
fi
# B1 (WO-1.15.7): no video stream -> refuse at PRE-FLIGHT. verify-source —
# this rung's mandatory identity battery — refuses video-less re-wraps, so
# pre-round the full re-wrap was built only to die at that refusal (the
# 1.15.2 Item-C shape on a new axis; measured on an MP2-only TS).
zb_vidx=$(ffp1 -v error -select_streams v:0 -show_entries stream=index -of default=nw=1:nk=1 "$IN" 2>/dev/null || true)
case "${zb_vidx:-}" in ''|*[!0-9]*)
  echo "no video stream in the source: refusing at pre-flight — verify-source's" >&2
  echo "identity battery requires video, so an audio-only re-wrap could never be" >&2
  echo "blessed (never build to a foregone refusal). Nothing was written. An" >&2
  echo "audio-only deliverable extracts directly: ffmpeg -i IN -map 0:a -c copy OUT" >&2
  exit 2;;
esac
# pair-timestamped-PAFF check (1.15.2 Item C) — windowed and cheap, so it runs
# BEFORE the whole-file scan: on the field source the old order burned a 54 s
# scan plus a 23.68 GB build to reach a foregone hard-stop. pf_detect's
# PF_PKT_FILE hook keeps this pinnable without mintable PAFF media.
# F1 (WO-1.15.7): the two PAFF shapes are now DIAGNOSED separately — the old
# single arm labeled a fully-timestamped PAFF source "pair-timestamped",
# claimed untimestamped mates it does not have, and routed it to
# pairfill-paff.sh, which exits 3 on exactly that file. The refusal POLICY
# stands for both shapes; the diagnosis and the route now match the profile.
eval "$(pf_detect "$IN")"
if [ "${PF_HALF_TS:-no}" = yes ]; then
  echo "pair-timestamped PAFF source (paff=$PF_PAFF half_ts=$PF_HALF_TS): refusing at pre-flight." >&2
  echo "A TS->TS copy of this shape makes the mpegts muxer invent timing for the" >&2
  echo "untimestamped mates ('Timestamps are unset' — the hard-stop class, measured" >&2
  echo "2026-08-27 on a 23.68 GB field source AFTER the full build), and the prize is" >&2
  echo "cosmetic: format.start_time lands at the reorder-delay floor either way and" >&2
  echo "players rebase it — the player clock already reads 0. The source IS the master." >&2
  echo "For the QuickTime deliverable route: scripts/pairfill-paff.sh IN OUT.mov" >&2
  exit 2
elif [ "${PF_PAFF:-no}" = yes ]; then
  echo "field-coded (PAFF) source with a COMPLETE timestamp column (paff=$PF_PAFF half_ts=no):" >&2
  echo "refusing at pre-flight — POLICY, not measurement (WO-1.15.7 F1): the 'TS->TS" >&2
  echo "copy preserves PAFF' claim is scoped to its 1.15.2 case file and unproven for" >&2
  echo "this shape, and the prize is cosmetic (players rebase start_time — the clock" >&2
  echo "already reads 0). This is NOT the pair-timestamped class: every packet is" >&2
  echo "stamped, and pairfill-paff.sh would refuse this very file (exit 3, half_ts=no)." >&2
  echo "For a QuickTime deliverable: scripts/mov.sh (the copy ladder keeps the true" >&2
  echo "reorder pyramid; scrub-gated); if ITS verify names timestamp work, scripts/" >&2
  echo "diagnose.sh routes by measured profile. The source IS the master." >&2
  exit 2
fi
# whole-file rot check — zero-base is not a timeline repair. Saved for reuse:
# verify-source consumes the same scan via --src-tsh (one scanner, one truth).
echo "-- pre-flight: whole-file health scan (ts-health) --"
thrc=0
if [ -n "$SRC_TSH" ]; then
  echo "   (reusing the caller's scan: $SRC_TSH — one scanner, one truth)"
  cat "$SRC_TSH" > "$TMP/src.tsh"
else
  set +e; bash "$SELF_DIR/ts-health.sh" "$IN" --kv > "$TMP/src.tsh" 2>/dev/null; thrc=$?; set -e
fi
[ -s "$TMP/src.tsh" ] || { echo "ts-health could not scan the source (rc=$thrc)" >&2; exit 1; }
S_BACK=$(sed -n 's/^TSH_BACK=//p' "$TMP/src.tsh" | head -1)
S_DUP=$(sed -n 's/^TSH_DUP=//p' "$TMP/src.tsh" | head -1)
S_SCR=$(sed -n 's/^TSH_SCRAMBLED=//p' "$TMP/src.tsh" | head -1)
if [ "${S_SCR:-0}" -gt 0 ]; then echo "source is scrambled — nothing here can recover it" >&2; exit 1; fi
if [ "${S_BACK:-0}" -gt 0 ] || [ "${S_DUP:-0}" -gt 0 ]; then
  echo "timeline rot in the source (backward DTS=$S_BACK duplicate DTS=$S_DUP, whole-file):" >&2
  echo "zero-base would let the muxer rewrite the rotten sites silently — that is a" >&2
  echo "TIMELINE REPAIR and belongs to its own rungs. Route: scripts/diagnose.sh" >&2
  echo "(it picks pairfill/derive-dts/rebuild by the measured profile)." >&2
  exit 2
fi

# Every shape-based refusal has now been evaluated. A caller that only wanted
# the verdict stops here — before the floor probe, the layout pass and the
# prediction dry run, none of which are refusals and all of which cost.
if [ "$PREFLIGHT_ONLY" -eq 1 ]; then
  echo ">> ELIGIBLE: no pre-flight refusal applies to this source."
  echo "ZB_PREFLIGHT verdict=eligible container=$CONT programs=${NPROG:-1} paff=${PF_PAFF:-no} half_ts=${PF_HALF_TS:-no} back=${S_BACK:-0} dup=${S_DUP:-0}"
  echo "   (eligibility is about the SOURCE SHAPE. The writer lock and disk"
  echo "    headroom are build-time conditions and are checked then.)"
  exit 0
fi

# --- the floor, announced before anything is built --------------------------------
eval "$(ffp -v error -select_streams v:0 -read_intervals '%+#1' \
          -show_entries packet=pts,dts -of csv=p=0 "$IN" 2>/dev/null | \
        awk -F, 'NR==1{printf "fp=%s fd=%s\n", $1, $2} END{if(NR==0) print "fp=na fd=na"}')"
TB=$(ffp1 -v error -select_streams v:0 -show_entries stream=time_base -of default=nw=1:nk=1 "$IN" 2>/dev/null)
TICK=${TB##*/}; case "$TICK" in ''|*[!0-9]*) TICK=90000;; esac
if [ "$fp" != na ] && [ "$fp" != N/A ] && [ "$fd" != na ] && [ "$fd" != N/A ]; then
  FLOOR=$(awk "BEGIN{printf \"%.6f\", (($fp)-($fd))/$TICK}")
else
  FLOOR=unknown
fi
ST_SRC=$(ffp1 -v error -show_entries format=start_time -of default=nw=1:nk=1 "$IN" 2>/dev/null)
echo "   source start_time: ${ST_SRC:-?}s; first video packet pts=$fp dts=$fd (tickrate $TICK)"
if [ "$FLOOR" = unknown ]; then
  echo "   floor: unknown (first video packet carries no timestamps — the missing-ts class"
  echo "   rides through a TS->TS copy unchanged; the muxer decides the exact start)"
else
  echo "   FLOOR: the VIDEO track cannot start below ${FLOOR}s (its first frame's reorder"
  echo "   delay — MPEG-TS cannot hold negative DTS). format.start_time lands at the"
  echo "   earliest stream start (audio with no reorder delay can sit slightly under the"
  echo "   video floor), never at 0.000000 while B-frames are in flight. Players rebase"
  echo "   it away — the player clock will read 0. Printing zero in ffprobe would require"
  echo "   inventing DTS: refused on doctrine."
fi

# --- layout, then the prediction contract -----------------------------------------
# layout FIRST: the pre-pass is a true dry run of the build (1.15.2 Defect B)
# and needs RW_STREAMID_OPTS/RW_MUX_OPTS on its command line.
rewrap_layout "$IN"
echo "   layout: $RW_LAYOUT_NOTE"
echo "-- prediction pre-pass (true dry run: same mpegts mux, bytes discarded) --"
PRED=$(rewrap_predict "$IN")
if [ "${PRED:-0}" -gt 0 ]; then
  echo "   predicted: $PRED DTS monotonicity-collision site(s). Expected artifact set:"
  echo "   one +1-tick DTS nudge per site (the measured CLI-filled-PAFF-mate class;"
  echo "   presentation timestamps untouched). The build's mux log must observe EXACTLY"
  echo "   this count — any surprise is a verdict."
else
  echo "   predicted: 0 collision sites — the mux log must stay nudge-free."
fi

# --- build ------------------------------------------------------------------------
trap 'rm -rf "$TMP"; rtm_unlock' EXIT   # re-armed: TMP cleanup + writer-lock release (WO-1.15.6 A2)
rtm_writer_preflight "$OUT" "$IN" || exit 2
PART="$(rtm_part "$OUT")"
MUXLOG="$TMP/mux.log"
if ! ffmpeg -nostdin -y -hide_banner -nostats -v warning "${FF_INPUT_OPTS[@]}" -i "$IN" \
      -map 0 -c copy -muxdelay 0 -muxpreload 0 \
      ${RW_STREAMID_OPTS[@]+"${RW_STREAMID_OPTS[@]}"} \
      ${RW_MUX_OPTS[@]+"${RW_MUX_OPTS[@]}"} \
      -f mpegts "$PART" 2>"$MUXLOG"; then
  echo ">> build FAILED:"; sed 's/^/   /' "$MUXLOG" | tail -8; rm -f "$PART"; exit 1
fi
HARD=$(rewrap_hard_confessions "$MUXLOG")
OBS=$(rewrap_nudges "$MUXLOG")
if [ "${HARD:-0}" -gt 0 ]; then
  echo ">> HARD STOP: the mux log confesses invented timing ($HARD line(s) of the" >&2
  echo "   'pts has no value'/'Timestamps are unset' class). NOT blessing; evidence" >&2
  echo "   kept at $PART and $MUXLOG. Route: scripts/diagnose.sh." >&2
  cp "$MUXLOG" "$PART.muxlog" 2>/dev/null || true
  exit 1
fi
if [ "${OBS:-0}" -ne "${PRED:-0}" ]; then
  echo ">> FAIL: prediction contract breached — predicted $PRED nudge site(s), the mux" >&2
  echo "   observed $OBS. An unexplained timeline artifact must not ship. Evidence kept" >&2
  echo "   at $PART; mux log at $PART.muxlog." >&2
  cp "$MUXLOG" "$PART.muxlog" 2>/dev/null || true
  exit 1
fi
echo "   mux: observed nudges=$OBS == predicted $PRED; hard confessions: 0"

# POST-MUX CENSUS (D5): plan = every source stream, codec-identical
ZB_C=$(ffp -v error -show_entries stream=index,codec_name -of csv=p=0 "$IN" 2>/dev/null | \
       awk -F, 'NF{ if(seen[$1]++) next; printf "%s%s", s, $2; s="," }')
ZB_N=$(printf '%s' "$ZB_C" | awk -F, '{print ($0=="" ? 0 : NF)}')
census_rc=0
mux_census "$PART" "$ZB_N" "$ZB_C" zero-base "$IN" || census_rc=$?
if [ "$census_rc" -ne 0 ] && [ "$census_rc" -ne 10 ]; then
  echo "   NOT blessing; kept at $PART." >&2
  exit 1
fi

# --- prove it (verify-source: the same scanner that pre-flighted the source) ------
echo "-- verification battery (verify-source.sh) --"
set +e
bash "$SELF_DIR/verify-source.sh" "$IN" "$PART" --src-tsh "$TMP/src.tsh"
vrc=$?
set -e
case "$vrc" in
  0)  VERDICT=ok;;
  10) VERDICT=review;;
  *)  echo ">> verification FAILED (rc=$vrc). NOT blessing; evidence kept at $PART." >&2; exit 1;;
esac
# an unexpected-surplus census (rc 10) blesses the complete build but demotes
# the verdict to REVIEW — the trim-to-idr propagation rule
[ "$census_rc" -eq 10 ] && VERDICT=review

mv -f "$PART" "$OUT"
ST_OUT=$(ffp1 -v error -show_entries format=start_time -of default=nw=1:nk=1 "$OUT" 2>/dev/null)
echo "wrote: $OUT"
echo "   start_time: ${ST_SRC:-?}s -> ${ST_OUT:-?}s (floor ${FLOOR}s); essence byte-identical,"
echo "   PID/program layout preserved. The source is untouched and remains the original."
echo "ZB_SUMMARY out=$OUT start_src=${ST_SRC:-na} start_out=${ST_OUT:-na} floor=$FLOOR predicted_nudges=${PRED:-0} observed_nudges=${OBS:-0} verdict=$VERDICT"
[ "$VERDICT" = review ] && exit 10
exit 0

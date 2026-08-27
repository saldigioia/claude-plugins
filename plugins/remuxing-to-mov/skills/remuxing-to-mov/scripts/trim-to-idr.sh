#!/usr/bin/env bash
# trim-to-idr.sh — PERFORM the lossless mid-GOP-start trim the toolset already
# prescribes. A capture that joins a broadcast mid-GOP opens with pre-roll
# packets before its first IDR: their reference frames and parameter sets were
# never captured, so NO player can decode them (players conceal). Worse, the
# pre-roll doesn't even survive a copy mux honestly: ffmpeg's streamcopy
# silently DROPS initial non-keyframe VIDEO packets (the -copyinkf default)
# while every AUDIO pre-roll packet lands — measured on the late-sps fixture:
# 102 video packets vanished from the mux with no warning, audio kept its full
# span, and verify's duration-parity gate then flagged a phantom "gap-collapse
# desync" at 4.25 s (a REVIEW caused by the head of the file, not by gaps).
# ts-health.sh has always PRESCRIBED "lossless trim at the first IDR" for this
# class, and gop-probe.sh could already validate the boundary — but no bundled
# script PERFORMED it, so the skill's own no-hand-rolled-ffmpeg rule left the
# operator stranded (the hole that forced manual work on the BBC file). This
# script closes the diagnose -> validate -> APPLY gap.
#
# What it does (copy-only; the source is never touched, video never re-encoded):
#   1. locate the first keyframe-flagged video packet — windowed demux scan
#      (RTM_IDR_WINDOW video packets, default 5000), every probe through the
#      lib-probe.sh raised window (this class often IS the late-SPS class);
#   2. prove the boundary is a FULL sync point via gop-probe.sh (closed GOP /
#      IDR). The one decode-heavy step: gop-probe reads the video frame table.
#      An open-GOP boundary REFUSES (exit 1): trimming to a partial sync point
#      just relocates the garbage, and advancing to the next closed keyframe
#      would drop DECODABLE frames — curation this tool has no mandate for
#      (that call is the operator's: references/cutting-concat.md, smart-cut);
#   3. copy-cut BOTH tracks together: -ss <relative> BEFORE -i, all streams
#      mapped, -c copy. ORIGIN of the seek value (WO 1.3, measured): -ss before
#      -i is relative to the container's start_time, NOT absolute stream PTS —
#      on a start_time=7.23 capture, the IDR observed at PTS 11.48 is cut with
#      -ss 4.25; passing 11.48 itself would seek ~4 s past the intended point
#      (or beyond EOF). Cutting both tracks at one point is what restores A/V
#      parity — the silent ffmpeg drop removes video only and leaves the skew.
#   4. gate before blessing (atomic .part -> mv only after ALL gates):
#      (a) the first output video packet is keyframe-flagged AND byte-sized
#          exactly like the source IDR packet (same coded AU — catches a seek
#          that landed on the wrong keyframe, which a bare "starts on a key"
#          check would wave through);
#      (b) ts-health.sh's own counter reads 0 pre-keyframe packets (the exact
#          counter that diagnosed the finding — no parallel arithmetic);
#      (c) output duration == source duration minus the trim (±1.5 s).
#
# Kept-region losslessness: everything at/after the first IDR is stream-copied,
# byte-identical (the regression suite proves it per-packet with framecrc).
# The trim removes ONLY the undecodable pre-roll — it loses nothing any player
# could ever have shown.
#
# Usage: scripts/trim-to-idr.sh INPUT OUTPUT
#   OUTPUT stays in the source's container family: give it the source's own
#   extension (capture.ts -> trimmed.ts) so ffmpeg infers the same muxer.
#   Standalone tool AND mov.sh's auto step (mov.sh runs it, announced, when its
#   pre-flight sees pre-roll; mov.sh --no-idr-trim skips it).
# Exit: 0 = trimmed + gated OK, or nothing to trim (says so, writes nothing);
#       1 = FAIL (unsafe boundary / cut missed / gate failed); 2 = usage.
# Machine-readable: TTI_SUMMARY prekey=<n> idr_pts=<s> ss_rel=<s> out=<path>
#   (out=none when nothing was trimmed; fields are stable API — extend only).
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-exit.sh"   # exit-code contract trap (WO 1.4): no stray code escapes

# NOTE no apostrophes in the :? messages: inside ${1:?...} bash 3.2 treats a
# quote as a quote OPENER and swallows the following lines into the message
# (measured here: the OUT assignment below silently vanished).
IN="${1:?usage: trim-to-idr.sh INPUT OUTPUT (give OUTPUT the same extension as the input, e.g. trimmed.ts)}"
OUT="${2:?need OUTPUT (same container family as the input, e.g. trimmed.ts)}"
[ $# -le 2 ] || { echo "unknown opt: $3" >&2; exit 2; }
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }
[ "$(cd "$(dirname "$IN")" && pwd)/$(basename "$IN")" != "$(cd "$(dirname "$OUT")" 2>/dev/null && pwd)/$(basename "$OUT")" ] \
  || { echo "refusing to overwrite the source in place" >&2; exit 2; }
. "$SELF_DIR/lib-probe.sh"  # ffp/FF_INPUT_OPTS: raised probe window on every input open
. "$SELF_DIR/lib-paff.sh"   # probe_shaped_failure / probe_retry_notice / FF_RETRY_OPTS
. "$SELF_DIR/lib-mux.sh"    # mux_census (D5); the part name here already kept its extension (1.9)

WINDOW="${RTM_IDR_WINDOW:-5000}"

echo "== trim-to-idr: $IN -> $OUT =="

# --- 1. first keyframe-flagged video packet (windowed, demux-only) --------------
# Fields by ffprobe's fixed section order: pts_time,dts_time,size,flags. The awk
# consumes to EOF — an early exit would SIGPIPE ffprobe under pipefail (the
# make-fixtures lesson) — and every counter is +0-guarded (the remux.sh:69
# uninitialized-n POSIX-awk trap).
eval "$(ffp -v error -select_streams v:0 -read_intervals "%+#$WINDOW" \
          -show_entries packet=pts_time,dts_time,size,flags -of csv=p=0 "$IN" 2>/dev/null | \
        awk -F, '
          NF>=4 && !found {
            if (index($4,"K")) { found=1; kpts=$1; kdts=$2; ksize=$3 }
            else pre++
          }
          { tot++ }
          END { printf "tti_tot=%d tti_found=%d tti_pre=%d tti_kpts=%s tti_kdts=%s tti_ksize=%s\n", \
                  tot+0, found+0, pre+0, (found?kpts:"na"), (found?kdts:"na"), (found?ksize:"na") }')"
if [ "${tti_tot:-0}" -eq 0 ]; then
  echo "no video packets found in $IN (not a coded video source?)" >&2; exit 2
fi
if [ "${tti_found:-0}" -eq 0 ]; then
  echo ">> FAIL: no keyframe in the first $tti_tot video packets (window $WINDOW)." >&2
  echo "   Either raise RTM_IDR_WINDOW, or this is the single-GOP/unseekable class —" >&2
  echo "   ts-health.sh names it; no lossless trim target exists in reach." >&2
  exit 1
fi
if [ "${tti_pre:-0}" -eq 0 ]; then
  echo "   first video packet is already keyframe-flagged — nothing to trim."
  echo "TTI_SUMMARY prekey=0 idr_pts=${tti_kpts:-na} ss_rel=none out=none"   # machine-readable
  exit 0
fi
IDR_PTS="${tti_kpts:-na}"
if [ "$IDR_PTS" = "N/A" ] || [ -z "$IDR_PTS" ]; then IDR_PTS="${tti_kdts:-na}"; fi
if [ "$IDR_PTS" = "N/A" ] || [ -z "$IDR_PTS" ] || [ "$IDR_PTS" = na ]; then
  echo ">> FAIL: the first keyframe packet carries no timestamp at all — the" >&2
  echo "   missing-timestamp class. Repair the timestamps FIRST (diagnose.sh routes by" >&2
  echo "   measured profile: pairfill-paff.sh for half-timestamped H.264 PAFF /" >&2
  echo "   derive-dts.sh for PTS-complete reordered, any codec / remux.sh --genpts" >&2
  echo "   otherwise), then re-run the trim." >&2
  exit 1
fi
echo "   mid-GOP head: $tti_pre pre-keyframe packet(s); first keyframe @ ${IDR_PTS}s (packet size ${tti_ksize:-0} B)"

# --- 2. boundary proof: closed GOP / full sync (gop-probe.sh) -------------------
set +e; gpo=$(bash "$SELF_DIR/gop-probe.sh" "$IN" "$IDR_PTS" 2>&1); gprc=$?; set -e
printf '%s\n' "$gpo" | sed 's/^/   /'
if [ "$gprc" -ne 0 ]; then
  if [ "$gprc" -eq 10 ]; then
    echo ">> FAIL: the first keyframe is an OPEN-GOP boundary (partial sync), not an" >&2
    echo "   IDR — a trim here relocates the garbage instead of removing it, and" >&2
    echo "   advancing to the next closed keyframe would drop DECODABLE frames." >&2
    echo "   That trade is the operator's call, not this tool's:" >&2
    echo "   references/cutting-concat.md (smart-cut / manual closed-GOP cut)." >&2
  else
    echo ">> FAIL: gop-probe.sh could not prove the boundary (rc=$gprc, output above)." >&2
  fi
  exit 1
fi

# --- 3. copy-cut both tracks at the IDR -----------------------------------------
# -ss is relative to container start_time (WO 1.3 — see header); clamp at 0.
ST=$(ffp -v error -show_entries format=start_time -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
case "$ST" in ''|N/A) ST=0; echo "   note: container reports no start_time — treating it as 0";; esac
REL=$(awk "BEGIN{r=($IDR_PTS)-($ST); if(r<0)r=0; printf \"%.6f\", r}")
SRC_DUR=$(ffp -v error -show_entries format=duration -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
case "$SRC_DUR" in ''|N/A) SRC_DUR="";; esac
echo "   copy-cut: -ss $REL (relative: IDR pts $IDR_PTS - start_time $ST) — all streams, -c copy"
# atomic part-file, but with the REAL extension kept ("x.part….ts", not "x.ts.part"):
# this tool is container-agnostic, so the muxer is inferred from the extension —
# a bare ".part" makes ffmpeg refuse ("Unable to choose an output format", measured).
# WO-1.15.6: the 1.9-era inline name converts to rtm_part — same extension
# discipline, now unique per process like every other builder (A2).
trap 'rtm_unlock' EXIT   # writer-lock release however this run ends (WO-1.15.6 A2)
rtm_writer_preflight "$OUT" "$IN" || exit 2
PART="$(rtm_part "$OUT")"
CUTLOG="$(mktemp)"
cut_mux () {  # cut_mux INPUT_OPT... — one attempt; only the probe window varies (WO 1.2)
  ffmpeg -nostdin -y -hide_banner -nostats -ss "$REL" "$@" -i "$IN" \
    -map 0 -c copy -avoid_negative_ts make_zero "$PART" 2>"$CUTLOG"
}
if ! cut_mux "${FF_INPUT_OPTS[@]}"; then
  # probe-shaped failure = window undershot, not a source defect -> retry ONCE at
  # 1G (lib-paff.sh, WO 1.2); anything else fails now (contract: 1 FAIL)
  if probe_shaped_failure "$CUTLOG"; then
    probe_retry_notice
    cut_mux "${FF_RETRY_OPTS[@]}" || { echo ">> copy-cut FAILED (after 1G retry):"; sed 's/^/   /' "$CUTLOG" | tail -8; rm -f "$PART"; exit 1; }
  else
    echo ">> copy-cut FAILED:"; sed 's/^/   /' "$CUTLOG" | tail -8; rm -f "$PART"; exit 1
  fi
fi
rm -f "$CUTLOG"

# --- 4. gates: bless only what is proven ------------------------------------------
# (a) first output video packet = keyframe-flagged AND the source IDR's exact
#     byte size (same coded AU — a seek that landed on the WRONG keyframe would
#     still "start on a key"; the size match pins it to THE first IDR). An
#     empty cut means -ss overshot EOF: the WO 1.3 guard class — meaningless,
#     so the .part does not survive it (atomic rule).
eval "$(ffp -v error -select_streams v:0 -read_intervals '%+#1' \
          -show_entries packet=size,flags -of csv=p=0 "$PART" 2>/dev/null | \
        awk -F, 'NR==1{printf "o_size=%s o_key=%d\n", $1, (index($2,"K")>0)} END{if(NR==0) print "o_size=0 o_key=0"}')"
if [ ! -s "$PART" ] || [ "${o_size:-0}" = 0 ]; then
  rm -f "$PART"
  echo ">> FAIL: cut produced no video (-ss beyond end of file? --ss is relative to start_time=$ST, not absolute PTS)" >&2
  exit 1
fi
if [ "${o_key:-0}" -ne 1 ] || [ "$o_size" != "${tti_ksize:-0}" ]; then
  echo ">> FAIL: cut did not land on the source's first IDR (first output packet:" >&2
  echo "   key=$o_key size=${o_size}B, want key=1 size=${tti_ksize:-0}B). NOT blessing;" >&2
  echo "   evidence kept at $PART." >&2
  exit 1
fi
# (b) the ts-health counter itself must read 0 pre-keyframe packets — the same
#     counter that diagnosed the finding proves the fix (whole-file, demux-only).
set +e; thkv=$(bash "$SELF_DIR/ts-health.sh" "$PART" --kv 2>/dev/null); thrc=$?; set -e
OUT_PREKEY=$(printf '%s\n' "$thkv" | sed -n 's/^TSH_PREKEY=//p' | head -1)
if [ -z "$OUT_PREKEY" ]; then
  echo ">> FAIL: ts-health.sh could not scan the cut (rc=$thrc). NOT blessing; kept at $PART." >&2
  exit 1
fi
if [ "$OUT_PREKEY" -ne 0 ]; then
  echo ">> FAIL: $OUT_PREKEY pre-keyframe packet(s) leaked into the cut (ts-health" >&2
  echo "   counter; the seek landed before the IDR). NOT blessing; evidence kept" >&2
  echo "   at $PART." >&2
  exit 1
fi
echo "   gates: first packet = the source IDR (key, ${o_size}B); ts-health pre-keyframe count = 0"
# (c) duration sanity: the cut should be source-minus-trim; a breach means the
#     seek snapped somewhere else entirely (e.g. a whole GOP early/late).
if [ -n "$SRC_DUR" ]; then
  OUT_DUR=$(ffp -v error -show_entries format=duration -of default=nw=1:nk=1 "$PART" 2>/dev/null | head -1)
  case "$OUT_DUR" in ''|N/A) OUT_DUR="";; esac
  if [ -n "$OUT_DUR" ]; then
    if ! awk "BEGIN{d=($OUT_DUR)-(($SRC_DUR)-($REL)); if(d<0)d=-d; exit !(d<=1.5)}"; then
      echo ">> FAIL: cut duration ${OUT_DUR}s vs expected ~$(awk "BEGIN{printf \"%.3f\", ($SRC_DUR)-($REL)}")s" >&2
      echo "   (source ${SRC_DUR}s - trim ${REL}s; tolerance 1.5s). NOT blessing; kept at $PART." >&2
      exit 1
    fi
    echo "   duration: ${OUT_DUR}s (source ${SRC_DUR}s - trimmed ${REL}s)"
  fi
fi

# POST-MUX CENSUS (D5, 1.13): this cut maps `0` — EVERY source stream must come
# out the other side, or the "both tracks, A/V parity kept" promise is void and
# the downstream build inherits a quietly narrower file as its "source".
TTI_C=$(ffp -v error -show_entries stream=index,codec_name -of csv=p=0 "$IN" 2>/dev/null | \
        awk -F, 'NF{ if(seen[$1]++) next; printf "%s%s", s, $2; s="," }')
TTI_N=$(printf '%s' "$TTI_C" | awk -F, '{print ($0=="" ? 0 : NF)}')
census_rc=0
mux_census "$PART" "$TTI_N" "$TTI_C" trim-to-idr "$IN" || census_rc=$?
if [ "$census_rc" -ne 0 ] && [ "$census_rc" -ne 10 ]; then
  echo "   NOT blessing the cut; kept at $PART." >&2
  exit 1
fi
mv -f "$PART" "$OUT"
echo "wrote: $OUT"
echo "   kept region: every packet at/after the IDR, stream-copied byte-identical;"
echo "   removed: ONLY the undecodable pre-roll, from BOTH tracks (A/V parity kept)."
echo "   Verify any downstream .mov against THIS file, not the untrimmed capture."
echo "TTI_SUMMARY prekey=${tti_pre:-0} idr_pts=$IDR_PTS ss_rel=$REL out=$OUT"   # machine-readable
# REVIEW propagation (1.14): an unexpected-surplus census blesses the complete
# cut and exits 10 ("look"), never 1 — nothing planned is missing.
exit "$census_rc"

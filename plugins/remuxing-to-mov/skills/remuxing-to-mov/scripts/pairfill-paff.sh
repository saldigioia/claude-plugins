#!/usr/bin/env bash
# pairfill-paff.sh — Rung 3-PAIR: repair a half-timestamped field-coded (PAFF)
# H.264 timeline by KEEPING every real PTS and filling each pair-mate.
#
# The stream class (proven on real broadcast captures, post-mortem 2026-07-25):
# field-coded H.264 in MPEG-TS where only the FIRST field of each frame pair
# carries PES timestamps — the second field of every pair has no PTS and no DTS.
# A straight copy hands those packets to the MOV muxer, which INVENTS timing
# (1-tick durations, PTS in decode order, negative DTS): bits perfect, timeline
# garbage. A constant-rate restamp (rebuild-paff.sh) is ALSO wrong here when the
# stream carries a B-field reorder pyramid — it sets PTS=DTS and plays fields in
# decode order (motion shuffled).
#
# The correct, fully-derivable repair: every untimestamped field is the pair-mate
# of the timestamped field before it, and its true PTS is exactly +1 field
# duration. So: keep every real PTS (which carries the reorder pyramid), fill
# each pair-mate at +1 field, synthesize a clean monotonic DTS ramp anchored to
# the first real PTS, copy the video bits untouched.
#
# Usage: scripts/pairfill-paff.sh INPUT OUTPUT.mov [--rate FRAC] [--preroll TICKS]
#   --rate    field rate override (e.g. 60000/1001) when detection can't map one
#   --preroll DTS pre-roll in stream ticks (default: measured max PTS-DTS offset,
#             rounded up to a whole pair; the reorder pyramid depth)
#
# PRECONDITIONS (checked against the WHOLE file; any miss aborts with exit 3):
#   1. the first video packet carries a real PTS (the fill anchors to it);
#   2. untimestamped packets never occur back-to-back (strict pair alternation —
#      each one's mate is the timestamped packet immediately before it);
#   3. the stream timebase and field rate yield whole-tick pair durations
#      (90 kHz @ 59.94 -> 1501/1502; @ 50 -> 1800/1800).
#
# setts LESSONS BAKED IN (each cost a broken build in the incident):
#   * unset timestamps reach setts expressions as INT64_MIN, NOT NaN — test
#     lt(PTS,-8e18), never isnan(); an isnan() filter silently does nothing and
#     writes the broken file again with exit 0.
#   * DTS expressions must be DOMAIN-RELATIVE: anchor the ramp to the first real
#     PTS (PTS-preroll), never to absolute source-clock values — ffmpeg rebases
#     PTS near zero and discards out-of-domain DTS, and the muxer guesses again.
#   * therefore this script verifies the OUTPUT's timestamps, never the command's
#     exit code: N/A-PTS count 0, DTS strictly monotonic, duration histogram of
#     exactly the two field durations — gates run BEFORE the output is blessed.
#
# Audio: original preserved bit-exact + PCM access track when the codec is not
# QuickTime-native (AC-3/DTS/MP2), single copy when it is (AAC/E-AC-3/...).
# Video is ALWAYS -c:v copy. Source never touched; output atomic (.part -> mv).
# Requires the setts bitstream filter with PREV_OUTPTS/PREV_OUTDTS expression
# variables (ffmpeg >= 5.x; scripts/doctor.sh reports setts availability).
# Exit: 0 verified-clean; 1 built but timeline gates failed; 2 usage; 3 stream
# does not match the pairfill signature (use diagnose.sh to pick the right rung);
# 11 refused by the backhaul gate (QT-undecodable profile — no .mov route).
set -euo pipefail
IN="${1:?usage: pairfill-paff.sh INPUT OUTPUT.mov [--rate FRAC] [--preroll TICKS]}"
OUT="${2:?need OUTPUT.mov}"; shift 2
RATE=""; PREROLL=""
while [ $# -gt 0 ]; do case "$1" in
  --rate)    RATE="${2:?--rate needs a value}"; shift 2;;
  --preroll) PREROLL="${2:?--preroll needs a value}"; shift 2;;
  *) echo "unknown opt: $1" >&2; exit 2;;
esac; done
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }
[ "$(cd "$(dirname "$IN")" && pwd)/$(basename "$IN")" != "$(cd "$(dirname "$OUT")" 2>/dev/null && pwd)/$(basename "$OUT")" ] \
  || { echo "refusing to overwrite the source in place" >&2; exit 2; }
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-paff.sh"

# backhaul refusal gate (exit 11, nothing written) — this script writes a .mov,
# so the QT-undecodability criteria hold even on a direct call; a gated caller
# (mov.sh/auto.sh) exports RTM_BACKHAUL_GATED=1 and skips it.
backhaul_gate "$IN" || exit $?

echo "== pairfill: $IN -> $OUT =="
eval "$(pf_detect "$IN")"
[ "$PF_CODEC" = h264 ] || { echo "not H.264 (codec=$PF_CODEC) — pairfill is an H.264 PAFF repair." >&2; exit 3; }
[ "$PF_PAFF" = yes ] || echo "   note: rate test reads paff=$PF_PAFF — proceeding anyway (caller's call)."
echo "   coded-pic rate=${PF_CODED_RATE}/s  untimestamped fraction=${PF_NOPTS_FRAC} (half_ts=$PF_HALF_TS)"

# --- field rate -> whole-tick pair duration in the stream timebase ---
[ -n "$RATE" ] || RATE="$PF_FIELD_RATE"
if [ "$RATE" = unknown ] || [ -z "$RATE" ]; then
  echo "cannot map a field rate (measured ${PF_CODED_RATE}/s); pass --rate, e.g. 60000/1001" >&2; exit 3
fi
TB=$(ffprobe -v error -select_streams v:0 -show_entries stream=time_base -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
TBDEN=${TB##*/}; case "$TBDEN" in ''|*[!0-9]*) echo "unusable stream time_base '$TB'" >&2; exit 3;; esac
RN=${RATE%%/*}; RD=${RATE##*/}; [ "$RN" = "$RATE" ] && RD=1   # "50" -> 50/1
read -r PAIR A B <<EOF
$(awk "BEGIN{p=$TBDEN*2*$RD/$RN; ip=int(p+0.5);
  if(p-int(p)>1e-9 && int(p)+1-p>1e-9){print \"x x x\"; exit}
  a=int(ip/2); printf \"%d %d %d\", ip, a, ip-a}")
EOF
[ "$PAIR" != x ] || { echo "timebase 1/$TBDEN at field rate $RATE gives a non-integer pair duration — remux via a 90 kHz carrier first, or pick another repair." >&2; exit 3; }
AB=$((B - A))
echo "   timebase=1/$TBDEN  field rate=$RATE  pair=${PAIR} ticks (fields ${A}/${B})"

# --- whole-file precondition scan (demux only): first-PTS, strict alternation,
#     the measured reorder depth (max PTS-DTS) for the DTS pre-roll, and the
#     PTS excursion vs a pair-cadence ramp (QTFF audit 5-4d / C67): each
#     timestamped packet advances one pair, so PTS minus (first_PTS + i*PAIR)
#     measures how far the reorder pyramid pushes presentation ahead of the
#     cadence — the exact amount the output's PTS-DTS offsets will exceed the
#     pre-roll by (the filled DTS ramp is uniform; the kept real PTS are not) ---
eval "$(ffprobe -v error -select_streams v:0 -show_entries packet=pts,dts -of csv=p=0 "$IN" 2>/dev/null | \
  awk -F, -v pair="$PAIR" 'NF{
      n++; p=$1; d=$2
      unset=(p=="N/A"||p=="")
      if(n==1) first_ok=(unset?0:1)
      if(unset){ miss++; run++; if(run>mxrun) mxrun=run } else run=0
      if(!unset){ if(ti==0) fp=p+0; exc=(p+0)-(fp+ti*pair); if(exc>emax)emax=exc; if(exc<emin)emin=exc; ti++ }
      if(!unset && d!="N/A" && d!=""){ both++; off=p-d; if(off>mxoff) mxoff=off }
    }
    END{ printf "PP_N=%d PP_FIRST_OK=%d PP_MISS=%d PP_MAXRUN=%d PP_BOTH=%d PP_MAXOFF=%d PP_EXC=%d PP_EXC_MIN=%d\n",
         n+0, first_ok+0, miss+0, mxrun+0, both+0, mxoff+0, emax+0, emin+0 }')"
echo "   packets=$PP_N  untimestamped=$PP_MISS  max consecutive untimestamped=$PP_MAXRUN  max PTS-DTS=$PP_MAXOFF ticks"
# bash 3.2 can't parse $(cmd "...\"...\"...") inside a double-quoted string — precompute
EXC_PAIRS=$(awk "BEGIN{printf \"%.2f\", ${PP_EXC:-0}/$PAIR}")
echo "   PTS excursion vs pair-cadence ramp: +${PP_EXC}/${PP_EXC_MIN} ticks ($EXC_PAIRS pairs of pyramid depth)"
[ "${PP_N:-0}" -gt 0 ] || { echo "no video packets read" >&2; exit 3; }
[ "${PP_FIRST_OK:-0}" -eq 1 ] || { echo ">> PRECONDITION FAIL: first video packet has no PTS — nothing to anchor the fill to. Use rebuild-paff.sh (no real timing survives to preserve)." >&2; exit 3; }
[ "${PP_MAXRUN:-9}" -le 1 ] || { echo ">> PRECONDITION FAIL: $PP_MAXRUN consecutive untimestamped packets — not strict pair alternation; the +1-field fill would be wrong. Diagnose by hand (references/timeline-repair.md)." >&2; exit 3; }

# --- DTS pre-roll: the pyramid depth, rounded up to whole pairs ---
if [ -z "$PREROLL" ]; then
  if [ "${PP_BOTH:-0}" -gt 0 ] && [ "${PP_MAXOFF:-0}" -gt 0 ]; then
    PREROLL=$(awk "BEGIN{printf \"%d\", int(($PP_MAXOFF+$PAIR-1)/$PAIR)*$PAIR}")
  else
    PREROLL=$((5 * PAIR))   # no DTS in the source to measure: 5 frames covers a deep pyramid
  fi
fi
[ "$PREROLL" -ge "$PAIR" ] || PREROLL=$PAIR
# --- derived PTS-DTS bound (QTFF audit 5-4d, gate 4 approved 2026-07-26): the
# output's max(PTS-DTS) is structurally PREROLL + the source's positive pair-ramp
# excursion (a legitimate hierarchical-B pyramid's presentation lead), so the
# old fixed PREROLL+PAIR limit refused valid >=2-level pyramids (C67; XLVI:
# 36036 > 30030 with no flag that could satisfy it). Revised bound:
#   max(PTS-DTS) <= PREROLL + min(measured excursion, 16 pairs) + 1 pair
# floored at PREROLL+PAIR — a zero-excursion (simple) stream keeps EXACTLY the
# old limit, and the 16-pair clamp keeps a pathological measurement from ever
# opening the gate to a runaway ramp (the C05 wrong-cadence class stays refused
# by this clamp AND the unchanged 2-pair span-skew gate).
EXCC=${PP_EXC:-0}
[ "$EXCC" -ge 0 ] || EXCC=0
[ "$EXCC" -le $((16 * PAIR)) ] || EXCC=$((16 * PAIR))
MAXOFF_LIMIT=$((PREROLL + EXCC + PAIR))
echo "   DTS pre-roll=$PREROLL ticks; derived max(PTS-DTS) bound=$MAXOFF_LIMIT (preroll + excursion $EXCC + 1 pair)"

# --- audio: preserve the original where QuickTime needs help (dual-track) ---
# a:0 only. A source with MORE audio tracks (SAP/secondary/commentary) loses
# them here — say so LOUDLY instead of dropping them silently (QTFF audit 5a).
NAUD=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$IN" 2>/dev/null | sort -u | grep -c . || true)
if [ "${NAUD:-0}" -gt 1 ]; then
  echo "** WARNING: source has $NAUD audio tracks; pairfill carries ONLY a:0."
  echo "**          Secondary/SAP tracks are NOT in the output. Extract and remux"
  echo "**          them separately, or run the manual pairfill mux with extra"
  echo "**          -map 0:a:N entries (references/timeline-repair.md, Rung 3-PAIR)."
fi
acodec=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1 || true)
alang=$(ffprobe -v error -select_streams a:0 -show_entries stream_tags=language -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1 || true)
case "$alang" in ""|und|unknown) alang=eng;; esac
DRC=(); case "$acodec" in ac3|eac3) DRC=(-drc_scale 0);; esac
AARGS=()
case "$acodec" in
  "") echo "   audio: none";;
  aac|alac|mp3|pcm_*|eac3)
    echo "   audio: $acodec is QuickTime-native -> single copied track"
    AARGS=(-map 0:a:0 -c:a copy -metadata:s:a:0 language="$alang");;
  ac3|dts|dca|mp2|mp1)
    echo "   audio: $acodec not QuickTime-native -> dual-track (PCM access + original bit-exact)"
    AARGS=(-map 0:a:0 -map 0:a:0 -c:a:0 pcm_s24le -c:a:1 copy
           -disposition:a:0 default -disposition:a:1 0
           -metadata:s:a:0 title="PCM 24-bit (access)" -metadata:s:a:0 language="$alang"
           -metadata:s:a:1 title="$(echo "$acodec" | tr a-z A-Z) (original)" -metadata:s:a:1 language="$alang");;
  *)
    echo "   audio: $acodec not MOV-copyable -> single PCM access track (original kept only in the source)"
    AARGS=(-map 0:a:0 -c:a pcm_s24le -metadata:s:a:0 language="$alang");;
esac

cprim=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_primaries -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1 || true)
MOVFLAGS="+faststart"; { [ -n "$cprim" ] && [ "$cprim" != unknown ]; } && MOVFLAGS="+faststart+write_colr"

# The repair itself. lt(x,-8e18) is the unset test (INT64_MIN, not NaN); the DTS
# ramp anchors to the FIRST REAL PTS (domain-relative) and alternates A/B ticks.
SETTS="setts=pts=if(lt(PTS\,-8000000000000000000)\,PREV_OUTPTS+${A}\,PTS):dts=if(lt(PREV_OUTDTS\,-8000000000000000000)\,PTS-${PREROLL}\,PREV_OUTDTS+${A}+${AB}*mod(N\,2))"
PART="${OUT}.part"; MUXLOG="$(mktemp)"
echo "-- muxing (video bits copied untouched; timeline pair-filled) --"
if ! ffmpeg -nostdin -y -hide_banner -nostats ${DRC[@]+"${DRC[@]}"} -i "$IN" \
    -map 0:v:0 ${AARGS[@]+"${AARGS[@]}"} \
    -c:v copy -bsf:v "$SETTS" \
    -movflags "$MOVFLAGS" -f mov "$PART" 2>"$MUXLOG"; then
  echo ">> mux FAILED:"; sed 's/^/   /' "$MUXLOG" | tail -8
  grep -qi 'setts' "$MUXLOG" && echo "   (setts rejected the expression — this ffmpeg may lack the PREV_OUT* vars; pairfill needs ffmpeg >= 5.x)"
  echo "   partial output kept at $PART; mux log: $MUXLOG"; exit 1
fi
conf=$(mux_confessions "$MUXLOG")
if [ "${conf:-0}" -gt 0 ]; then
  echo ">> HARD STOP: the muxer logged $conf timeline confession(s) (pts has no value /"
  echo "   Timestamps are unset / non-monotonic DTS) — it invented timing despite the fill."
  grep -iE 'pts has no value|timestamps are unset|non-?monotonic dts' "$MUXLOG" | sort | uniq -c | sort -rn | head -4 | sed 's/^/   /'
  echo "   NOT blessing the output. Kept: $PART (log: $MUXLOG)"; exit 1
fi

# --- gate the OUTPUT's timeline before blessing it (never trust the exit code) ---
# Beyond N/A + monotonicity + duration histogram, two BOUNDEDNESS gates (QTFF
# audit 1b, 2026-07-25; bound revised 5-4d, 2026-07-26): a DTS ramp at the
# wrong cadence (e.g. field-rate ramp on a frame-per-packet stream) passes all
# the point checks yet writes linearly GROWING ctts offsets and a decode span
# half the presentation span — an internally inconsistent file (mdhd != sum
# stts) that still "plays". So:
#   * max(PTS-DTS) over the whole output must stay <= the DERIVED bound
#     (PREROLL + measured pyramid excursion clamped at 16 pairs + 1 pair;
#     floor PREROLL+PAIR) — fixed at one pair it refused legitimate deep
#     hierarchical-B pyramids (C67/XLVI), while the clamp + skew gate below
#     still refuse the wrong-cadence class;
#   * the decode span (last DTS - first DTS) must equal the presentation span
#     (max PTS - min PTS) within 2 pairs.
echo "-- output timeline gates (want: 0 N/A, strictly monotonic DTS, only ${A}/${B}-tick durations, bounded PTS-DTS) --"
eval "$(ffprobe -v error -select_streams v:0 -show_entries packet=pts,dts,duration -of csv=p=0 "$PART" 2>/dev/null | \
  awk -F, -v a="$A" -v b="$B" 'NF{
      n++
      if($1=="N/A"||$1==""){ nap++ } else { p=$1+0; if(!havp){mnp=mxp=p; havp=1} else {if(p<mnp)mnp=p; if(p>mxp)mxp=p} }
      if($2=="N/A"||$2==""){ nad++ } else { d=$2+0; if(!havd){fd=d} else { if(d<pd) back++; else if(d==pd) dup++ }; pd=d; havd=1
        if($1!="N/A" && $1!="" ){ off=($1+0)-d; if(off>mxo) mxo=off } }
      if($3!="N/A" && $3!=""){ h[$3]++; if($3+0!=a && $3+0!=b) od++ }
    }
    END{
      pspan=(havp?mxp-mnp:0); dspan=(havd?pd-fd:0); skew=pspan-dspan; if(skew<0)skew=-skew
      printf "PG_N=%d PG_NAPTS=%d PG_NADTS=%d PG_BACK=%d PG_DUP=%d PG_OFFHIST=%d PG_MAXOFF=%d PG_SKEW=%d\n", \
        n+0, nap+0, nad+0, back+0, dup+0, od+0, mxo+0, skew+0
    }')"
echo "   packets=$PG_N  N/A-PTS=$PG_NAPTS  N/A-DTS=$PG_NADTS  backward-DTS=$PG_BACK  duplicate-DTS=$PG_DUP  off-histogram durations=$PG_OFFHIST"
echo "   max PTS-DTS=$PG_MAXOFF (derived limit $MAXOFF_LIMIT)  presentation-vs-decode span skew=$PG_SKEW ticks (limit $((2 * PAIR)))"
gates_ok=1
[ "${PG_NAPTS:-1}" -eq 0 ] || gates_ok=0
[ "${PG_NADTS:-1}" -eq 0 ] || gates_ok=0
[ "${PG_BACK:-1}"  -eq 0 ] || gates_ok=0
[ "${PG_DUP:-1}"   -eq 0 ] || gates_ok=0
[ "${PG_OFFHIST:-9}" -le 2 ] || gates_ok=0   # first/last sample may legitimately stray
[ "${PG_MAXOFF:-999999999}" -le "$MAXOFF_LIMIT" ] || gates_ok=0
[ "${PG_SKEW:-999999999}" -le $((2 * PAIR)) ] || gates_ok=0
if [ "$gates_ok" -ne 1 ]; then
  echo ">> TIMELINE GATES FAILED — the written timeline is not the derived one."
  echo "   NOT blessing the output. Kept: $PART (log: $MUXLOG)"
  echo "   (unbounded PTS-DTS / span skew = the DTS ramp cadence does not match the"
  echo "    stream's packets-per-field — wrong --rate, or not the pair class at all;"
  echo "    rerun scripts/diagnose.sh)"
  exit 1
fi
rm -f "$MUXLOG"
mv -f "$PART" "$OUT"
echo "wrote: $OUT"
# bash 3.2 can't parse $(case ...) inside a double-quoted string — precompute
AUDFLAG=""; case "$acodec" in ac3|dts|dca|mp2|mp1) AUDFLAG=" --audio";; esac
echo "sign-off: scripts/verify.sh \"$IN\" \"$OUT\"$AUDFLAG"
echo "  (the scrub gate + A/V parity there are still required — these gates prove the"
echo "   container timeline, not the decode; a FAIL there is a defect until every gate"
echo "   is individually explained)"

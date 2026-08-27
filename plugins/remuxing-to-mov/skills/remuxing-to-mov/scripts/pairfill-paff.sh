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
#      each one's mate is the timestamped packet immediately before it).
#      WIDENED 2026-08-18 (PROVENANCE record: 23.7 GB PAFF 1080i25, 451,071
#      coded pictures, 11 junctions): a max run of exactly TWO untimestamped
#      packets is the DISPLACED-TIMESTAMP class — the PES timestamp rides the
#      SECOND field of a pair instead of the first; nothing is missing and the
#      clock never jumps. That class routes to the JUNCTION MODEL (announced):
#      a trace_headers census must prove uniform field cadence (no pic_struct
#      repeat/doubling) and the running ffmpeg's setts must carry the
#      NEXT_PTS/NEXT_DTS + PREV_IN* expression variables; the widened fill then
#      hands each displaced timestamp back to its owner and fills the vacated
#      slot one field later. Runs > 2 still refuse (exit 3), now naming the
#      recorded attestation route (lib-attest.sh precond_attest);
#   3. the stream timebase and field rate yield whole-tick pair durations
#      (90 kHz @ 59.94 -> 1501/1502; @ 50 -> 1800/1800).
#
# JUNCTION-MODEL OUTPUT GATE (in addition to every existing gate): the
# POC lattice — per IDR-delimited sequence, every picture's OUTPUT PTS must
# sit exactly on  base + POC * half_interval  with pic_order_cnt_lsb UNWRAPPED
# to full POC first (the record's local gate 2; 451,071/451,071 on-slot on the
# proving job — a figure the 1.14.0–1.15.1 gate could NOT reproduce: the
# extraction dropped the unwrap and the shipped gate false-FAILed the same
# file at 3,179/451,071 until 1.15.2 Defect D restored it, pinned by test 76).
# Any off-lattice picture is FAIL exit 1 with the artifact kept as .part.
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
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-exit.sh"   # exit-code contract trap (WO 1.4): no stray code escapes
RTM_EXIT_OK="0 1 2 3 10 11" # + this script's documented pre-contract 3 (signature REFUSED; suite-pinned)
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
. "$SELF_DIR/lib-probe.sh"  # ffp/FF_INPUT_OPTS: raised probe window on every input open
. "$SELF_DIR/lib-paff.sh"
. "$SELF_DIR/lib-mux.sh"    # rtm_part (extension-keeping atomics), mux_census (D5)
. "$SELF_DIR/lib-attest.sh" # precond_attest: recorded operator override of a precondition

# backhaul gate (1.11: advises + warns, refuses nothing — the 4:2:2 advisory
# defers to the post-build proof, rot WARNs and builds) — this script writes a
# .mov, so the advisory fires even on a direct call; a gated caller
# (mov.sh/auto.sh) exports RTM_BACKHAUL_GATED=1 and skips it.
backhaul_gate "$IN" || exit $?

echo "== pairfill: $IN -> $OUT =="
eval "$(pf_detect "$IN")"
[ "$PF_CODEC" = h264 ] || { echo "not H.264 (codec=$PF_CODEC) — pairfill is an H.264 PAFF repair." >&2; exit 3; }
[ "$PF_PAFF" = yes ] || echo "   note: rate test reads paff=$PF_PAFF — proceeding anyway (caller's call)."
echo "   coded-pic rate=${PF_CODED_RATE}/s  untimestamped fraction=${PF_NOPTS_FRAC} (half_ts=$PF_HALF_TS)"

# --- field rate -> whole-tick pair duration in the stream timebase ---
PP_ATTESTED=""   # set by any precond_attest override below; appended to PP_CENSUS
[ -n "$RATE" ] || RATE="$PF_FIELD_RATE"
if [ "$RATE" = unknown ] || [ -z "$RATE" ]; then
  # attested override (2026-08-18): the operator with independent evidence that
  # the rate TABLE is wrong for this file proceeds on the measured coded rate,
  # rounded to a whole per-second value — announced, sidecar-recorded, and the
  # whole-tick pair-duration check below still applies (evidence never skipped).
  if precond_attest pf-rate-map pairfill-paff.sh "$OUT" \
       "PF_CODED_RATE=${PF_CODED_RATE:-0}" "PF_FIELD_RATE=${PF_FIELD_RATE:-unknown}" "PF_RATIO=${PF_RATIO:-0}"; then
    PP_ATTESTED=pf-rate-map
    RATE=$(awk "BEGIN{printf \"%d\", int(${PF_CODED_RATE:-0}+0.5)}")
    [ "${RATE:-0}" -gt 0 ] 2>/dev/null || { echo "measured coded rate ${PF_CODED_RATE}/s unusable even under attestation" >&2; exit 3; }
    echo "** attested rate-map override: using the measured coded rate rounded to ${RATE}/s"
    echo "**   as the field rate (the table could not map ${PF_CODED_RATE}/s; the operator's"
    echo "**   recorded evidence decides). Every output gate below still runs."
  else
    echo "cannot map a field rate (measured ${PF_CODED_RATE}/s); pass --rate, e.g. 60000/1001" >&2
    precond_attest_route pf-rate-map pairfill-paff.sh >&2
    exit 3
  fi
fi
TB=$(ffp -v error -select_streams v:0 -show_entries stream=time_base -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
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
# PP_RUN2 (2026-08-18): the count of runs of EXACTLY two consecutive
# untimestamped packets — the junction census the widened branch announces.
# Test hook: PP_SCAN_FILE=<csv of pts,dts lines> bypasses ffprobe (the suite
# pins the branch on injected scan profiles the sandbox encoders cannot mint).
eval "$( { if [ -n "${PP_SCAN_FILE:-}" ]; then cat "$PP_SCAN_FILE"; else
             ffp -v error -select_streams v:0 -show_entries packet=pts,dts -of csv=p=0 "$IN" 2>/dev/null; fi; } | \
  awk -F, -v pair="$PAIR" 'NF{
      n++; p=$1; d=$2
      unset=(p=="N/A"||p=="")
      if(n==1) first_ok=(unset?0:1)
      if(unset){ miss++; run++; if(run>mxrun) mxrun=run } else { if(run==2) r2++; run=0 }
      if(!unset){ if(ti==0) fp=p+0; exc=(p+0)-(fp+ti*pair); if(exc>emax)emax=exc; if(exc<emin)emin=exc; ti++ }
      if(!unset && d!="N/A" && d!=""){ both++; off=p-d; if(off>mxoff) mxoff=off }
    }
    END{ if(run==2) r2++
         printf "PP_N=%d PP_FIRST_OK=%d PP_MISS=%d PP_MAXRUN=%d PP_RUN2=%d PP_BOTH=%d PP_MAXOFF=%d PP_EXC=%d PP_EXC_MIN=%d\n",
         n+0, first_ok+0, miss+0, mxrun+0, r2+0, both+0, mxoff+0, emax+0, emin+0 }')"
echo "   packets=$PP_N  untimestamped=$PP_MISS  max consecutive untimestamped=$PP_MAXRUN (2-runs: ${PP_RUN2:-0})  max PTS-DTS=$PP_MAXOFF ticks"
# bash 3.2 can't parse $(cmd "...\"...\"...") inside a double-quoted string — precompute
EXC_PAIRS=$(awk "BEGIN{printf \"%.2f\", ${PP_EXC:-0}/$PAIR}")
echo "   PTS excursion vs pair-cadence ramp: +${PP_EXC}/${PP_EXC_MIN} ticks ($EXC_PAIRS pairs of pyramid depth)"
[ "${PP_N:-0}" -gt 0 ] || { echo "no video packets read" >&2; exit 3; }
[ "${PP_FIRST_OK:-0}" -eq 1 ] || { echo ">> PRECONDITION FAIL: first video packet has no PTS — nothing to anchor the fill to. Use rebuild-paff.sh (no real timing survives to preserve)." >&2; exit 3; }
# --- fill model dispatch (2026-08-18): strict pair alternation keeps today's
# rule byte-identical; a max run of exactly 2 is the measured displaced-
# timestamp class and triggers the JUNCTION MODEL (announced; census + setts
# feature-detect below are its own preconditions); anything deeper refuses as
# before, now naming the recorded attestation route.
PP_MODEL=strict
if [ "${PP_MAXRUN:-9}" -le 1 ]; then
  : # strict pair alternation — the existing class, zero behavior change
elif [ "${PP_MAXRUN:-9}" -eq 2 ]; then
  PP_MODEL=junction
  echo ">> ${PP_RUN2:-0} junction(s) with a 2-run of untimestamped packets — the displaced-timestamp class (measured 2026-08-18): widening the fill model; census required"
  echo "   (at each junction the PES timestamp is attached to the SECOND field of its"
  echo "    pair instead of the first — nothing missing, no clock jump. The widened rule"
  echo "    hands the displaced timestamp back to its owner via NEXT_PTS/NEXT_DTS and"
  echo "    moves the displaced one forward one field.)"
else
  if precond_attest pf-maxrun pairfill-paff.sh "$OUT" \
       "PP_MAXRUN=$PP_MAXRUN" "PP_RUN2=${PP_RUN2:-0}" "PP_MISS=$PP_MISS" "PP_N=$PP_N"; then
    PP_ATTESTED=pf-maxrun
    PP_MODEL=junction
    echo "** attested past the strict-alternation precondition (max run $PP_MAXRUN > 2):"
    echo "**   proceeding on the widened junction model; its census precondition and every"
    echo "**   output gate (POC lattice included) still run — evidence is never skipped."
  else
    echo ">> PRECONDITION FAIL: $PP_MAXRUN consecutive untimestamped packets — not strict pair alternation; the +1-field fill would be wrong. If this stream is fully-timestamped and reordered — the derive-dts route (scripts/derive-dts.sh, Rung 3-DERIVE) is the repair; pairfill only applies to half-timestamped pair sources." >&2
    precond_attest_route pf-maxrun pairfill-paff.sh >&2
    exit 3
  fi
fi

if [ "$PP_MODEL" = junction ]; then
  # --- junction precondition 1: the widened rule's setts expression variables.
  # NEXT_PTS/NEXT_DTS and PREV_INPTS/PREV_INDTS do not exist on old ffmpeg
  # (4.4 measured: option-parse rejection) — probed with a tiny synthetic
  # invocation (pf_setts_probe, lib-paff.sh), never a read of the source.
  PP_JEXPR="if(lt(PTS\,-8000000000000000000)\,if(lt(PREV_INPTS\,-8000000000000000000)\,NEXT_PTS\,PREV_OUTPTS+${A})\,if(eq(PTS\,PREV_OUTPTS)\,PTS+${A}\,PTS))"
  if ! pf_setts_probe "$PP_JEXPR"; then
    echo ">> JUNCTION MODEL REFUSED: this ffmpeg's setts lacks the NEXT_PTS/NEXT_DTS (and/or"
    echo "   PREV_INPTS/PREV_INDTS) expression variables the widened fill needs — an ffmpeg"
    echo "   >= 5.x with the full setts variable set is required (probed with a synthetic"
    echo "   invocation; never build unproven). The strict pair rule cannot repair a 2-run,"
    echo "   so nothing was built; the source is untouched."
    exit 3
  fi
  echo "   setts NEXT_PTS/NEXT_DTS support: probed OK"
  # --- junction precondition 2 (the operator's 2026-08-18 WARNING): the fixed
  # field interval is only valid when the cadence is uniform fields. A whole-
  # file trace_headers census proves it: no pic_struct in {0,5,6,7,8}
  # (frame/repeat/doubling), and the field/frame split feeds the widened
  # duration-histogram gate below. Head feature-probe first: a trace_headers
  # that parses nothing on this ffmpeg/file must refuse BEFORE the whole-file
  # pass (never build unproven), not after it.
  if [ -z "${PF_TRACE_FILE:-}" ]; then
    pp_headpics=$(ffmpeg -nostdin -hide_banner -nostats ${FF_INPUT_OPTS[@]+"${FF_INPUT_OPTS[@]}"} \
        -i "$IN" -map 0:v:0 -c copy -frames:v 40 -bsf:v trace_headers -f null - 2>&1 | \
      awk '{ for(i=1;i<=NF;i++) if($i=="first_mb_in_slice"){ if($NF+0==0) n++; break } } END{ print n+0 }')
    if [ "${pp_headpics:-0}" -eq 0 ]; then
      echo ">> JUNCTION MODEL REFUSED: trace_headers on this ffmpeg parsed no coded picture"
      echo "   from the stream head — the census cannot be taken, and the junction fill is"
      echo "   never built unproven. Nothing was built; the source is untouched."
      exit 3
    fi
  fi
  echo "-- junction census (whole-file trace_headers; demux + header parse, no decode) --"
  eval "$(pf_trace_census "$IN")"
  if [ "${PC_OK:-no}" != yes ]; then
    echo ">> JUNCTION MODEL REFUSED: the whole-file trace_headers census parsed no coded"
    echo "   pictures — unprovable cadence, nothing built."
    exit 3
  fi
  echo "   pictures=$PC_PICS  field pictures=$PC_FIELDS  frame pictures=$PC_FRAMES  pic_struct histogram: $PC_STRUCT_HIST"
  if [ "${PC_STRUCT_BAD:-1}" -ne 0 ]; then
    echo ">> JUNCTION MODEL REFUSED: $PC_STRUCT_BAD picture(s) carry pic_struct in {0,5,6,7,8}"
    echo "   (frame/repeat/doubling) — the cadence is NOT uniform fields, so the fixed field"
    echo "   interval the junction fill assumes is unproven for this file."
    echo "   pic_struct histogram: $PC_STRUCT_HIST"
    exit 3
  fi
  [ "$PC_STRUCT_HIST" = none ] && \
    echo "   note: no pic_timing pic_struct carried — no repeat/doubling signaled; the census stands on the field/frame split"
  [ "${PC_PICS:-0}" -eq "${PP_N:-0}" ] || \
    echo "   note: census pictures ($PC_PICS) != demux packets ($PP_N) — multi-slice or non-VCL framing; the duration gate still judges the written timeline"
  echo "PP_CENSUS pics=$PC_PICS fields=$PC_FIELDS frames=$PC_FRAMES pic_struct_bad=${PC_STRUCT_BAD:-0}${PP_ATTESTED:+ attested=$PP_ATTESTED}"   # machine-readable (additive, 2026-08-18)
fi

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
NAUD=$(ffp -v error -select_streams a -show_entries stream=index -of csv=p=0 "$IN" 2>/dev/null | sort -u | grep -c . || true)
if [ "${NAUD:-0}" -gt 1 ]; then
  echo "** WARNING: source has $NAUD audio tracks; pairfill carries ONLY a:0."
  echo "**          Secondary/SAP tracks are NOT in the output. Extract and remux"
  echo "**          them separately, or run the manual pairfill mux with extra"
  echo "**          -map 0:a:N entries (references/timeline-repair.md, Rung 3-PAIR)."
fi
acodec=$(ffp -v error -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1 || true)
alang=$(ffp -v error -select_streams a:0 -show_entries stream_tags=language -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1 || true)
case "$alang" in ""|und|unknown) alang=eng;; esac
DRC=(); case "$acodec" in ac3|eac3) DRC=(-drc_scale 0);; esac
# PF_CENSUS_* : the audio plan, recorded by the same case that builds the mux
# args, so the post-mux census (D5) asserts exactly what this run intended.
pf_vcodec=$(ffp -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1 || true)
AARGS=(); PF_CENSUS_N=1; PF_CENSUS_C="${pf_vcodec:-?}"
case "$acodec" in
  "") echo "   audio: none";;
  aac|alac|mp3|pcm_*|eac3)
    echo "   audio: $acodec is QuickTime-native -> single copied track"
    PF_CENSUS_N=2; PF_CENSUS_C="${pf_vcodec:-?},$acodec"
    AARGS=(-map 0:a:0 -c:a copy -metadata:s:a:0 language="$alang");;
  ac3|dts|dca|mp2|mp1)
    echo "   audio: $acodec not QuickTime-native -> dual-track (PCM access + original bit-exact)"
    PF_CENSUS_N=3; PF_CENSUS_C="${pf_vcodec:-?},pcm_s24le,$acodec"
    AARGS=(-map 0:a:0 -map 0:a:0 -c:a:0 pcm_s24le -c:a:1 copy
           -disposition:a:0 default -disposition:a:1 0
           -metadata:s:a:0 title="PCM 24-bit (access)" -metadata:s:a:0 language="$alang"
           -metadata:s:a:1 title="$(echo "$acodec" | tr a-z A-Z) (original)" -metadata:s:a:1 language="$alang");;
  *)
    echo "   audio: $acodec not MOV-copyable -> single PCM access track (original kept only in the source)"
    PF_CENSUS_N=2; PF_CENSUS_C="${pf_vcodec:-?},pcm_s24le"
    AARGS=(-map 0:a:0 -c:a pcm_s24le -metadata:s:a:0 language="$alang");;
esac

cprim=$(ffp -v error -select_streams v:0 -show_entries stream=color_primaries -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1 || true)
MOVFLAGS="+faststart"; { [ -n "$cprim" ] && [ "$cprim" != unknown ]; } && MOVFLAGS="+faststart+write_colr"

# The repair itself. lt(x,-8e18) is the unset test (INT64_MIN, not NaN); the DTS
# ramp anchors to the FIRST REAL PTS (domain-relative) and alternates A/B ticks.
if [ "$PP_MODEL" = junction ]; then
  # The widened rule, exactly as proven on the 2026-08-18 job (whole-file
  # timeline clean; POC lattice 451,071/451,071 on-slot — measured with the
  # UNWRAPPING gate, restored 1.15.2 and pinned by test 76; VCL bit-identical):
  #   pts = if(lt(PTS, -8e18),
  #            if(lt(PREV_INPTS, -8e18), NEXT_PTS, PREV_OUTPTS + FIELD),
  #            if(eq(PTS, PREV_OUTPTS), PTS + FIELD, PTS))
  #   dts = same shape with DTS/PREV_INDTS/NEXT_DTS/PREV_OUTDTS
  # Read plainly: real timestamp -> keep; first untimestamped of a pair ->
  # previous output + one field (today's rule); SECOND of a run of two -> take
  # the FOLLOWING packet's value (it belongs to this packet — the displaced-
  # timestamp case); real timestamp equal to what was just emitted -> it is the
  # displaced one, move it forward one field. FIELD is the per-file field
  # interval already computed above (${A}); never hardcoded.
  SETTS="setts=pts=${PP_JEXPR}:dts=if(lt(DTS\,-8000000000000000000)\,if(lt(PREV_INDTS\,-8000000000000000000)\,NEXT_DTS\,PREV_OUTDTS+${A})\,if(eq(DTS\,PREV_OUTDTS)\,DTS+${A}\,DTS))"
else
  SETTS="setts=pts=if(lt(PTS\,-8000000000000000000)\,PREV_OUTPTS+${A}\,PTS):dts=if(lt(PREV_OUTDTS\,-8000000000000000000)\,PTS-${PREROLL}\,PREV_OUTDTS+${A}+${AB}*mod(N\,2))"
fi
PART="$(rtm_part "$OUT")"; MUXLOG="$(mktemp)"   # extension-keeping (D6)
echo "-- muxing (video bits copied untouched; timeline pair-filled) --"
pf_mux () {  # pf_mux INPUT_OPT... — one attempt; only the probe window varies (WO 1.2)
  ffmpeg -nostdin -y -hide_banner -nostats ${DRC[@]+"${DRC[@]}"} "$@" -i "$IN" \
    -map 0:v:0 ${AARGS[@]+"${AARGS[@]}"} \
    -c:v copy -bsf:v "$SETTS" \
    -movflags "$MOVFLAGS" -f mov "$PART" 2>"$MUXLOG"
}
pf_mux_fail () {  # pf_mux_fail [LABEL] — report + exit 1 (contract), keeping the log
  echo ">> mux FAILED${1:+ ($1)}:"; sed 's/^/   /' "$MUXLOG" | tail -8
  grep -qi 'setts' "$MUXLOG" && echo "   (setts rejected the expression — this ffmpeg may lack the PREV_OUT* vars; pairfill needs ffmpeg >= 5.x)"
  echo "   partial output kept at $PART; mux log: $MUXLOG"; exit 1
}
if ! pf_mux "${FF_INPUT_OPTS[@]}"; then
  # probe-shaped failure = window undershot, not a mux defect -> retry ONCE at
  # 1G (lib-paff.sh, WO 1.2); anything else fails now, and so does a second
  # miss — the retry never masks a genuinely different error, and the output
  # timeline gates below run unchanged on whatever the retry writes
  if probe_shaped_failure "$MUXLOG"; then
    probe_retry_notice
    pf_mux "${FF_RETRY_OPTS[@]}" || pf_mux_fail "after 1G retry"
  else
    pf_mux_fail
  fi
fi
# Stream-scoped (1.14 / DF-10): only VIDEO (or unattributable) confessions
# hard-stop; audio/subtitle DTS nudges are the ms-quantization class ->
# announced + REVIEW (the fill only ever touched v:0's timeline anyway).
eval "$(mux_confessions_scoped "$MUXLOG" 0)"   # video is output stream 0:0 (mapped first)
conf=${MC_VIDEO:-0}
if [ "${conf:-0}" -gt 0 ]; then
  echo ">> HARD STOP: the muxer logged $conf timeline confession(s) (pts has no value /"
  echo "   Timestamps are unset / non-monotonic DTS) — it invented timing despite the fill."
  grep -iE 'pts has no value|timestamps are unset|non-?monoton(ic|ous) dts|non monotonically increasing dts' "$MUXLOG" | sort | uniq -c | sort -rn | head -4 | sed 's/^/   /'
  echo "   NOT blessing the output. Kept: $PART (log: $MUXLOG)"; exit 1
fi
PF_CONF_REVIEW=0
if [ "${MC_AUDSUB:-0}" -gt 0 ]; then
  echo ">> REVIEW: $MC_AUDSUB audio DTS nudges (ms-quantization class) — not video timing"
  echo "   invention; verify gates (f)/(g) judge audio. Building on; exit will say 10."
  echo "RMX_CONFESS stage=pairfill-paff video=0 audsub=${MC_AUDSUB} unattr=${MC_UNATTR:-0}"   # machine-readable (additive, DF-10 1.14)
  PF_CONF_REVIEW=10
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
# Junction model (2026-08-18): the census counted frame pictures (field_pic_flag
# =0), each worth TWO field intervals — the expected histogram is then
# fields x FIELD + frames x 2FIELD (the record's proof read 450878x1800 +
# 193x3600). jm=1 admits the ${PAIR}-tick duration and counts it separately
# (PG_PAIRDUR, matched against the census below); jm=0 leaves the strict-path
# arithmetic byte-for-byte as before (a PAIR duration is off-histogram).
PP_JM=0; [ "$PP_MODEL" = junction ] && PP_JM=1
echo "-- output timeline gates (want: 0 N/A, strictly monotonic DTS, only ${A}/${B}-tick durations, bounded PTS-DTS) --"
[ "$PP_JM" -eq 1 ] && echo "   (junction model: ${PAIR}-tick frame-picture durations admitted — census expects ${PC_FIELDS:-0} x field + ${PC_FRAMES:-0} x pair)"
eval "$(ffp -v error -select_streams v:0 -show_entries packet=pts,dts,duration -of csv=p=0 "$PART" 2>/dev/null | \
  awk -F, -v a="$A" -v b="$B" -v pair="$PAIR" -v jm="$PP_JM" 'NF{
      n++
      if($1=="N/A"||$1==""){ nap++ } else { p=$1+0; if(!havp){mnp=mxp=p; havp=1} else {if(p<mnp)mnp=p; if(p>mxp)mxp=p} }
      if($2=="N/A"||$2==""){ nad++ } else { d=$2+0; if(!havd){fd=d} else { if(d<pd) back++; else if(d==pd) dup++ }; pd=d; havd=1
        if($1!="N/A" && $1!="" ){ off=($1+0)-d; if(off>mxo) mxo=off } }
      if($3!="N/A" && $3!=""){ h[$3]++
        if($3+0!=a && $3+0!=b){ if(jm && $3+0==pair) pd2++; else od++ } }
    }
    END{
      pspan=(havp?mxp-mnp:0); dspan=(havd?pd-fd:0); skew=pspan-dspan; if(skew<0)skew=-skew
      printf "PG_N=%d PG_NAPTS=%d PG_NADTS=%d PG_BACK=%d PG_DUP=%d PG_OFFHIST=%d PG_PAIRDUR=%d PG_MAXOFF=%d PG_SKEW=%d\n", \
        n+0, nap+0, nad+0, back+0, dup+0, od+0, pd2+0, mxo+0, skew+0
    }')"
echo "   packets=$PG_N  N/A-PTS=$PG_NAPTS  N/A-DTS=$PG_NADTS  backward-DTS=$PG_BACK  duplicate-DTS=$PG_DUP  off-histogram durations=$PG_OFFHIST"
[ "$PP_JM" -eq 1 ] && echo "   pair-tick (frame-picture) durations=$PG_PAIRDUR (census counted ${PC_FRAMES:-0} frame picture(s))"
echo "   max PTS-DTS=$PG_MAXOFF (derived limit $MAXOFF_LIMIT)  presentation-vs-decode span skew=$PG_SKEW ticks (limit $((2 * PAIR)))"
gates_ok=1
[ "${PG_NAPTS:-1}" -eq 0 ] || gates_ok=0
[ "${PG_NADTS:-1}" -eq 0 ] || gates_ok=0
[ "${PG_BACK:-1}"  -eq 0 ] || gates_ok=0
[ "${PG_DUP:-1}"   -eq 0 ] || gates_ok=0
[ "${PG_OFFHIST:-9}" -le 2 ] || gates_ok=0   # first/last sample may legitimately stray
[ "${PG_MAXOFF:-999999999}" -le "$MAXOFF_LIMIT" ] || gates_ok=0
[ "${PG_SKEW:-999999999}" -le $((2 * PAIR)) ] || gates_ok=0
if [ "$PP_JM" -eq 1 ]; then
  # the written pair-tick durations must match the census's frame-picture count
  # (same first/last-sample tolerance the off-histogram check has always had)
  pp_fdiff=$((PG_PAIRDUR - ${PC_FRAMES:-0})); [ "$pp_fdiff" -ge 0 ] || pp_fdiff=$((-pp_fdiff))
  [ "$pp_fdiff" -le 2 ] || { echo "   junction histogram mismatch: $PG_PAIRDUR pair-tick durations written vs $PC_FRAMES frame pictures counted"; gates_ok=0; }
fi
if [ "$gates_ok" -ne 1 ]; then
  echo ">> TIMELINE GATES FAILED — the written timeline is not the derived one."
  echo "   NOT blessing the output. Kept: $PART (log: $MUXLOG)"
  echo "   (unbounded PTS-DTS / span skew = the DTS ramp cadence does not match the"
  echo "    stream's packets-per-field — wrong --rate, or not the pair class at all;"
  echo "    rerun scripts/diagnose.sh)"
  exit 1
fi
rm -f "$MUXLOG"
# --- POC-lattice output gate (junction model ONLY; the record's local gate 2,
# the strongest correctness evidence a field fill can carry): extract per-
# picture pic_order_cnt_lsb from the OUTPUT via trace_headers (already proven
# available by the census precondition) and per-picture output PTS via ffprobe;
# per IDR-delimited sequence, fit base = PTS - POC x half_interval from the
# first pictures and assert EVERY picture sits on its slot (pf_poc_lattice,
# lib-paff.sh). Any off-lattice picture: FAIL exit 1, artifact kept as .part.
if [ "$PP_JM" -eq 1 ]; then
  echo "-- POC-lattice gate (junction model): every picture on its presentation slot --"
  PP_POCA="$(mktemp)"; PP_POCB="$(mktemp)"; PP_POCT="$(mktemp)"; PP_SPS="$(mktemp)"
  # the same pass also captures the SPS's log2_max_pic_order_cnt_lsb_minus4 —
  # pf_poc_lattice needs MaxPicOrderCntLsb to unwrap the lsb (1.15.2 Defect D)
  ffmpeg -nostdin -hide_banner -nostats -i "$PART" -map 0:v:0 -c copy \
      -bsf:v trace_headers -f null - 2>&1 | \
    awk -v spsf="$PP_SPS" '{ name=""
           for(i=1;i<=NF;i++) if($i=="nal_unit_type"||$i=="first_mb_in_slice"||$i=="pic_order_cnt_lsb"||$i=="log2_max_pic_order_cnt_lsb_minus4"){ name=$i; break }
           if(name=="") next
           v=$NF+0
           if(name=="log2_max_pic_order_cnt_lsb_minus4"){ l2=v; next }
           if(name=="nal_unit_type"){ nal=v; next }
           if(name=="first_mb_in_slice"){ if(v==0){ pend=1; idr=(nal==5)?1:0 }; next }
           if(pend){ printf "%d,%d\n", idr, v; pend=0 } }
         END{ if(l2 != "") printf "%d\n", l2 > spsf }' > "$PP_POCA"
  ffp -v error -select_streams v:0 -show_entries packet=pts -of csv=p=0 "$PART" 2>/dev/null | \
    awk -F, 'NF && $1!="N/A"{ print $1+0 }' > "$PP_POCB"
  pp_na=$(grep -c . "$PP_POCA" || true); pp_nb=$(grep -c . "$PP_POCB" || true)
  if [ "${pp_na:-0}" -eq 0 ] || [ "${pp_na:-0}" -ne "${pp_nb:-1}" ]; then
    # UNPROVEN, not FAILED (the 1.15.2 rule): this branch is a claim about the
    # GATE's reach, not about the artifact — but an unproven build is still
    # never blessed, so the exit and the retention are unchanged.
    echo ">> POC-LATTICE GATE UNPROVEN — POC not extractable or picture/packet counts differ"
    echo "   (POC rows=$pp_na, timestamped packets=$pp_nb; pic_order_cnt_type != 0 streams"
    echo "    carry no pic_order_cnt_lsb and the lattice cannot be evaluated — never"
    echo "    blessed unproven; this is not evidence the artifact is bad)."
    echo "   Kept: $PART ($(wc -c < "$PART" | tr -d ' ') bytes; delete: rm \"$PART\")"
    rm -f "$PP_POCA" "$PP_POCB" "$PP_POCT" "$PP_SPS"; exit 1
  fi
  PP_L2=$(head -1 "$PP_SPS" 2>/dev/null || true)
  PP_MAXLSB=0
  case "${PP_L2:-}" in ''|*[!0-9]*) ;; *) [ "$PP_L2" -le 12 ] && PP_MAXLSB=$((1 << (PP_L2 + 4)));; esac
  if [ "$PP_MAXLSB" -gt 0 ]; then
    echo "   MaxPicOrderCntLsb=$PP_MAXLSB (SPS log2_max_pic_order_cnt_lsb_minus4=$PP_L2); lsb unwrapped per H.264 8.2.1.1"
  else
    echo "   MaxPicOrderCntLsb: SPS value unavailable — inferred per sequence (next power of two above the largest lsb)"
  fi
  paste -d, "$PP_POCA" "$PP_POCB" > "$PP_POCT"
  eval "$(pf_poc_lattice "$PP_POCT" "$PP_MAXLSB")"
  rm -f "$PP_POCA" "$PP_POCB" "$PP_POCT" "$PP_SPS"
  echo "   on_slot=$PL_ON/$PL_TOTAL  off_lattice=$PL_OFF  (IDR sequences=$PL_SEQS)"
  echo "PP_POC_LATTICE on_slot=$PL_ON total=$PL_TOTAL off=$PL_OFF"   # machine-readable (additive, 2026-08-18)
  if [ "${PL_OFF:-1}" -ne 0 ]; then
    echo ">> POC-LATTICE GATE FAILED — $PL_OFF picture(s) off their presentation slot:"
    echo "   the written timeline is not the derived lattice. NOT blessing."
    echo "   Kept: $PART ($(wc -c < "$PART" | tr -d ' ') bytes; delete: rm \"$PART\")"
    exit 1
  fi
fi
# POST-MUX CENSUS (D5, 1.13): the timeline gates above judge v:0 only — an audio
# track the muxer quietly dropped would sail past every one of them.
census_rc=0
mux_census "$PART" "$PF_CENSUS_N" "$PF_CENSUS_C" pairfill-paff "$IN" || census_rc=$?
if [ "$census_rc" -ne 0 ] && [ "$census_rc" -ne 10 ]; then
  echo "   NOT blessing the output. Kept: $PART"
  exit 1
fi
mv -f "$PART" "$OUT"
echo "wrote: $OUT"
# bash 3.2 can't parse $(case ...) inside a double-quoted string — precompute
AUDFLAG=""; case "$acodec" in ac3|dts|dca|mp2|mp1) AUDFLAG=" --audio";; esac
echo "sign-off: scripts/verify.sh \"$IN\" \"$OUT\"$AUDFLAG"
echo "  (the scrub gate + A/V parity there are still required — these gates prove the"
echo "   container timeline, not the decode; a FAIL there is a defect until every gate"
echo "   is individually explained)"
# REVIEW propagation (1.14): an unexpected-surplus census or an audio/subtitle
# confession class blesses the complete artifact and exits 10 ("look"), never 1.
if [ "$census_rc" -eq 10 ] || [ "${PF_CONF_REVIEW:-0}" -eq 10 ]; then exit 10; fi
exit 0

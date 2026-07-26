#!/usr/bin/env bash
# remux.sh — Rung 0/1 lossless remux into MOV.
# Usage: scripts/remux.sh INPUT OUTPUT.mov [--audio auto|copy|pcm] [--genpts]
#                         [--audio-keep all|first|layouts|IDX[,IDX...]]
#                         [--all-audio] [--print-plan] [--timescale N]
#   --audio auto (default): per kept track — copy AC-3/E-AC-3/AAC/ALAC/PCM;
#                           decode MP2/MP1/MP3/DTS (QuickTime-unplayable) and
#                           FLAC/Opus/Vorbis/TrueHD (not MOV-copyable) to PCM
#   --audio copy : force copy (mux-only; may not play — or mux — in QuickTime)
#   --audio pcm  : force pcm_s16le on every kept track
#   --genpts     : add -fflags +genpts (Rung 2, missing timestamps)
#   --audio-keep : which audio tracks survive (QTFF audit 5-2b; policy details
#                  in SKILL.md house defaults):
#                    first   (default) a:0 only — the historical behavior
#                    all     every track
#                    layouts distinct channel layouts all survive; duplicate
#                            layouts curated lossless > lossy-high > lossy-low
#                            (earlier track wins ties)
#                    0,2,...  explicit audio ordinals
#                  Every decision is printed as a KEEP/DROP manifest before the
#                  mux; every DROP is a WARN. No silent mapping decisions.
#   --all-audio  : alias for --audio-keep all (kept for compatibility)
#   --print-plan : print the KEEP/DROP manifest and exit without writing
#   --timescale N: set -video_track_timescale (ms-quantized MKV conventionality
#                  fix — see probe.sh's advisory; a timescale change, never a
#                  restamp)
# Video is ALWAYS copied (bit-identical). HEVC is tagged hvc1. Output is written
# atomically (.part -> mv) so a failure never leaves a half file under the real name.
set -euo pipefail
IN="${1:?usage: remux.sh INPUT OUTPUT.mov [opts]}"; OUT="${2:?need OUTPUT.mov}"; shift 2
AUDIO=auto; GENPTS=""; KEEP=first; PLANONLY=0; TSCALE=""
while [ $# -gt 0 ]; do case "$1" in
  --audio) AUDIO="$2"; shift 2;;
  --genpts) GENPTS="-fflags +genpts"; shift;;
  --all-audio) KEEP=all; shift;;
  --audio-keep) KEEP="${2:?--audio-keep needs a value}"; shift 2;;
  --audio-keep=*) KEEP="${1#*=}"; shift;;
  --print-plan) PLANONLY=1; shift;;
  --timescale) TSCALE="${2:?--timescale needs a value}"; shift 2;;
  --timescale=*) TSCALE="${1#*=}"; shift;;
  *) echo "unknown opt: $1" >&2; exit 2;;
esac; done
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }
[ "$(cd "$(dirname "$IN")" && pwd)/$(basename "$IN")" != "$(cd "$(dirname "$OUT")" 2>/dev/null && pwd)/$(basename "$OUT")" ] \
  || { echo "refusing to overwrite the source in place" >&2; exit 2; }
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-paff.sh"   # mux_confessions

# --- per-track audio manifest -> KEEP/DROP plan (QTFF audit 5-2b) ---
# One awk pass computes the whole selection so the policy lives in ONE place
# (mov.sh consumes it via --print-plan instead of duplicating the logic).
# Codec ranking for layout curation: lossless (pcm/flac/alac/truehd/mlp) >
# lossy-high (eac3/ac3/aac/opus/vorbis/dts) > lossy-low (mp2/mp1/mp3);
# unknown ranks lowest; the earlier track wins ties. TS sources list each
# stream under its program AND top-level -> dedupe by stream index.
PLAN=$(ffprobe -v error -select_streams a \
    -show_entries stream=index,codec_name,channels,channel_layout:stream_tags=language \
    -of compact=p=0:nk=0 "$IN" 2>/dev/null | \
  awk -F'|' -v pol="$KEEP" '
    # BEGIN{n=0} is load-bearing: an UNINITIALIZED n used as an array subscript
    # is the empty string (not 0) in POSIX awk, silently storing record 0 at
    # C[""] — while n++ still counts it. Caught by probe on the first fixture.
    BEGIN{ n=0 }
    function rank(c){ if(c ~ /^pcm_/ || c=="flac" || c=="alac" || c=="truehd" || c=="mlp") return 3
                      if(c=="eac3" || c=="ac3" || c=="aac" || c=="opus" || c=="vorbis" || c=="dts" || c=="dca") return 2
                      if(c=="mp2" || c=="mp1" || c=="mp3") return 1
                      return 0 }
    function rname(r){ return r==3?"lossless":(r==2?"lossy-high":(r==1?"lossy-low":"unknown")) }
    NF{
      c="unknown"; ch=0; lay=""; lang="und"; idx=""
      for(i=1;i<=NF;i++){ eq=index($i,"="); k=substr($i,1,eq-1); v=substr($i,eq+1)
        if(k=="index")idx=v; else if(k=="codec_name")c=v; else if(k=="channels")ch=v
        else if(k=="channel_layout")lay=v; else if(k=="tag:language")lang=v }
      if(idx!=""){ if(idx in seen) next; seen[idx]=1 }
      if(lay=="") lay=ch"ch"
      C[n]=c; CH[n]=ch; L[n]=lay; G[n]=lang; n++
    }
    END{
      if(pol=="layouts")
        for(o=0;o<n;o++) if(!(L[o] in best) || rank(C[o])>rank(C[best[L[o]]])) best[L[o]]=o
      split(pol, want, ","); for(w in want) wantset[want[w]]=1
      for(o=0;o<n;o++){
        keep=0; rule=""
        if(pol=="all"){ keep=1; rule="policy all" }
        else if(pol=="first"){ if(o==0){keep=1; rule="policy first (a:0)"} else rule="policy first keeps a:0 only" }
        else if(pol=="layouts"){
          cnt=0; for(p=0;p<n;p++) if(L[p]==L[o]) cnt++
          if(best[L[o]]==o){ keep=1; rule=(cnt==1?"distinct layout "L[o]:"best of layout "L[o]" ("rname(rank(C[o]))")") }
          else { b=best[L[o]]; rule="duplicate layout "L[o]": "C[o]" ("rname(rank(C[o]))") loses to a:"b" "C[b]" ("rname(rank(C[b]))")" }
        }
        else { if(o in wantset){keep=1; rule="requested index"} else rule="not in requested indices" }
        printf "%d|%s|%s|%s|%s|%s|%s\n", o, C[o], CH[o], L[o], G[o], (keep?"KEEP":"DROP"), rule
      }
    }' || true)

# validate explicit-indices policy: every requested ordinal must exist
case "$KEEP" in
  all|first|layouts) ;;
  *) naud=$(printf '%s\n' "$PLAN" | grep -c . || true)
     for req in $(printf '%s' "$KEEP" | tr ',' ' '); do
       case "$req" in ''|*[!0-9]*) echo "bad --audio-keep value: $KEEP" >&2; exit 2;; esac
       [ "$req" -lt "${naud:-0}" ] || { echo "--audio-keep $KEEP: no audio track a:$req (source has ${naud:-0})" >&2; exit 2; }
     done;;
esac

KEPT=""; DROPPED=""
if [ -n "$PLAN" ]; then
  echo "-- audio keep/drop manifest (policy: $KEEP) --"
  while IFS='|' read -r ord codec ch lay lang verdict rule; do
    [ -n "$ord" ] || continue
    if [ "$verdict" = KEEP ]; then
      echo "   KEEP a:$ord $codec ${ch}ch $lay $lang — $rule"
      KEPT="${KEPT:+$KEPT,}$ord"
    else
      echo "** WARN DROP a:$ord $codec ${ch}ch $lay $lang — $rule"
      DROPPED="${DROPPED:+$DROPPED,}$ord"
    fi
    # machine row per track (mov.sh's classifier consumes these via --print-plan)
    echo "RMX_T ord=$ord keep=$([ "$verdict" = KEEP ] && echo 1 || echo 0) codec=$codec ch=$ch layout=$lay lang=$lang"
  done <<EOF
$PLAN
EOF
else
  echo "audio: none"
fi
echo "RMX_PLAN policy=$KEEP kept=${KEPT:-none} dropped=${DROPPED:-none}"   # machine-readable
[ "$PLANONLY" -eq 1 ] && exit 0

# --- per-track audio handling (mirrors the old a:0 auto rule, now per track) ---
AARGS=(); outi=0
if [ -n "$KEPT" ]; then
  for ord in $(printf '%s' "$KEPT" | tr ',' ' '); do
    codec=$(printf '%s\n' "$PLAN" | awk -F'|' -v o="$ord" '$1==o{print $2; exit}')
    AARGS=(${AARGS[@]+"${AARGS[@]}"} -map "0:a:$ord")
    case "$AUDIO" in
      pcm)  AARGS=(${AARGS[@]+"${AARGS[@]}"} "-c:a:$outi" pcm_s16le)
            echo "audio a:$ord: $codec -> PCM (forced)";;
      copy) AARGS=(${AARGS[@]+"${AARGS[@]}"} "-c:a:$outi" copy)
            echo "audio a:$ord: $codec -> copy (forced)";;
      *) case "$codec" in
           mp2|mp1|mp3|dts|dca) AARGS=(${AARGS[@]+"${AARGS[@]}"} "-c:a:$outi" pcm_s16le)
                                echo "audio a:$ord: $codec -> PCM (QuickTime-unplayable)";;
           flac|opus|vorbis|truehd|mlp) AARGS=(${AARGS[@]+"${AARGS[@]}"} "-c:a:$outi" pcm_s16le)
                                echo "audio a:$ord: $codec -> PCM (not MOV-copyable)";;
           *) AARGS=(${AARGS[@]+"${AARGS[@]}"} "-c:a:$outi" copy)
              echo "audio a:$ord: $codec -> copy";;
         esac;;
    esac
    outi=$((outi+1))
  done
fi

# --- video tag (HEVC needs hvc1 for QuickTime) ---
vcodec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1 || true)
VTAG=""; [ "$vcodec" = hevc ] && VTAG="-tag:v hvc1"

# --- color: +write_colr is redundant on modern ffmpeg but harmless; include only if tagged ---
cp=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_primaries -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1 || true)
MOVFLAGS="+faststart"; { [ -n "$cp" ] && [ "$cp" != unknown ]; } && MOVFLAGS="+faststart+write_colr"

PART="${OUT}.part"; MUXLOG="$(mktemp)"
# shellcheck disable=SC2086
if ! ffmpeg -nostdin -y -hide_banner -nostats $GENPTS -i "$IN" -map 0:v:0 \
    ${AARGS[@]+"${AARGS[@]}"} \
    -c:v copy $VTAG \
    ${TSCALE:+-video_track_timescale "$TSCALE"} \
    -movflags "$MOVFLAGS" -f mov \
    "$PART" 2>"$MUXLOG"; then
  echo ">> mux FAILED:"; sed 's/^/   /' "$MUXLOG" | tail -8
  exit 1
fi
[ -n "${RTM_MUX_LOG_APPEND:-}" ] && [ -f "$RTM_MUX_LOG_APPEND" ] && cat "$RTM_MUX_LOG_APPEND" >> "$MUXLOG"   # test hook
[ -s "$MUXLOG" ] && sed 's/^/   mux: /' "$MUXLOG" | tail -6
# HARD STOP (post-mortem 2026-07-25): "pts has no value" / "Timestamps are unset" /
# non-monotonic DTS in a COPY mux's log is the muxer announcing it INVENTED the
# timeline. The video bits can be perfect while the written timing is garbage —
# the shipped-broken files rendered thumbnails and passed the essence checks.
# Never bless such an output, regardless of what any later check says.
conf=$(mux_confessions "$MUXLOG")
if [ "${conf:-0}" -gt 0 ]; then
  echo ">> HARD STOP: the muxer logged $conf timeline confession(s):"
  grep -iE 'pts has no value|timestamps are unset|non-?monotonic dts' "$MUXLOG" | sort | uniq -c | sort -rn | head -4 | sed 's/^/   /'
  echo "   The muxer invented timing for packets the source never timestamped."
  echo "   NOT blessing the output (kept at $PART; log: $MUXLOG)."
  echo "   Run scripts/diagnose.sh \"$IN\" — half-timestamped PAFF routes to"
  echo "   scripts/pairfill-paff.sh; timestamp-free streams to scripts/rebuild-paff.sh."
  exit 1
fi
rm -f "$MUXLOG"
mv -f "$PART" "$OUT"
echo "wrote: $OUT"
echo "verify with: scripts/verify.sh \"$IN\" \"$OUT\""

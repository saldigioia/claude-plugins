#!/usr/bin/env bash
# probe.sh — one-shot source inspection for a remux decision.
# Usage: scripts/probe.sh INPUT [--kv|--json]
#   (default)  human-readable report
#   --kv       machine-readable KEY=VAL (PR_* + PF_* + a recommended FIRST rung)
#   --json     same facts as a flat JSON object
# Prints: container, video/audio codecs + tags, per-track audio manifest, field
# structure, Annex-B vs AVCC, color tags, a timestamp sanity flag, ms-timebase
# advisory, and ffmpeg-version-dependent warnings.
set -euo pipefail
IN="${1:?usage: probe.sh INPUT [--kv|--json]}"; MODE="${2:-human}"
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-paff.sh"   # shared PAFF detection (coded-picture-rate test)

# --- per-track audio manifest (QTFF audit 5-2a) ---------------------------------
# The audio classifier must see the WHOLE track set, not a:0 — the incident
# blind spot: FLAC-5.1 + MP2-stereo classified 'pcm' off track 1 and silently
# dropped track 2. Emitted as PR_AUD_COUNT + PR_AUD_<n>_{CODEC,CHANNELS,LAYOUT,
# LANG}; layouts are single-quoted (parens) — keys satisfy ^(PR|PF)_[A-Z0-9_]+=.
aud_manifest_kv () {
  ffprobe -v error -select_streams a \
      -show_entries stream=index,codec_name,channels,channel_layout:stream_tags=language \
      -of compact=p=0:nk=0 "$IN" 2>/dev/null | \
  awk -F'|' 'NF{
      c="unknown"; ch=0; lay=""; lang="und"; idx=""
      for(i=1;i<=NF;i++){ eq=index($i,"="); k=substr($i,1,eq-1); v=substr($i,eq+1)
        if(k=="index")idx=v; else if(k=="codec_name")c=v; else if(k=="channels")ch=v
        else if(k=="channel_layout")lay=v; else if(k=="tag:language")lang=v }
      # TS lists each stream under its program AND top-level -> dedupe by index
      # (same quirk verify.sh dedupes for packet counts)
      if(idx!=""){ if(idx in seen) next; seen[idx]=1 }
      if(lay=="") lay="unknown"
      printf "PR_AUD_%d_CODEC=%s\nPR_AUD_%d_CHANNELS=%s\nPR_AUD_%d_LAYOUT=%c%s%c\nPR_AUD_%d_LANG=%s\n", \
        n, c, n, ch, n, 39, lay, 39, n, lang
      n++
    } END{ printf "PR_AUD_COUNT=%d\n", n+0 }'
}

# --- ms-timebase advisory scan (QTFF audit 5-4e, C68) ---------------------------
# MKV's 1/1000 timebase survives remux as a coarse video timescale with
# alternating tick durations — source-baked ±0.5 ms rounding, not judder. Sets
# MS_TB=yes/no, TS_HINT (conventional -video_track_timescale), MS_ALT (top two
# duration ticks, evidence for the report).
ms_tb_scan () {
  MS_TB=no; TS_HINT=""; MS_ALT=""
  local tb fr num den
  tb=$(ffprobe -v error -select_streams v:0 -show_entries stream=time_base -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
  [ "$tb" = 1/1000 ] || return 0
  MS_TB=yes
  MS_ALT=$(ffprobe -v error -select_streams v:0 -read_intervals '%+#120' -show_entries packet=duration -of csv=p=0 "$IN" 2>/dev/null | \
    grep -v -e N/A -e '^$' | sort | uniq -c | sort -rn | head -2 | awk '{printf "%s%sx%sms", sep, $1, $2; sep=" "}')
  fr=$(ffprobe -v error -select_streams v:0 -show_entries stream=avg_frame_rate -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
  num=${fr%%/*}; den=${fr##*/}
  case "$den" in
    1001) TS_HINT=$num;;                                   # 30000/1001 -> 30000
    1)    case "$num" in ''|*[!0-9]*) TS_HINT=90000;; *) TS_HINT=$((num * 1000));; esac;;
    *)    TS_HINT=90000;;                                  # odd rate -> MPEG clock
  esac
}

# --- mp4 atom scan: gama + stsd sample entry (QTFF audit 5-5b/5-5e) -------------
# One mp4dump pass shared by both checks. Degrades silently: non-MP4-family
# containers are skipped; without mp4dump the stsd entry falls back to ffprobe's
# codec_tag_string and gama reads 'unknown' (report-only either way).
mp4_atom_scan () {  # $1 = container name, $2 = ffprobe codec_tag_string fallback
  GAMA=unknown; STSD_ENTRY=""; STSD_DV=""
  case "$1" in *mov*|*mp4*|*m4a*) ;; *) GAMA=no; return 0;; esac
  if ! command -v mp4dump >/dev/null 2>&1; then STSD_ENTRY="${2:-}"; return 0; fi
  local dump
  dump=$(mp4dump "$IN" 2>/dev/null || true)
  [ -n "$dump" ] || { STSD_ENTRY="${2:-}"; return 0; }
  # pure-bash case matches: a piped `grep -q` SIGPIPEs the printf under
  # pipefail on a match (the herestring lesson from verify.sh) — never pipe
  # into an early-exit reader here
  case "$dump" in *'[gama]'*) GAMA=yes;; *) GAMA=no;; esac
  case "$dump" in *'[dvcC]'*|*'[dvvC]'*) STSD_DV=yes;; esac
  STSD_ENTRY=$(printf '%s\n' "$dump" | awk '/\[stsd\]/{f=1;next} f&&/\[/{gsub(/[^A-Za-z0-9-]/,"",$1); print $1; exit}' || true)
  [ -n "$STSD_ENTRY" ] || STSD_ENTRY="${2:-}"
}

# Structured output for auto.sh / batch.sh. The recommended rung is a FIRST guess
# from codec/PAFF/audio only; timestamp-driven escalation (Rung 2/3 on non-PAFF)
# happens reactively in auto.sh from the verify verdict.
probe_struct () {
  local mode="$1" q="ffprobe -v error -select_streams"
  local container vcodec vtag isavc acodec aaction rung cmd cp ct cs cr pixfmt
  container=$(ffprobe -v error -show_entries format=format_name -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
  vcodec=$($q v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
  vtag=$($q v:0 -show_entries stream=codec_tag_string -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
  pixfmt=$($q v:0 -show_entries stream=pix_fmt -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
  isavc=$($q v:0 -show_entries stream=is_avc -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
  acodec=$($q a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
  cp=$($q v:0 -show_entries stream=color_primaries -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
  ct=$($q v:0 -show_entries stream=color_transfer -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
  cs=$($q v:0 -show_entries stream=color_space -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
  cr=$($q v:0 -show_entries stream=color_range -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
  eval "$(pf_detect "$IN")"
  eval "$(pf_reorder_scan "$IN")"
  ms_tb_scan
  mp4_atom_scan "$container" "$vtag"
  case "$acodec" in                              # mirrors remux.sh --audio auto
    mp2|mp1|mp3|dts|dca)         aaction=pcm;;   # QuickTime-unplayable
    flac|opus|vorbis|truehd|mlp) aaction=pcm;;   # not MOV-copyable (5-2b alignment)
    "")                          aaction=none;;
    *)                           aaction=copy;;
  esac
  # PAFF repair routed by timestamp profile (post-mortem 2026-07-25): a pair-
  # timestamped or reordered stream must KEEP its real PTS (pairfill); the
  # constant-rate rebuild is only safe when no reorder pyramid survives.
  if [ "$PF_PAFF" = yes ]; then
    rung=3
    if [ "$PF_HALF_TS" = yes ] || [ "$PF_REORDER" = yes ]; then cmd="pairfill-paff.sh IN OUT.mov"
    else cmd="rebuild-paff.sh IN OUT.mov $PF_FIELD_RATE $PF_TIMESCALE"; fi
  elif [ "$aaction" = pcm ]; then rung=1; cmd="remux.sh IN OUT.mov --audio pcm"
  else                            rung=0; cmd="remux.sh IN OUT.mov"; fi
  if [ "$mode" = "--json" ]; then
    printf '{"container":"%s","vcodec":"%s","vtag":"%s","pix_fmt":"%s","is_avc":"%s","acodec":"%s","audio_action":"%s","paff":"%s","field_rate":"%s","timescale":"%s","coded_rate":"%s","nominal_fps":"%s","nopts_frac":"%s","half_ts":"%s","reorder":"%s","color_primaries":"%s","color_transfer":"%s","color_space":"%s","color_range":"%s","rec_rung":%s,"rec_cmd":"%s"}\n' \
      "$container" "$vcodec" "$vtag" "${pixfmt:-unknown}" "${isavc:-na}" "${acodec:-none}" "$aaction" "$PF_PAFF" "$PF_FIELD_RATE" "$PF_TIMESCALE" "$PF_CODED_RATE" "$PF_NOMINAL_FPS" "$PF_NOPTS_FRAC" "$PF_HALF_TS" "$PF_REORDER" "${cp:-unknown}" "${ct:-unknown}" "${cs:-unknown}" "${cr:-unknown}" "$rung" "$cmd"
  else
    # values are single tokens (eval-safe + greppable); PR_REC_CMD has spaces -> quote it
    printf 'PR_CONTAINER=%s\nPR_VCODEC=%s\nPR_VTAG=%s\nPR_PIX_FMT=%s\nPR_IS_AVC=%s\nPR_ACODEC=%s\nPR_AUDIO_ACTION=%s\nPF_PAFF=%s\nPF_FIELD_RATE=%s\nPF_TIMESCALE=%s\nPF_CODED_RATE=%s\nPF_NOMINAL_FPS=%s\nPF_NOPTS_FRAC=%s\nPF_HALF_TS=%s\nPF_REORDER=%s\nPR_COLOR_PRIMARIES=%s\nPR_COLOR_TRANSFER=%s\nPR_COLOR_SPACE=%s\nPR_COLOR_RANGE=%s\nPR_REC_RUNG=%s\nPR_REC_CMD='"'"'%s'"'"'\n' \
      "$container" "$vcodec" "$vtag" "${pixfmt:-unknown}" "${isavc:-na}" "${acodec:-none}" "$aaction" "$PF_PAFF" "$PF_FIELD_RATE" "$PF_TIMESCALE" "$PF_CODED_RATE" "$PF_NOMINAL_FPS" "$PF_NOPTS_FRAC" "$PF_HALF_TS" "$PF_REORDER" "${cp:-unknown}" "${ct:-unknown}" "${cs:-unknown}" "${cr:-unknown}" "$rung" "$cmd"
    aud_manifest_kv                                                       # 5-2a
    printf 'PR_MS_TB=%s\nPR_TS_HINT=%s\n' "$MS_TB" "${TS_HINT:-none}"    # 5-4e
    printf 'PR_GAMA=%s\nPR_STSD_ENTRY=%s\nPR_STSD_DV=%s\n' \
      "$GAMA" "${STSD_ENTRY:-unknown}" "${STSD_DV:-no}"                  # 5-5b/e
  fi
}
case "$MODE" in --kv|--json) probe_struct "$MODE"; exit 0;; esac

echo "== source: $IN =="
container=$(ffprobe -v error -show_entries format=format_name -of default=nw=1:nk=1 "$IN")
echo "container : $container"

echo "-- video --"
ffprobe -v error -select_streams v:0 -show_entries \
  stream=codec_name,codec_tag_string,profile,width,height,field_order,pix_fmt,color_primaries,color_transfer,color_space,color_range,is_avc,nal_length_size \
  -of default=nw=1 "$IN" || true
# stsd sample entry + Dolby Vision config visibility (QTFF audit 5-5e): the DV
# playability split rides the sample-entry fourcc (dvh1 plays where the hev1
# family fails); ffprobe's codec_tag_string alone can miss the dvcC/dvvC box.
vtag_h=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_tag_string -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
mp4_atom_scan "$container" "$vtag_h"
if [ -n "${STSD_ENTRY:-}" ] && [ "$STSD_ENTRY" != "[0][0][0][0]" ]; then
  echo "stsd sample entry: $STSD_ENTRY${STSD_DV:+ (+Dolby Vision dvcC/dvvC config box)}"
fi
if [ "${GAMA:-unknown}" = yes ]; then
  echo "   WARN legacy 'gama' atom present (pre-2010 QuickTime gamma era): modern"
  echo "        players may render this dark/washed vs an nclc-tagged copy. A -c copy"
  echo "        remux normalizes it; see color-hdr-subs.md (Pre-2010 exports)."
fi
# backhaul/contribution mastering profiles: QuickTime has NO 4:2:2 decode path
# for MPEG-2 (verify-green MOV distorts, 2026-07-30) OR H.264 High 4:2:2
# (decoder stalls, 2026-07-31) — both proven against 4:2:0 controls.
vcod_h=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
pix_h=$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
if [ "$pix_h" = yuv422p ] && { [ "$vcod_h" = mpeg2video ] || [ "$vcod_h" = h264 ]; }; then
  echo "   >> QT-UNDECODABLE: $vcod_h 4:2:2 (yuv422p) — AVFoundation/QuickTime cannot"
  echo "      decode this profile at all; even a verified lossless MOV will not play"
  echo "      (MPEG-2 4:2:2 distorts, H.264 High 4:2:2 stalls the decoder; FFmpeg"
  echo "      players — IINA/VLC/mpv — decode it fine). No container surgery supplies"
  echo "      a missing decoder: mov.sh refuses early (exit 11)."
  echo "      Playback copy: lossless MKV mux. QuickTime-native: scripts/rung4.sh"
  echo "      (operator-attested re-encode) — the only sanctioned path."
fi

echo "-- audio --"
ffprobe -v error -select_streams a -show_entries \
  stream=index,codec_name,codec_tag_string,channels,sample_rate,channel_layout:stream_tags=language \
  -of default=nw=1 "$IN" || true

echo "-- bitstream format --"
isavc=$(ffprobe -v error -select_streams v:0 -show_entries stream=is_avc -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1 || true)
case "$isavc" in
  true)  echo "AVCC (MP4/MKV/MOV) -> add -bsf:v h264_mp4toannexb when EXTRACTING to raw .h264" ;;
  false) echo "Annex-B (TS/PS)    -> NO bitstream filter needed when extracting to raw .h264" ;;
  *)     echo "n/a (not H.264, or undetectable)" ;;
esac

echo "-- field structure & timestamp profile --"
eval "$(pf_detect "$IN")"
eval "$(pf_reorder_scan "$IN")"
echo "field_order=$PF_FIELD  (tt/bb = interlaced; progressive/unknown = usually no field concern)"
echo "coded-picture rate=${PF_CODED_RATE}/s  vs  frame rate=${PF_NOMINAL_FPS}/s  (ratio=${PF_RATIO})"
echo "untimestamped packets: fraction=${PF_NOPTS_FRAC} (half_ts=$PF_HALF_TS)   reorder pyramid: $PF_REORDER (max PTS-DTS ${PF_MAXOFF_TICKS} ticks)"
if [ "$PF_PAFF" = yes ]; then
  echo "   >> FIELD-CODED (PAFF) H.264: coded-picture rate ~2x the frame rate."
  echo "      This is the fragile profile and the one that silently corrupts."
  echo "      genpts (Rung 2) is GUILTY-UNTIL-PROVEN here: it can pass the strict"
  echo "      MKV-mux test yet leave a timeline that tears when a player scrubs."
  if [ "$PF_HALF_TS" = yes ] || [ "$PF_REORDER" = yes ]; then
    echo "      Timestamp profile says KEEP the real PTS (pair-timestamped and/or"
    echo "      reordered — a constant-rate rebuild would play fields in decode order):"
    echo "         scripts/pairfill-paff.sh \"$IN\" OUT.mov"
  elif [ "$PF_FIELD_RATE" = unknown ]; then
    echo "      Go to the field-rate rebuild (Rung 3):"
    echo "         scripts/rebuild-paff.sh \"$IN\" OUT.mov <FIELD_RATE> <TIMESCALE>"
    echo "         (measured ~${PF_CODED_RATE}/s didn't map to a standard rate — pick"
    echo "          from the field-rate table in references/timeline-repair.md)"
  else
    echo "      No reorder survives -> field-rate rebuild (Rung 3):"
    echo "         scripts/rebuild-paff.sh \"$IN\" OUT.mov $PF_FIELD_RATE $PF_TIMESCALE"
  fi
  echo "      Then verify with the scrub gate: scripts/verify.sh \"$IN\" OUT.mov"
else
  echo "   NOTE: not field-coded by the rate test (ratio ~1x; the rate counts ALL"
  echo "   packets, untimestamped ones included — the old timestamped-only count"
  echo "   false-read 1x on pair-timestamped PAFF). If mediainfo says 'Separated"
  echo "   fields' or playback still tears on scrub, treat as PAFF anyway;"
  echo "   see references/timeline-repair.md."
fi

echo "-- discontinuities (forward timestamp gaps) --"
eval "$(disc_scan "$IN")"
if [ "${DISC_COUNT:-0}" -gt 0 ]; then
  echo "   >> ${DISC_COUNT} forward gap(s), first @ ${DISC_FIRST}s (~${DISC_MISSING}s dropped)."
  echo "      Present + monotonic, so the mux 'succeeds' — but a blind -c copy COLLAPSES"
  echo "      these in raw PCM audio and desyncs it. Use scripts/resync.sh, then verify."
else
  echo "   none (video DTS gap-free on the timing axis; safe to plain-copy)."
fi
if [ "${DISC_BACK:-0}" -gt 0 ] || [ "${DISC_DUP:-0}" -gt 0 ]; then
  echo "   >> whole-file DTS rot: backward=${DISC_BACK:-0} duplicate=${DISC_DUP:-0} (the windowed"
  echo "      5000-packet scan can miss these mid-file). Combined with forward gaps on an"
  echo "      mpegts/mpeg2video source this is the unbuildable BACKHAUL class — mov.sh"
  echo "      refuses it early (exit 11); scripts/diagnose.sh prints the routes."
fi

# ms-timebase advisory (QTFF audit 5-4e, C68): conventionality, not repair.
ms_tb_scan
if [ "$MS_TB" = yes ]; then
  echo "-- timescale (ms-quantized source) --"
  echo "   >> video timebase is 1/1000 (Matroska ms quantization). A remux inherits a"
  echo "      coarse MOV timescale with ALTERNATING tick durations (${MS_ALT:-e.g. 33/34 ms})"
  echo "      — source-baked rounding (±0.5 ms), imperceptible; NOT judder introduced"
  echo "      by the remux (C68). Conventionality fix, purely cosmetic:"
  echo "         scripts/remux.sh \"$IN\" OUT.mov --timescale ${TS_HINT:-90000}"
  echo "      (a track-timescale change, never a restamp — a constant-rate restamp on"
  echo "      a reorder-pyramid stream shuffles motion; diagnose.sh's prohibition.)"
fi

echo "-- ffmpeg version & behavior deltas --"
ver=$(ffmpeg -version 2>/dev/null | head -1 | grep -oE "[0-9]+\.[0-9]+" | head -1 || true)
major=${ver%%.*}
echo "ffmpeg $ver"
if [ "${major:-0}" -lt 5 ]; then
  echo "  WARN ffmpeg <5.0: Dolby Vision will NOT survive -c copy. Keep MKV for DV sources."
else
  echo "  OK ffmpeg >=5.0: single-layer Dolby Vision (P5/P8) survives -c copy with -tag:v hvc1."
fi
echo "  NOTE colr atom is written by default on modern ffmpeg; +write_colr is redundant (harmless)."
echo "  NOTE HDR10 mdcv/clli ride in the HEVC SEI, NOT as container boxes ffmpeg writes on copy."
echo "  NOTE MP2 muxes into MOV (tag .mp2) but is non-standard; QuickTime is not expected to play it -> decode to PCM for playback."

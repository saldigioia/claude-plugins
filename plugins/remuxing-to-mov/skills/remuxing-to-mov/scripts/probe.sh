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
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-exit.sh"   # exit-code contract trap (WO 1.4): no stray code escapes
IN="${1:?usage: probe.sh INPUT [--kv|--json]}"; MODE="${2:-human}"
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }
. "$SELF_DIR/lib-probe.sh"  # ffp/FF_INPUT_OPTS: raised probe window on every input open
. "$SELF_DIR/lib-paff.sh"   # shared PAFF detection (coded-picture-rate test)

# --- per-track audio manifest (QTFF audit 5-2a) ---------------------------------
# The audio classifier must see the WHOLE track set, not a:0 — the incident
# blind spot: FLAC-5.1 + MP2-stereo classified 'pcm' off track 1 and silently
# dropped track 2. Emitted as PR_AUD_COUNT + PR_AUD_<n>_{CODEC,CHANNELS,LAYOUT,
# LANG}; layouts are single-quoted (parens) — keys satisfy ^(PR|PF)_[A-Z0-9_]+=.
aud_manifest_kv () {
  ffp -v error -select_streams a \
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
  tb=$(ffp -v error -select_streams v:0 -show_entries stream=time_base -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
  [ "$tb" = 1/1000 ] || return 0
  MS_TB=yes
  MS_ALT=$(ffp -v error -select_streams v:0 -read_intervals '%+#120' -show_entries packet=duration -of csv=p=0 "$IN" 2>/dev/null | \
    grep -v -e N/A -e '^$' | sort | uniq -c | sort -rn | head -2 | awk '{printf "%s%sx%sms", sep, $1, $2; sep=" "}')
  fr=$(ffp -v error -select_streams v:0 -show_entries stream=avg_frame_rate -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
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

# --- measured QT-native video matrix (WO 5.1) -----------------------------------
# vnative CODEC PIX_FMT -> yes|variant|no|na. "Native" means: the codec muxes
# -c copy into MOV AND AVFoundation fully decodes it, MEASURED — never assumed
# from a spec. Ground Rule 6 applies: decode support is a property of the macOS
# it was measured on (C63: Tahoe 26.4 DROPPED MJPEG variants/AIC; C72: 26.6.1
# RESTORED 4:2:2 — the drift runs both ways), so the advisories that consume
# this self-date their bench and playable-check.sh stays the per-file judge.
#   yes     h264 / hevc(needs hvc1) / mpeg2video — the long-standing remux
#           classes — plus the F8 matrix measured 2026-08-14 (macOS 26.6.1,
#           ffmpeg 9.0.1): mpeg4(tag mp4v), MJPEG 4:2:0(jpeg), dvvideo(dvcp),
#           prores(apcn) each mux -c copy and fully decode. 4:2:2 pix_fmts on
#           any of these still get the WO 4.1 post-build empirical proof.
#   variant MJPEG in a non-4:2:0 pix_fmt — the C63 measured-drop class
#           (yuvj422p rendered NO frame and hung qlmanage on macOS 26.5.2):
#           the copy is lossless, playability must be proven on the output.
#   no      outside the measured matrix (vp9/ffv1/legacy cvid...): MOV may
#           carry it, QuickTime playability is unproven here.
#   na      no video stream.
vnative () {
  case "${1:-}" in
    "")    echo na;;
    mjpeg) case "${2:-}" in yuv420p|yuvj420p) echo yes;; *) echo variant;; esac;;
    h264|hevc|mpeg2video|mpeg4|dvvideo|prores) echo yes;;
    *)     echo no;;
  esac
}

# Structured output for auto.sh / batch.sh. The recommended rung is a FIRST guess
# from codec/PAFF/audio only; timestamp-driven escalation (Rung 2/3 on non-PAFF)
# happens reactively in auto.sh from the verify verdict.
probe_struct () {
  local mode="$1" q="ffp -v error -select_streams"
  local container vcodec vtag isavc acodec aaction rung cmd cp ct cs cr pixfmt vnat
  container=$(ffp -v error -show_entries format=format_name -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
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
  vnat=$(vnative "$vcodec" "$pixfmt")
  # a:0 advisory + first-rung pick. aaction=pcm forces Rung 1 (remux --audio
  # pcm) where a plain a:0 copy would be worthless; aaction=copy rides Rung 0,
  # whose default is remux.sh --audio auto — the per-track WO 3.2 whitelist —
  # so ac3 stays copy-class HERE (rung 0 already lands it as announced PCM
  # access per track, and a forced --audio pcm would decode co-present
  # QT-native tracks for nothing).
  case "$acodec" in
    # WO 5.1 addendum: container-framed LPCM outranks everything — mov.sh/
    # remux.sh route it to PCM access (the HDMV-tagged MOV "copy" muxes but NO
    # decoder claims it, WO 3.1); a copy-class advisory here put probe/auto
    # consumers at odds with that fixed routing.
    pcm_bluray|pcm_dvd)          aaction=pcm;;
    mp2|mp1|dts|dca)             aaction=pcm;;   # QuickTime-unplayable
    flac|opus|vorbis|truehd|mlp) aaction=pcm;;   # not MOV-copyable (5-2b alignment)
    dolby_e)                     aaction=specialist;;  # WO 5.2: broadcast
                                                 # mezzanine — PCM-treating it
                                                 # is full-scale noise; mov.sh
                                                 # refuses (exit 11) and names
                                                 # the operator-invoked decode
    "")                          aaction=none;;
    *)                           aaction=copy;;  # QT-native (aac/alac/mp3/raw
                                                 # PCM/eac3 — mp3 plays, C33;
                                                 # pre-5.1 it was misfiled pcm)
                                                 # + ac3 (see WHY above)
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
    printf '{"container":"%s","vcodec":"%s","vtag":"%s","pix_fmt":"%s","vnative":"%s","is_avc":"%s","acodec":"%s","audio_action":"%s","paff":"%s","field_rate":"%s","timescale":"%s","coded_rate":"%s","nominal_fps":"%s","nopts_frac":"%s","half_ts":"%s","reorder":"%s","color_primaries":"%s","color_transfer":"%s","color_space":"%s","color_range":"%s","rec_rung":%s,"rec_cmd":"%s"}\n' \
      "$container" "$vcodec" "$vtag" "${pixfmt:-unknown}" "$vnat" "${isavc:-na}" "${acodec:-none}" "$aaction" "$PF_PAFF" "$PF_FIELD_RATE" "$PF_TIMESCALE" "$PF_CODED_RATE" "$PF_NOMINAL_FPS" "$PF_NOPTS_FRAC" "$PF_HALF_TS" "$PF_REORDER" "${cp:-unknown}" "${ct:-unknown}" "${cs:-unknown}" "${cr:-unknown}" "$rung" "$cmd"
  else
    # values are single tokens (eval-safe + greppable); PR_REC_CMD has spaces -> quote it
    printf 'PR_CONTAINER=%s\nPR_VCODEC=%s\nPR_VTAG=%s\nPR_PIX_FMT=%s\nPR_VNATIVE=%s\nPR_IS_AVC=%s\nPR_ACODEC=%s\nPR_AUDIO_ACTION=%s\nPF_PAFF=%s\nPF_FIELD_RATE=%s\nPF_TIMESCALE=%s\nPF_CODED_RATE=%s\nPF_NOMINAL_FPS=%s\nPF_NOPTS_FRAC=%s\nPF_HALF_TS=%s\nPF_REORDER=%s\nPR_COLOR_PRIMARIES=%s\nPR_COLOR_TRANSFER=%s\nPR_COLOR_SPACE=%s\nPR_COLOR_RANGE=%s\nPR_REC_RUNG=%s\nPR_REC_CMD='"'"'%s'"'"'\n' \
      "$container" "$vcodec" "$vtag" "${pixfmt:-unknown}" "$vnat" "${isavc:-na}" "${acodec:-none}" "$aaction" "$PF_PAFF" "$PF_FIELD_RATE" "$PF_TIMESCALE" "$PF_CODED_RATE" "$PF_NOMINAL_FPS" "$PF_NOPTS_FRAC" "$PF_HALF_TS" "$PF_REORDER" "${cp:-unknown}" "${ct:-unknown}" "${cs:-unknown}" "${cr:-unknown}" "$rung" "$cmd"
    aud_manifest_kv                                                       # 5-2a
    printf 'PR_MS_TB=%s\nPR_TS_HINT=%s\n' "$MS_TB" "${TS_HINT:-none}"    # 5-4e
    printf 'PR_GAMA=%s\nPR_STSD_ENTRY=%s\nPR_STSD_DV=%s\n' \
      "$GAMA" "${STSD_ENTRY:-unknown}" "${STSD_DV:-no}"                  # 5-5b/e
  fi
}
case "$MODE" in --kv|--json) probe_struct "$MODE"; exit 0;; esac

echo "== source: $IN =="
container=$(ffp -v error -show_entries format=format_name -of default=nw=1:nk=1 "$IN")
echo "container : $container"
# --- named-limit advisories (WO 5.4; detail + measurements: known-limits.md) ----
# multi-program TS: every route maps -map 0:v:0 = the FIRST video stream in
# PAT/PMT order — the other programs' VIDEO is never mapped (and that drop is
# silent: the KEEP/DROP manifest covers audio only), while audio from EVERY
# program survives --audio-keep all. Measured 2026-08-14 on constructed
# 2-program fixtures in both PAT orders; the advisory exists so the session
# knows the mux is choosing a program, not taking "the" video.
nprog=$(ffp -v error -show_entries format=nb_programs -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1 || true)
case "$nprog" in ''|*[!0-9]*) nprog=0;; esac
if [ "$nprog" -gt 1 ]; then
  echo "   NOTE $nprog programs in this mux: v:0 = the FIRST video in PAT/PMT order wins; other programs' video is NOT mapped (their audio survives keep-all). Another program: -map 0:p:N intermediate — references/known-limits.md"
fi
# 33-bit PTS wraparound horizon: MPEG-TS PTS is 33 bits @ 90 kHz -> wraps every
# ~26.5 h. ffmpeg unwraps ONE rollover on read (ts-health.sh counts observed
# wraps); >=2 wraps (~53 h) is the NAMED LIMITATION — ambiguous epochs, no
# route repairs it. Advisory fires at >24 h, approaching the horizon.
dur=$(ffp -v error -show_entries format=duration -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1 || true)
if awk -v d="${dur:-0}" 'BEGIN{exit !(d+0>86400)}' 2>/dev/null; then
  echo "   NOTE duration $(awk -v d="$dur" 'BEGIN{printf "%.1f", d/3600}') h (>24 h): 33-bit PTS wraps at ~26.5 h — ffmpeg unwraps ONE rollover; >=2 wraps (~53 h) break. Prove the output timeline: verify.sh gate (d) — references/known-limits.md"
fi

echo "-- video --"
ffp -v error -select_streams v:0 -show_entries \
  stream=codec_name,codec_tag_string,profile,width,height,field_order,pix_fmt,color_primaries,color_transfer,color_space,color_range,is_avc,nal_length_size \
  -of default=nw=1 "$IN" || true
# stsd sample entry + Dolby Vision config visibility (QTFF audit 5-5e): the DV
# playability split rides the sample-entry fourcc (dvh1 plays where the hev1
# family fails); ffprobe's codec_tag_string alone can miss the dvcC/dvvC box.
vtag_h=$(ffp -v error -select_streams v:0 -show_entries stream=codec_tag_string -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
mp4_atom_scan "$container" "$vtag_h"
if [ -n "${STSD_ENTRY:-}" ] && [ "$STSD_ENTRY" != "[0][0][0][0]" ]; then
  echo "stsd sample entry: $STSD_ENTRY${STSD_DV:+ (+Dolby Vision dvcC/dvvC config box)}"
fi
if [ "${GAMA:-unknown}" = yes ]; then
  echo "   WARN legacy 'gama' atom present (pre-2010 QuickTime gamma era): modern"
  echo "        players may render this dark/washed vs an nclc-tagged copy. A -c copy"
  echo "        remux normalizes it; see color-hdr-subs.md (Pre-2010 exports)."
fi
# measured QT-native matrix + contribution profile (WO 5.1 / WO 4.1): codec
# decode verdicts are bench measurements that DRIFT with macOS (C63/C72), so
# every advisory self-dates and playable-check.sh on the finished build stays
# the empirical judge. The pre-1.11 block here still promised a refusal
# ("mov.sh refuses early, exit 11") — the categorical 4:2:2 verdict was
# falsified on the bench 2026-08-13 and demoted to the shared post-build
# proof (lib-paff contribution_advisory, so probe and the builders never
# diverge on the announcement).
vcod_h=$(ffp -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
pix_h=$(ffp -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
case "$(vnative "$vcod_h" "$pix_h")" in
  yes) case "$vcod_h" in mpeg4|mjpeg|dvvideo|prores)
    echo "   QT-native, measured (bench 2026-08-14, macOS 26.6.1/ffmpeg 9.0.1): $vcod_h"
    echo "   muxes -c copy into MOV and AVFoundation fully decodes it -> route: lossless"
    echo "   copy (scripts/mov.sh), never a conversion. Decode support drifts by macOS"
    echo "   (C63) — re-prove on a new bench: scripts/playable-check.sh OUT.mov"
    ;; esac;;
  variant)
    echo "   WARN mjpeg $pix_h: MJPEG 4:2:0 is measured QT-native, but non-4:2:0"
    echo "        variants are the C63 measured-DROP class (Tahoe 26.4; yuvj422p"
    echo "        rendered no frame and hung qlmanage on macOS 26.5.2). The copy is"
    echo "        still lossless — build, then prove the output:"
    echo "        scripts/playable-check.sh OUT.mov (bounded probe; a stall = FAIL)"
    ;;
  no)
    case "$vcod_h" in
      # WO 5.2: the unroutable classes are NOT "MOV may carry it" — the mux
      # itself is impossible (VC-1 has no MOV sample entry; VP9/AV1 the muxer
      # rejects as MP4-only, bench-verified ffmpeg 9.0.1 2026-08-14), so the
      # pre-1.11 generic note here was an overclaim on exactly these codecs.
      vc1|vp9|av1)
        echo "   REFUSED-class: $vcod_h cannot be muxed into MOV at all — no lossless"
        echo "        .mov of this source exists. mov.sh refuses pre-flight with the"
        echo "        routes (exit 11, MOV_REFUSED profile=unroutable-vcodec): keep the"
        echo "        source / lossless -c copy to MP4 (VP9/AV1) or MKV (VC-1) for"
        echo "        playback / scripts/rung4.sh (operator-attested re-encode) for a"
        echo "        QuickTime-native .mov."
        ;;
      *)
        echo "   NOTE ${vcod_h:-?} is outside the measured QT-native matrix: MOV may carry"
        echo "        it, but QuickTime playability is unproven here — prove the finished"
        echo "        build with scripts/playable-check.sh (QuickTime-native fallback:"
        echo "        scripts/rung4.sh, the operator-attested re-encode)"
        ;;
    esac
    ;;
esac
if qt_contribution_profile "$pix_h"; then
  contribution_advisory "$vcod_h" "$pix_h"
fi

echo "-- audio --"
ffp -v error -select_streams a -show_entries \
  stream=index,codec_name,codec_tag_string,channels,sample_rate,channel_layout:stream_tags=language \
  -of default=nw=1 "$IN" || true
# Dolby E detection (WO 5.2) — codec-tagged form only (codec_name dolby_e, any
# track). The PCM-wrapped AES3 form (SMPTE 337M inside a pcm_s16le/s24le
# track) is deliberately NOT sniffed here — payload sync-word inspection is
# the deep-inspection rabbit hole — so that named limitation lives in SKILL.md
# troubleshooting: a broadcast "PCM" track that plays as steady full-scale
# noise is the signature. grep -c consumes to EOF (grep -q would SIGPIPE ffp
# under pipefail — the verify.sh herestring lesson); ||true guards the
# no-match rc under set -e.
dbe_n=$(ffp -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 "$IN" 2>/dev/null | grep -c '^dolby_e' || true)
if [ "${dbe_n:-0}" -gt 0 ]; then
  echo "   WARN Dolby E ($dbe_n track(s)): broadcast mezzanine, up to 8 programs per"
  echo "        AES3 pair. NOT MOV-carriable, and PCM-treating it yields full-scale"
  echo "        noise. mov.sh refuses with the routes (exit 11); the specialist decode"
  echo "        (ffmpeg's dolby_e decoder -> WAV) is a named, operator-invoked step —"
  echo "        program/channel assignment is editorial, never automatic."
fi

echo "-- bitstream format --"
isavc=$(ffp -v error -select_streams v:0 -show_entries stream=is_avc -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1 || true)
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
  # 1.11 (WO 4.2 demotion; wording fixed in the WO 5.2 messaging pass): the
  # pre-1.11 text called this "the unbuildable BACKHAUL class — mov.sh refuses
  # it early (exit 11)". The refusal is gone; the verdict belongs to the
  # measured gates on the actual build.
  echo "   >> whole-file DTS rot: backward=${DISC_BACK:-0} duplicate=${DISC_DUP:-0} (the windowed"
  echo "      5000-packet scan can miss these mid-file). Combined with forward gaps on an"
  echo "      mpegts/mpeg2video source this is the BACKHAUL rot class — since 1.11 mov.sh"
  echo "      WARNS and builds it (MOV_ROT_WARN + the three routes): the mux-confession"
  echo "      gate hard-stops invented timing and verify.sh judges the finished timeline."
  echo "      Full read + routes: scripts/diagnose.sh."
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

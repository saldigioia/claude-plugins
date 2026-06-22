#!/usr/bin/env bash
# verify.sh — prove a remux was lossless and the output timeline is clean,
# at the lowest cost that is actually conclusive.
# Usage: scripts/verify.sh SOURCE OUTPUT [--full] [--signaling] [--audio]
#
# Default tier (NO full decode — I/O-bound, runs at many× realtime):
#   (a) packet-hash identity: -c copy -f streamhash on both files (demux only,
#       zero decode). A match PROVES the copied bitstream is identical — done.
#       A mismatch is INCONCLUSIVE, not a failure: TS sources get SPS/PPS
#       re-placed and Rung-3 rebuilds repacketize, so identical video can hash
#       differently at the packet level. Fall through to (b).
#   (b) lossless essence check (demux only):
#       - H.264: VCL-payload hash with SPS/PPS/AUD/SEI stripped — placement- and
#         re-timing-invariant, so it survives TS->MOV and field-rate rebuilds.
#         REPLACES decoded framemd5 for H.264, which FALSE-FAILs field-coded
#         (PAFF) streams (field-vs-frame packaging) and any rebuild.
#       - other codecs: framemd5 of the first 300 frames (hash column only) +
#         packet-count parity. Catches wrong-stream, corruption-at-head, truncation.
#       - degraded env (no filter_units/h264_mp4toannexb): non-field-coded H.264
#         falls back to framemd5; field-coded -> REVIEW, never a false FAIL.
#         scripts/doctor.sh reports whether the VCL path is available.
#   (c) decode spot-checks of the OUTPUT at middle + tail (10 s windows).
#   (d) backward-DTS recheck on the output (want 0).
#   (e) SCRUB GATE: accurate seeks (-ss AFTER -i) to deliberately off-keyframe
#       targets + keyframe-spacing / single-GOP sanity. Reproduces a GUI scrub
#       (which a keyframe-snap -ss-before-i seek does not), so a glitchy PAFF
#       timeline FAILs here — before the source is deleted.
#
# --full adds a whole-file decoded check: an order/count-tolerant multiset for
# H.264 (corroboration only — a positional compare false-fails field-coded), or
# a bit-exact rawvideo md5 for other codecs. Reserve it for archival sign-off,
# or to settle a REVIEW verdict from the default tier.
#
# Optional preservation checks (off by default; they don't affect the lossless
# verdict unless they find real loss):
#   --signaling : color/HDR tags + HEVC hvc1 + HDR side data + closed-caption
#                 presence, source vs output. Drift -> REVIEW.
#   --audio     : dual-track fidelity — the preserved original track must be
#                 bit-exact vs source (else FAIL) and the PCM access track must
#                 equal the decoded original, aligned (else REVIEW).
set -euo pipefail
SRC="${1:?usage: verify.sh SOURCE OUTPUT [--full] [--signaling] [--audio]}"; OUT="${2:?need OUTPUT}"; shift 2
FULL=0; SIG=0; AUD=0
while [ $# -gt 0 ]; do case "$1" in
  --full) FULL=1; shift;;
  --signaling) SIG=1; shift;;          # color/HDR/caption preservation (source vs output)
  --audio) AUD=1; shift;;              # dual-track audio fidelity (PCM access + original)
  "") shift;;                          # tolerate an empty arg from `verify.sh A B $FULL`
  *) echo "unknown opt: $1" >&2; exit 2;;
esac; done
for f in "$SRC" "$OUT"; do [ -f "$f" ] || { echo "no such file: $f" >&2; exit 2; }; done
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-paff.sh"
eval "$(pf_detect "$SRC")"            # PF_CODEC / PF_PAFF describe the SOURCE
SRC_IS_H264=0; [ "$PF_CODEC" = h264 ] && SRC_IS_H264=1
# The H.264 VCL lossless arbiter needs filter_units + h264_mp4toannexb. On an
# ffmpeg that lacks them, DON'T false-FAIL — degrade (see step b). Herestring
# match avoids a pipefail SIGPIPE false-negative. RTM_FORCE_NO_VCL=1 forces the
# degraded path for testing. (scripts/doctor.sh reports this capability.)
BSFS_AVAIL=$(ffmpeg -hide_banner -bsfs 2>/dev/null || true)
HAVE_VCL=0
{ grep -qw filter_units <<<"$BSFS_AVAIL" && grep -qw h264_mp4toannexb <<<"$BSFS_AVAIL"; } && HAVE_VCL=1
[ "${RTM_FORCE_NO_VCL:-0}" = 1 ] && HAVE_VCL=0

N=300            # frames in the decoded head sample (~10-12 s of video)
WIN=10           # seconds per output decode spot-check window
verdict=PASS     # PASS | REVIEW | FAIL — only ever downgraded
note=""

echo "== verify: $OUT vs $SRC =="

echo "-- (a) packet-hash identity (demux only, no decode) --"
phash () { ffmpeg -nostdin -v error -i "$1" -map 0:v:0 -c copy -f streamhash -hash md5 - 2>/dev/null || true; }
# VCL-payload hash: strip SPS(7)/PPS(8)/AUD(9)/SEI(6) so parameter-set placement
# (TS in-band vs MOV avcC) and a Rung-3 repacketization cannot false-mismatch.
# What remains is the coded picture data — the correct lossless arbiter for H.264,
# and the reason decoded framemd5 is NOT used here: it FALSE-FAILs field-coded
# (PAFF) streams (field-vs-frame packaging) and any re-timed rebuild.
vcl_hash () { local b=""; \
  [ "$(ffprobe -v error -select_streams v:0 -show_entries stream=is_avc -of default=nw=1:nk=1 "$1" 2>/dev/null | head -1)" = true ] && b="h264_mp4toannexb,"; \
  ffmpeg -nostdin -v error -i "$1" -map 0:v:0 -c:v copy -bsf:v "${b}filter_units=remove_types=6|7|8|9" -f streamhash -hash md5 - 2>/dev/null || true; }
sp=$(phash "$SRC"); op=$(phash "$OUT")
if [ -n "$sp" ] && [ "$sp" = "$op" ]; then
  echo "   PASS: video packets bit-identical — lossless proven, no decode needed."
  bitproven=1
else
  echo "   inconclusive (expected for TS sources / Rung-3 rebuilds: packets get"
  echo "   re-framed even when the video is identical) — checking the essence."
  bitproven=0
fi

if [ "$bitproven" -eq 0 ]; then
  if [ "$SRC_IS_H264" -eq 1 ] && [ "$HAVE_VCL" -eq 1 ]; then
    echo "-- (b) VCL-payload identity (demux only; lossless arbiter for H.264) --"
    sv=$(vcl_hash "$SRC"); ov=$(vcl_hash "$OUT")
    if [ -n "$sv" ] && [ "$sv" = "$ov" ]; then
      echo "   VCL MATCH: coded picture data bit-identical — lossless proven"
      echo "   (survives TS->MOV and field-rate rebuilds; framemd5 would false-FAIL here)."
      bitproven=1
    else
      echo "   VCL MISMATCH — slice data differs; output is NOT a lossless copy."
      echo "     src=$sv"
      echo "     out=$ov"
      verdict=FAIL
    fi
  elif [ "$SRC_IS_H264" -eq 1 ] && [ "$PF_PAFF" = yes ]; then
    # Degraded env (no filter_units) + field-coded: VCL is unavailable and decoded
    # framemd5 FALSE-FAILs PAFF — so we must NOT FAIL. Flag for a definitive check.
    echo "-- (b) lossless essence: VCL hash unavailable for a field-coded source --"
    echo "   filter_units/h264_mp4toannexb missing in this ffmpeg, and decoded"
    echo "   framemd5 false-FAILs field-coded streams — cannot cheaply prove lossless."
    [ "$verdict" = FAIL ] || verdict=REVIEW
    note="${note:+$note }VCL check unavailable (upgrade ffmpeg, or run --full); field-coded source can't be cheaply proven lossless."
  else
    echo "-- (b) decoded spot-identity: first $N frames + packet-count parity --"
    fhead () { ffmpeg -nostdin -v error -i "$1" -map 0:v:0 -frames:v "$N" -f framemd5 - 2>/dev/null \
                 | grep -v '^#' | awk -F', *' '{print $NF}' || true; }
    sh=$(fhead "$SRC"); oh=$(fhead "$OUT")
    if [ -n "$sh" ] && [ "$sh" = "$oh" ]; then
      echo "   head sample: MATCH ($N decoded frames identical)"
    else
      echo "   head sample: FAIL — decoded frames differ; output is NOT a lossless copy."
      verdict=FAIL
    fi
    # TS sources list the stream under its program AND top-level -> dedupe to one line
    pkts () { ffprobe -v error -select_streams v:0 -count_packets \
                -show_entries stream=nb_read_packets -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n1; }
    spk=$(pkts "$SRC"); opk=$(pkts "$OUT")
    echo "   video packets: source=$spk output=$opk"
    if [ "$spk" != "$opk" ] && [ "$verdict" = PASS ]; then
      verdict=REVIEW
      note="packet counts differ — fine after a Rung-3 rebuild (repacketization), otherwise possible truncation. Settle with --full."
    fi
  fi
fi

echo "-- (c) output decode spot-checks (${WIN}s windows) --"
dur=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT" 2>/dev/null) || dur=0
case "$dur" in ''|N/A) dur=0;; esac
# Decode the output and count ffmpeg error-level lines. A REAL decode error
# (bitstream corruption) is deterministic and recurs on every pass; a stray line
# emitted under heavy host load is not. So `confirm` re-decodes a nonzero result
# (up to twice more) and keeps the MINIMUM — this drops load-induced false
# positives without ever masking a reproducible error (which stays nonzero).
decode_win () {  # $1 optional start time; empty -> whole file
  if [ -n "${1:-}" ]; then
    ffmpeg -nostdin -v error -ss "$1" -t "$WIN" -i "$OUT" -map 0:v:0 -map '0:a?' -f null - 2>&1 | grep -c . || true
  else
    ffmpeg -nostdin -v error -i "$OUT" -map 0:v:0 -map '0:a?' -f null - 2>&1 | grep -c . || true
  fi
}
confirm () {  # re-confirm a nonzero count; keep the min, bail early on a clean pass
  local n m i; n=$(decode_win "${1:-}"); i=0
  while [ "$n" -ne 0 ] && [ "$i" -lt 4 ]; do m=$(decode_win "${1:-}"); [ "$m" -lt "$n" ] && n=$m; i=$((i+1)); done
  printf '%s' "$n"
}
if awk "BEGIN{exit !($dur < 4*$WIN)}"; then
  errs=$(confirm)
  echo "   short file — full output decode: $errs errors (want 0)"
else
  mid=$(awk "BEGIN{printf \"%.2f\", $dur/2}")
  tail=$(awk "BEGIN{printf \"%.2f\", $dur-$WIN-2}")
  em=$(confirm "$mid"); et=$(confirm "$tail")
  echo "   middle @${mid}s: $em errors; tail @${tail}s: $et errors (want 0)"
  errs=$((em + et))
fi
[ "$errs" -eq 0 ] || { [ "$verdict" = FAIL ] || verdict=REVIEW; note="${note:+$note }Output decode errors in spot windows."; }

echo "-- (d) backward-DTS on output --"
back=$(ffprobe -v error -select_streams v:0 -read_intervals "%+#3000" \
  -show_entries packet=dts -of csv=p=0 "$OUT" 2>/dev/null | \
  awk -F, 'NR>1 && $1!="N/A" && p!="N/A" && $1<p {b++} {p=$1} END{print b+0}')
echo "   backward-DTS: ${back:-0} (want 0)"
[ "${back:-0}" -eq 0 ] || { [ "$verdict" = FAIL ] || verdict=REVIEW; note="${note:+$note }Non-monotonic DTS on output."; }

echo "-- (e) scrub gate: player-style off-keyframe seeks + keyframe sanity --"
# WHY: the demux/keyframe-accurate checks above (and an -ss-before-i spot decode)
# snap to a keyframe and decode forward — they stayed clean on the corrupted PAFF
# file. A GUI scrub instead lands at arbitrary, often non-keyframe positions and
# follows the container seek index/edit list, which is what tore. This gate
# reproduces that: accurate seeks (-ss AFTER -i) to deliberately off-keyframe
# targets, plus a keyframe-spacing sanity check. Errors here FAIL the file so a
# glitchy timeline is caught BEFORE the source is deleted.
case "${dur:-0}" in ''|N/A) dur=0;; esac
kf=$(ffprobe -v error -select_streams v:0 -show_entries packet=pts_time,flags -of csv=p=0 "$OUT" 2>/dev/null \
      | awk -F, '$2 ~ /K/ && $1!="N/A" && $1!="" {print $1}' | sort -n | uniq)
nkf=$(printf '%s\n' "$kf" | grep -c . || true)
echo "   keyframes in output: $nkf"
if [ "${nkf:-0}" -lt 2 ]; then
  echo "   only ${nkf:-0} keyframe(s) — no interior scrub target; a scrub must decode"
  echo "   from the previous keyframe (potentially the file start)."
  if awk "BEGIN{exit !(${dur:-0} > 30)}"; then
    [ "$verdict" = FAIL ] || verdict=REVIEW
    note="${note:+$note }Single-GOP/unseekable output (${nkf:-0} keyframe over ${dur}s)."
  fi
else
  maxgap=$(printf '%s\n' "$kf" | awk 'NR>1{g=$1-p; if(g>m)m=g} {p=$1} END{printf "%.2f", m+0}')
  echo "   max keyframe gap: ${maxgap}s"
  samples=$(printf '%s\n' "$kf" | awk -v n=6 '{a[NR]=$1} END{
      if(NR<2) exit; step=(NR-1)/n; if(step<1)step=1;
      for(i=1; c<n; i+=step){ idx=int(i); if(idx<1)idx=1; if(idx+1>NR) break;
        kfb=a[idx]; nxt=a[idx+1]; if(nxt>kfb){c++; printf "%.3f %.3f\n", kfb, (nxt-kfb)/2} }}')
  serr=0; ntests=0
  while read -r kfb delta; do
    [ -n "$kfb" ] || continue
    ntests=$((ntests+1))
    # fast input-seek to the preceding keyframe, then ACCURATE output-seek to the
    # non-keyframe midpoint (-ss after -i): a player landing mid-GOP via the index.
    e=$(ffmpeg -nostdin -v error -ss "$kfb" -i "$OUT" -ss "$delta" -t 4 -map 0:v:0 -f null - 2>&1 | grep -c . || true)
    serr=$((serr + e))
  done <<EOF
$samples
EOF
  echo "   off-keyframe accurate seeks: $ntests point(s), $serr decode error(s) (want 0)"
  if [ "${serr:-0}" -gt 0 ]; then
    verdict=FAIL
    note="${note:+$note }Scrub gate: $serr decode error(s) on off-keyframe seeks — the timeline tears on scrub (silent-corruption signature). Rebuild at the field rate."
  fi
fi

if [ "$FULL" -eq 1 ]; then
  if [ "$SRC_IS_H264" -eq 1 ]; then
    echo "-- (--full) whole-file decoded multiset identity (H.264) --"
    # For H.264 the VCL hash in (b) is the bit-exact lossless proof. A decoded
    # compare is corroboration only and must be ORDER/COUNT-tolerant: field-coded
    # rebuilds legitimately present a different frame count (field-vs-frame / edit
    # list), so a positional rawvideo md5 would FALSE-FAIL. Compare the sorted
    # multiset of frame hashes instead, and never FAIL on it alone.
    setmd5 () { ffmpeg -nostdin -v error -i "$1" -map 0:v:0 -f framemd5 - 2>/dev/null \
                  | grep -v '^#' | awk -F', *' '{print $NF}' | sort | md5sum | awk '{print $1}'; }
    s=$(setmd5 "$SRC"); d=$(setmd5 "$OUT")
    echo "   source multiset=$s"
    echo "   output multiset=$d"
    if [ "$s" = "$d" ]; then
      echo "   PASS: decoded frame multiset identical (VCL hash already proved lossless)."
      [ "$verdict" = REVIEW ] && { verdict=PASS; note=""; }
    else
      echo "   NOTE: decoded multiset differs — expected for a field-coded / edit-list"
      echo "   rebuild (different presented frame count). The VCL hash in (b) is the"
      echo "   authoritative lossless proof; not downgrading on this alone."
    fi
  else
    echo "-- (--full) whole-file decoded-pixel identity (two full decodes) --"
    fmd5 () { ffmpeg -nostdin -v error -i "$1" -map 0:v:0 -c:v rawvideo -f md5 - | sed 's/^MD5=//'; }
    s=$(fmd5 "$SRC"); d=$(fmd5 "$OUT")
    echo "   source=$s"
    echo "   output=$d"
    if [ "$s" = "$d" ]; then
      echo "   PASS: every decoded frame is bit-identical."
      [ "$verdict" = REVIEW ] && { verdict=PASS; note=""; }   # definitive check overrides sampled doubt
    else
      echo "   FAIL: decoded frames differ — output is NOT a lossless copy."
      verdict=FAIL
    fi
  fi
fi

if [ "$SIG" -eq 1 ]; then
  echo "-- (--signaling) color / HDR / caption preservation (source vs output) --"
  sg () { ffprobe -v error -select_streams v:0 -show_entries stream="$2" -of default=nw=1:nk=1 "$1" 2>/dev/null | head -1; }
  sdrift=0
  for k in color_primaries color_transfer color_space color_range; do
    a=$(sg "$SRC" "$k"); b=$(sg "$OUT" "$k")
    if [ "$a" != "$b" ]; then echo "   $k: source=$a output=$b  (DRIFT)"; sdrift=1; else echo "   $k=$a (preserved)"; fi
  done
  if [ "$PF_CODEC" = hevc ]; then
    t=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_tag_string -of default=nw=1:nk=1 "$OUT" 2>/dev/null | head -1)
    [ "$t" = hvc1 ] && echo "   HEVC tag=hvc1 (QuickTime-playable)" || { echo "   HEVC tag=$t — NOT hvc1; QuickTime won't play it (DRIFT)"; sdrift=1; }
  fi
  ccs=$(ffprobe -v error -select_streams v:0 -show_entries stream=closed_captions -of default=nw=1:nk=1 "$SRC" 2>/dev/null | head -1)
  cco=$(ffprobe -v error -select_streams v:0 -show_entries stream=closed_captions -of default=nw=1:nk=1 "$OUT" 2>/dev/null | head -1)
  if [ "${ccs:-0}" = 1 ] && [ "${cco:-0}" != 1 ]; then echo "   closed captions: present in source, MISSING in output (DRIFT)"; sdrift=1
  else echo "   closed captions: source=${ccs:-0} output=${cco:-0}"; fi
  hs=$(ffprobe -v error -select_streams v:0 -read_intervals "%+#1" -show_entries frame=side_data_type -of csv=p=0 "$SRC" 2>/dev/null | tr '\n' ';')
  ho=$(ffprobe -v error -select_streams v:0 -read_intervals "%+#1" -show_entries frame=side_data_type -of csv=p=0 "$OUT" 2>/dev/null | tr '\n' ';')
  case "$hs" in *"Mastering display"*|*"Content light"*)
    case "$ho" in *"Mastering display"*|*"Content light"*) echo "   HDR mastering/CLL side data preserved";;
      *) echo "   HDR mastering/CLL side data in source, MISSING in output (DRIFT)"; sdrift=1;; esac;;
  esac
  [ "$sdrift" -eq 0 ] && echo "   signaling: no drift" || { [ "$verdict" = FAIL ] || verdict=REVIEW; note="${note:+$note }Signaling/caption drift (see --signaling)."; }
fi

if [ "$AUD" -eq 1 ]; then
  echo "-- (--audio) dual-track audio fidelity (PCM access + preserved original) --"
  na=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$OUT" 2>/dev/null | grep -c . || true)
  a0c=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$OUT" 2>/dev/null | head -1)
  if [ "${na:-0}" -lt 2 ]; then
    echo "   output has ${na:-0} audio track(s); dual-track checks need PCM access + original. Skipping."
  elif case "$a0c" in pcm_*) false;; *) true;; esac; then
    echo "   a:0 is '$a0c', not PCM — not a dual-track-access layout. Skipping."
  else
    raw=${a0c#pcm_}
    a1c=$(ffprobe -v error -select_streams a:1 -show_entries stream=codec_name -of default=nw=1:nk=1 "$OUT" 2>/dev/null | head -1)
    drc=""; case "$a1c" in ac3|eac3) drc="-drc_scale 0";; esac     # match dual-track.sh's default
    s1=$(ffmpeg -nostdin -v error -i "$SRC" -map 0:a:0 -c copy -f streamhash -hash md5 - 2>/dev/null || true)
    o1=$(ffmpeg -nostdin -v error -i "$OUT" -map 0:a:1 -c copy -f streamhash -hash md5 - 2>/dev/null || true)
    if [ -n "$s1" ] && [ "$s1" = "$o1" ]; then echo "   original track (a:1): bit-exact vs source — preserved."
    else echo "   original track (a:1): NOT bit-exact vs source — provenance track corrupted."; verdict=FAIL; fi
    # shellcheck disable=SC2086
    d0=$(ffmpeg -nostdin -v error -i "$OUT" -map 0:a:0 -c:a "$a0c" -f "$raw" - 2>/dev/null | md5sum | awk '{print $1}')
    # shellcheck disable=SC2086
    d1=$(ffmpeg -nostdin -v error $drc -i "$OUT" -map 0:a:1 -c:a "$a0c" -f "$raw" - 2>/dev/null | md5sum | awk '{print $1}')
    if [ "$d0" = "$d1" ]; then echo "   access track (a:0 PCM): == decoded original, aligned."
    else echo "   access track (a:0): NOT aligned with the original decode."; [ "$verdict" = FAIL ] || verdict=REVIEW; note="${note:+$note }Dual-track audio misaligned."; fi
  fi
fi

case "$verdict" in
  PASS)
    if [ "$bitproven" -eq 1 ] || [ "$FULL" -eq 1 ]; then echo ">> OK (lossless proven; timeline scrub-clean)"
    else echo ">> OK (sampled checks; scrub-clean; for archival sign-off run again with --full)"; fi ;;
  REVIEW) echo ">> REVIEW: $note" ;;
  FAIL)   echo ">> FAIL (see above)"; exit 1 ;;
esac

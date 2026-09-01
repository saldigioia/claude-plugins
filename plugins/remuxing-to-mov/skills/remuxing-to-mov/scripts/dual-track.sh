#!/usr/bin/env bash
# dual-track.sh — build a QuickTime-ready, minimal-loss MOV with a PCM "access"
# track as the DEFAULT first audio track, and the ORIGINAL audio preserved
# bit-exact as a second track. Non-destructive: writes a NEW file, never the source.
#
# This is the recommended DEFAULT deliverable: it always plays in stock QuickTime
# (PCM track 1) while losing as little as possible (original bitstream kept as
# track 2 for provenance / re-derivation).
#
# Usage:
#   dual-track.sh INPUT OUTPUT.mov [--ss START] [--to END] \
#                 [--pcm auto|16|24|32] [--drc auto|off|on]
#
#   --ss/--to  : optional lossless cut (keyframe-bound). START/END accept seconds
#                or HH:MM:SS.mmm. Omit for a full-file build.
#                ORIGIN (WO 1.3, measured): --ss/--to are relative to the
#                container's start_time, NOT absolute stream PTS. On a
#                start_time=1372.69 capture, the keyframe observed at PTS
#                1374.27 is cut with --ss 1.58 — passing 1374.27 itself seeks
#                past EOF. Pre-1.3 that wrote an EMPTY file with exit 0; a
#                guard after the copy-cut pass now FAILs it instead.
#   --pcm auto : pick PCM depth from the decoder's native sample format
#                (s16->16, flt/fltp->24, s32->32). Override with 16|24|32.
#   --drc auto : disable AC-3/E-AC-3 dynamic-range compression (full dynamic
#                range, audiophile default). Use --drc on to keep broadcast DRC.
#
# Video is ALWAYS -c:v copy (bit-identical); HEVC tagged hvc1. Output is atomic
# (.part -> mv) and faststart. ALWAYS verify after (see dual-track-quicktime.md).
#
# WHY TWO PASSES WHEN CUTTING: doing the cut and the decode in one pass with -ss
# before -i, while mapping the same audio twice (one decoded, one copied), trims
# the decoded PCM to the seek time but keeps whole frames on the copied track —
# leaving the two audio tracks offset by up to ~0.5 s. So when a cut is requested
# we (1) lossless-copy-cut first, then (2) decode+copy from that cut with NO -ss,
# which guarantees both audio tracks share identical frames and stay aligned.
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-exit.sh"   # exit-code contract trap (WO 1.4): the measured 234 leak dies here

IN="${1:?usage: dual-track.sh INPUT OUTPUT.mov [--ss START] [--to END] [--pcm auto|16|24|32] [--drc auto|off|on]}"
OUT="${2:?need OUTPUT.mov}"; shift 2
SS=""; TO=""; PCMOPT=auto; DRCOPT=auto
while [ $# -gt 0 ]; do case "$1" in
  --ss)  SS="$2";  shift 2;;
  --to)  TO="$2";  shift 2;;
  --pcm) PCMOPT="$2"; shift 2;;
  --drc) DRCOPT="$2"; shift 2;;
  *) echo "unknown opt: $1" >&2; exit 2;;
esac; done
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }
. "$SELF_DIR/lib-probe.sh"  # ffp/FF_INPUT_OPTS: raised probe window on every input open
. "$SELF_DIR/lib-paff.sh"   # mux_confessions, backhaul_gate
. "$SELF_DIR/lib-mux.sh"    # rtm_part (extension-keeping atomics), mux_census (D5)
rtm_sibling_guard "$IN" "$OUT" || exit 2   # TIER 1 T1.11 write beside the source, never onto it (one writer: lib-mux.sh)

# backhaul gate (1.11: advises + warns, refuses nothing — the 4:2:2 advisory
# defers to the post-build proof, rot WARNs and builds; lib-paff.sh) — this
# script writes a .mov directly (it bypasses remux.sh), so the advisory fires
# here too; a gated caller (mov.sh) exports RTM_BACKHAUL_GATED=1 and skips it.
backhaul_gate "$IN" || exit $?

# --- probe source (never guess) ---
# SCOPE (QTFF audit 5-2d): this tool builds ONE access+original pair from a:0,
# by design — the two-pass cut alignment, verify.sh --audio's fixed
# a:0-PCM/a:1-original shape, and the C41-verified disposition pattern all
# assume the single-pair layout. A multi-track source loses its other tracks
# HERE, so say it loudly (mov.sh's layouts policy is the multi-layout route;
# it keeps every distinct layout as an access track, without originals).
NAUD=$(ffp -v error -select_streams a -show_entries stream=index -of csv=p=0 "$IN" 2>/dev/null | sort -u | grep -c . || true)
if [ "${NAUD:-0}" -gt 1 ]; then
  echo "** WARNING: source has $NAUD audio tracks; dual-track.sh builds the a:0"
  echo "**          access+original pair ONLY. The other tracks are NOT in this"
  echo "**          output. For multi-layout keeps use scripts/mov.sh (layouts"
  echo "**          policy; PCM access per layout, no originals), or run the"
  echo "**          manual mux with extra -map 0:a:N entries."
fi
acodec=$(ffp1 -v error -select_streams a:0 -show_entries stream=codec_name   -of default=nw=1:nk=1 "$IN")
afmt=$(  ffp1 -v error -select_streams a:0 -show_entries stream=sample_fmt   -of default=nw=1:nk=1 "$IN")
vcodec=$(ffp1 -v error -select_streams v:0 -show_entries stream=codec_name   -of default=nw=1:nk=1 "$IN")
cp=$(    ffp1 -v error -select_streams v:0 -show_entries stream=color_primaries -of default=nw=1:nk=1 "$IN")
[ -n "$acodec" ] || { echo "no audio stream found in $IN" >&2; exit 2; }
# the preserved-original contract needs a MOV-copyable codec; FLAC/Opus/Vorbis/
# TrueHD are hard-rejected by the MOV muxer — refuse early with the route,
# instead of dying mid-mux with raw ffmpeg errors (QTFF audit 5-2d)
case "$acodec" in flac|opus|vorbis|truehd|mlp)
  echo "a:0 is $acodec — not MOV-copyable, so the 'original preserved as track 2'" >&2
  echo "contract is impossible in a .mov. Use scripts/remux.sh --audio pcm (access" >&2
  echo "track only; keep the source container for provenance), or scripts/mov.sh" >&2
  echo "which routes this automatically." >&2
  exit 2;;
esac

# --- choose PCM depth (override or auto from decoder native fmt) ---
case "$PCMOPT" in
  16) PCMC=pcm_s16le; BITS=16;;
  24) PCMC=pcm_s24le; BITS=24;;
  32) PCMC=pcm_s32le; BITS=32;;
  auto) case "$afmt" in
          s16|s16p) PCMC=pcm_s16le; BITS=16;;   # e.g. 16-bit DTS-HD MA -> bit-exact
          s32|s32p) PCMC=pcm_s32le; BITS=32;;
          *)        PCMC=pcm_s24le; BITS=24;;   # flt/fltp/dbl (AC-3 etc.) -> 24-bit
        esac;;
  *) echo "bad --pcm: $PCMOPT" >&2; exit 2;;
esac

# --- DRC handling (AC-3 / E-AC-3 only) ---
DRC=""
case "$acodec" in
  ac3|eac3) case "$DRCOPT" in
              auto|off) DRC="-drc_scale 0";;   # full dynamic range (default)
              on) DRC="";;
              *) echo "bad --drc: $DRCOPT" >&2; exit 2;;
            esac;;
esac

VTAG=""; VBSF=()
if [ "$vcodec" = hevc ]; then
  VTAG="-tag:v hvc1"
  # PS-less hvcC stub reroute (1.19.0; full rationale at remux.sh's twin site):
  # hvc1 + a numOfArrays=0 stub = silent EMPTY hvcC, undecodable output. The
  # inline bsf rebuilds the config from the in-band sets; timestamps untouched.
  if rtm_hevc_ps_stub "$IN"; then
    echo "** HEVC decoder config is a PS-less hvcC stub — rerouting via the inline"
    echo "   hevc_mp4toannexb bsf (same mux, same timestamps; see remux.sh / known-limits.md)."
    echo "RMX_HVCC route=annexb-bsf reason=ps-stub"   # machine-readable (additive, 1.19.0)
    VBSF=(-bsf:v hevc_mp4toannexb)
  fi
fi
CFLAG=""; { [ -n "$cp" ] && [ "$cp" != unknown ]; } && CFLAG="+write_colr"
MOVFLAGS=$(rtm_movflags "$CFLAG")   # 1.16.7: faststart by default, knob announced
MOVF=(); [ -n "$MOVFLAGS" ] && MOVF=(-movflags "$MOVFLAGS")
rtm_faststart_announce dual-track.sh
# the copy-cut intermediate is a .mov write too, so it follows the same policy
CUTMOVFLAGS=$(rtm_movflags); CUTMOVF=()
[ -n "$CUTMOVFLAGS" ] && CUTMOVF=(-movflags "$CUTMOVFLAGS")
trap 'rtm_unlock' EXIT   # writer-lock release however this run ends (WO-1.15.6 A2)
rtm_writer_preflight "$OUT" "$IN" || exit 2
PART="$(rtm_part "$OUT")"   # extension-keeping (D6) + unique per process (A2)

# track titles, self-describing
T1="PCM ${BITS}-bit (access)"
T2="$(echo "$acodec" | tr a-z A-Z) (original)"

echo "source: video=$vcodec  audio=$acodec ($afmt)  -> track1=$PCMC  track2=copy  ${DRC:+[DRC disabled]}"

build_from () {  # build_from SRC  -- decode a:0 to PCM (track1, default) + copy a:0 (track2)
  local SRC="$1" MUXLOG conf; MUXLOG="$(mktemp)"
  bf_mux () {  # bf_mux INPUT_OPT... — one attempt; only the probe window varies (WO 1.2)
    # shellcheck disable=SC2086
    ffmpeg -nostdin -y -hide_banner -nostats $DRC "$@" -i "$SRC" \
      -map 0:v:0 -map 0:a:0 -map 0:a:0 \
      -c:v copy $VTAG ${VBSF[@]+"${VBSF[@]}"} -c:a:0 $PCMC -c:a:1 copy \
      -disposition:a:0 default -disposition:a:1 0 \
      -metadata:s:a:0 title="$T1" -metadata:s:a:0 language=eng \
      -metadata:s:a:1 title="$T2" -metadata:s:a:1 language=eng \
      ${MOVF[@]+"${MOVF[@]}"} -f mov "$PART" 2>"$MUXLOG"
  }
  if ! bf_mux "${FF_INPUT_OPTS[@]}"; then
    # probe-shaped failure = window undershot, not a mux defect -> retry ONCE at
    # 1G (lib-paff.sh, WO 1.2); anything else fails now, and so does a second
    # miss — the retry never masks a genuinely different error (contract: 1 FAIL)
    if probe_shaped_failure "$MUXLOG"; then
      probe_retry_notice
      bf_mux "${FF_RETRY_OPTS[@]}" || { echo ">> mux FAILED (after 1G retry):"; sed 's/^/   /' "$MUXLOG" | tail -8; exit 1; }
    else
      echo ">> mux FAILED:"; sed 's/^/   /' "$MUXLOG" | tail -8; exit 1
    fi
  fi
  [ -s "$MUXLOG" ] && sed 's/^/   mux: /' "$MUXLOG" | tail -6
  # HARD STOP: mux-log timeline confessions mean the muxer invented timing —
  # never bless that output (post-mortem 2026-07-25). Stream-scoped (1.14 /
  # DF-10): only VIDEO (or unattributable) confessions hard-stop; audio/
  # subtitle DTS nudges are the ms-quantization class -> announced + REVIEW.
  eval "$(mux_confessions_scoped "$MUXLOG" 0)"   # video is output stream 0:0 (mapped first)
  conf=${MC_VIDEO:-0}
  if [ "${conf:-0}" -gt 0 ]; then
    echo ">> HARD STOP: mux log shows $conf timeline confession(s) (pts has no value /"
    echo "   Timestamps are unset / non-monotonic DTS). NOT blessing the output;"
    echo "   kept at $PART (log: $MUXLOG). Run scripts/diagnose.sh \"$IN\" first."
    exit 1
  fi
  if [ "${MC_AUDSUB:-0}" -gt 0 ]; then
    echo ">> REVIEW: $MC_AUDSUB audio DTS nudges (ms-quantization class) — not video timing"
    echo "   invention; verify gates (f)/(g) judge audio. Building on; exit will say 10."
    echo "RMX_CONFESS stage=dual-track video=0 audsub=${MC_AUDSUB} unattr=${MC_UNATTR:-0}"   # machine-readable (additive, DF-10 1.14)
    DT_CONF_REVIEW=10
  fi
  rm -f "$MUXLOG"
}

if [ -n "$SS" ] || [ -n "$TO" ]; then
  # TWO PASS: lossless copy-cut, then decode+copy from the cut (no -ss) => aligned tracks
  TMP="${OUT%.*}.dtcut.tmp.mov"
  echo "pass 1/2: lossless copy-cut${SS:+ from $SS}${TO:+ to $TO}"
  # pass 1 is the mux that opens the RAW SOURCE on a cut run (pass 2 reads the
  # cut MOV, whose header carries the parameter sets) — so the probe-shaped
  # retry lives here too, or the --ss/--to path would keep the old hard FAIL
  CUTLOG="$(mktemp)"
  cut_mux () {  # cut_mux INPUT_OPT... — one attempt; only the probe window varies (WO 1.2)
    # shellcheck disable=SC2086
    ffmpeg -nostdin -y -hide_banner -nostats ${SS:+-ss "$SS"} ${TO:+-to "$TO"} "$@" -i "$IN" \
      -map 0:v:0 -map 0:a:0 -c copy \
      -avoid_negative_ts make_zero ${CUTMOVF[@]+"${CUTMOVF[@]}"} -f mov "$TMP" 2>"$CUTLOG"
  }
  if ! cut_mux "${FF_INPUT_OPTS[@]}"; then
    if probe_shaped_failure "$CUTLOG"; then
      probe_retry_notice
      cut_mux "${FF_RETRY_OPTS[@]}" || { echo ">> copy-cut FAILED (after 1G retry):"; sed 's/^/   /' "$CUTLOG" | tail -8; exit 1; }
    else
      echo ">> copy-cut FAILED:"; sed 's/^/   /' "$CUTLOG" | tail -8; exit 1
    fi
  fi
  rm -f "$CUTLOG"
  # GUARD (WO 1.3, measured): --ss is relative to the container's start_time,
  # NOT absolute PTS — on a start_time=1372.69 file, --ss 1374.27 (the observed
  # keyframe PTS) seeks past EOF, and ffmpeg exits 0 on the empty cut. Left
  # unguarded that becomes either an empty "success" or a baffling pass-2
  # "Stream map '' matches no streams" death, with the cut temp littered behind.
  # So: the cut must be non-empty AND carry >= 1 video packet, or we FAIL here
  # with the origin spelled out, and the partial cut does not survive (atomic).
  npkt=$(ffp -v error -select_streams v:0 -show_entries packet=dts -of csv=p=0 \
           -read_intervals '%+#1' "$TMP" 2>/dev/null | grep -c . || true)
  if [ ! -s "$TMP" ] || [ "${npkt:-0}" -eq 0 ]; then
    st=$(ffp1 -v error -show_entries format=start_time -of default=nw=1:nk=1 "$IN" 2>/dev/null)
    { [ -n "$st" ] && [ "$st" != "N/A" ]; } || st=unknown
    rm -f "$TMP"
    echo ">> cut produced no video: -ss beyond end of file? (--ss is relative to start_time=$st, not absolute PTS)" >&2
    exit 1
  fi
  echo "pass 2/2: decode PCM access track + copy original"
  build_from "$TMP"
  rm -f "$TMP"
else
  echo "full-file build (no cut)"
  build_from "$IN"
fi

# POST-MUX CENSUS (D5, 1.13): the dual-track contract IS a stream count — video
# + PCM access + preserved original. A silently dropped track here is the whole
# deliverable's promise gone, and nothing checked it before this.
census_rc=0
mux_census "$PART" 3 "$vcodec,$PCMC,$acodec" dual-track "$IN" || census_rc=$?
if rtm_census_failed "$census_rc"; then
  echo "   NOT blessing the output; kept at $PART. The access+original pair is the"
  echo "   contract of this tool — a missing track means the promise was not kept."
  exit 1
fi
mv -f "$PART" "$OUT"
echo "wrote: $OUT"
echo "VERIFY (alignment): decode track 2 with the SAME params and md5-compare to track 1, e.g."
echo "  a=\$(ffmpeg -v error ${DRC:+$DRC }-i \"$OUT\" -map 0:a:0 -f ${PCMC#pcm_} - | md5sum)"
echo "  b=\$(ffmpeg -v error ${DRC:+$DRC }-i \"$OUT\" -map 0:a:1 -c:a $PCMC -f ${PCMC#pcm_} - | md5sum); [ \"\$a\" = \"\$b\" ] && echo ALIGNED"
# REVIEW propagation (1.14): an unexpected-surplus census or an audio/subtitle
# confession class blesses the complete artifact and exits 10 ("look"), never 1.
if rtm_census_review "$census_rc" || [ "${DT_CONF_REVIEW:-0}" -eq 10 ]; then exit 10; fi
exit 0

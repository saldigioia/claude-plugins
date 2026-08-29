#!/usr/bin/env bash
# resync.sh — fix a DISCONTINUOUS-source desync while keeping the VIDEO bit-identical.
# For captures whose source dropped frames (forward timestamp gaps): a blind `-c copy`
# preserves those gaps in the video timeline but COLLAPSES them in raw PCM audio
# (ffmpeg's muxer writes no mid-stream empty edit per drop, so the PCM sample
# array packs end-to-end), sliding audio progressively out of sync — the
# remux-sync post-mortem. This re-times the audio to
# the picture by filling the gaps, and never re-encodes the video.
#
# Usage: scripts/resync.sh INPUT OUTPUT.mov [--all-audio] [--audio a:N] [--pcm 16|24|32]
#   --all-audio  re-time every audio track (default: a:0 only)
#   --audio a:N  re-time a specific track
#   --pcm        PCM bit depth for the re-timed audio (default 24)
#
# What it does (the corrected procedure from the post-mortem):
#   video : -c:v copy  -> BIT-IDENTICAL (HEVC tagged hvc1); never re-encoded
#   audio : -af aresample=async=1:first_pts=0 -> PCM; silence inserted at each gap
#           so the audio stays pinned to the picture timeline
#   +faststart; atomic .part -> mv; the SOURCE is never touched.
#
# TRADE-OFF (explicit, by design — this is why it is a separate, human-invoked tool
# and not part of the lossless ladder): the audio is RE-TIMED, not a bit-exact copy.
# Video stays lossless. If you also need the bit-exact ORIGINAL audio, the only
# frame-accurate fix is a re-mux from the still-existing source — see the post-mortem
# and references/timeline-repair.md. Lossy tracks (AC-3/DTS/MP2) are rendered to PCM.
#
# REFUSED CLASS (2026-07-30 incident): sources whose audio changes channel layout
# mid-stream (broadcast AC-3 flipping 5.1 -> stereo -> 5.1). Each change makes
# ffmpeg REBUILD the audio filter graph, and aresample=async=1:first_pts=0
# re-pads silence from t=0 on EVERY rebuild — the 2008 backhaul build injected
# ~17 minutes of silence and pushed all later audio out of sync while duration
# parity still passed. The scan below detects the class up front and refuses
# (exit 11) rather than ship it; verify.sh --silence is the downstream content
# gate for whatever does get built.
#
# Exit: 0 = resynced + sync-verified; 10 = REVIEW; 1 = FAIL; 2 = usage;
#       11 = REFUSED (mid-stream audio layout change — resync would inject silence).
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-exit.sh"   # exit-code contract trap (WO 1.4): no stray code escapes
IN="${1:?usage: resync.sh INPUT OUTPUT.mov [--all-audio] [--audio a:N] [--pcm 16|24|32]}"
OUT="${2:?need OUTPUT.mov}"; shift 2
AMAP="-map 0:a:0?"; PCM=pcm_s24le
FORCE=0; FORCED_LAYOUT=0
while [ $# -gt 0 ]; do case "$1" in
  --all-audio) AMAP="-map 0:a?"; shift;;
  --audio)     AMAP="-map 0:${2:?--audio needs a:N}"; shift 2;;
  --pcm) case "${2:-}" in 16) PCM=pcm_s16le;; 24) PCM=pcm_s24le;; 32) PCM=pcm_s32le;; *) echo "bad --pcm: ${2:-}" >&2; exit 2;; esac; shift 2;;
  # TIERS.md T3.11 (1.16.0): the mid-stream layout-change refusal below stays
  # the DEFAULT — the injected-silence class is invisible to duration parity,
  # so shipping it silently is exactly the failure that gate was built from.
  # But the operator may have evidence this script does not (they can listen),
  # and refusing an attempt outright is the habit this round retired. --force
  # attempts it and MANDATES the content gate that can actually see the defect:
  # verify.sh --silence on the result, non-negotiable and non-waivable.
  --force) FORCE=1; shift;;
  *) echo "unknown opt: $1" >&2; exit 2;;
esac; done
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }
. "$SELF_DIR/lib-probe.sh"  # ffp/FF_INPUT_OPTS: raised probe window on every input open
. "$SELF_DIR/lib-mux.sh"    # rtm_part (extension-keeping atomics), mux_census (D5)
rtm_sibling_guard "$IN" "$OUT" || exit 2   # TIER 1 T1.11 write beside the source, never onto it (one writer: lib-mux.sh)

vcodec=$(ffp1 -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$IN" 2>/dev/null)
VTAG=""; [ "$vcodec" = hevc ] && VTAG="-tag:v hvc1"
cp=$(ffp1 -v error -select_streams v:0 -show_entries stream=color_primaries -of default=nw=1:nk=1 "$IN" 2>/dev/null)
MOVFLAGS="+faststart"; { [ -n "$cp" ] && [ "$cp" != unknown ]; } && MOVFLAGS="+faststart+write_colr"

echo "== resync: $IN -> $OUT =="
echo "   video=$vcodec -> -c:v copy (bit-identical); audio -> $PCM, gaps filled (aresample async)"

# --- chapter/movie-timescale pre-announce (WO 1.12-C): announced, never silent -
# With chapters present, movenc warns once the duration passes 2^31
# MOVIE-timescale ticks (measured 2026-08-15, macOS 26.6.1/ffmpeg 9.0.1;
# bracketed 2982/2983 s at the broadcast-common 720000 = LCM of 90 kHz video +
# 48 kHz audio track timescales; a finer movie timescale overflows sooner —
# 2048000 warned at 1049 s). -video_track_timescale does NOT govern it
# (measured at 600/30000/90000). In-band the warning is BENIGN as measured:
# 64-bit version-1 atoms file-wide, clean decode, chapters intact. Past 2^32
# TOTAL ticks (~5965 s at 720000) movenc can silently DROP the chapter track
# — geometry-gated (measured 2026-08-15, two independent rigs): drop iff the
# FIRST chapter spans > 2^31 ticks AND the total passes 2^32, and the warning
# is SUPPRESSED whenever ANY chapter spans > 2^31 ticks, so the loss is
# silent on exactly the geometries that drop. The tier-2 duration gate below
# is a conservative SUPERSET of the drop condition (may over-warn, cannot
# miss) and tells the operator to check the finished build. Pre-announce so
# the warning is expected, never alarming — NO behavior change, and a probe
# failure degrades silently (announce-or-nothing, never a new exit path).
# Details: references/known-limits.md "Chaptered MOV past ~50 min".
CH_WARN_SECS="${RTM_CHAPTER_TS_WARN_SECS:-2900}"   # just under 2^31/720000 = 2982.6 s
case "$CH_WARN_SECS" in ''|*[!0-9]*) CH_WARN_SECS=2900;; esac
CH_DROP_SECS="${RTM_CHAPTER_TS_DROP_SECS:-5965}"   # 2^32/720000 = 5965.2 s (contested zone)
case "$CH_DROP_SECS" in ''|*[!0-9]*) CH_DROP_SECS=5965;; esac
CH_N=$(ffp -v error -show_chapters -of csv=p=0 "$IN" 2>/dev/null | grep -c . || true)
CH_DUR=$(ffp1 -v error -show_entries format=duration -of default=nw=1:nk=1 "$IN" 2>/dev/null || true)
CH_DUR_S=${CH_DUR%%.*}
case "$CH_DUR_S" in ''|*[!0-9]*) CH_DUR_S=0;; esac
if [ "${CH_N:-0}" -ge 1 ] && [ "$CH_DUR_S" -gt "$CH_WARN_SECS" ]; then
  echo "** EXPECT a FATAL-looking muxer warning on this input: \"FATAL error, file"
  echo "   duration too long for timebase ... will not be playable with QuickTime\"."
  echo "   The source carries $CH_N chapter(s) at ~${CH_DUR_S} s: with chapters present,"
  echo "   movenc warns once the duration passes 2^31 movie-timescale ticks —"
  echo "   ~2983 s (~49.7 min) at the broadcast-common 720000 (the movie timescale"
  echo "   rides the track timescales, so a finer one overflows sooner) — and"
  echo "   -video_track_timescale does NOT govern it (measured 2026-08-15). In-band"
  echo "   the warning is BENIGN on modern macOS as measured (2026-08-15, macOS"
  echo "   26.6.1/ffmpeg 9.0.1): ffmpeg writes 64-bit version-1 atoms file-wide;"
  echo "   decode, scrubbing and the chapter menu all verified working. Only"
  echo "   QuickTime 7-era software reading version-1 atoms would object. If the"
  echo "   chapters are dispensable, -map_chapters -1 drops them deliberately."
  echo "   NOTE: if any single chapter itself spans more than 2^31 ticks (~2983 s at"
  echo "   720000), movenc SUPPRESSES this warning entirely — no warning, same math."
  CH_ML=""
  if [ "$CH_DUR_S" -gt "$CH_DROP_SECS" ]; then
    echo "** PAST ~${CH_DROP_SECS} s (2^32 total movie-timescale ticks) movenc can silently"
    echo "   DROP the QuickTime chapter-menu track (measured 2026-08-15, two independent"
    echo "   rigs): the drop fires iff the FIRST chapter spans more than 2^31 ticks AND"
    echo "   the total passes 2^32 — and the warning is suppressed on exactly those"
    echo "   skewed geometries, so the loss is silent; chapters then survive only in"
    echo "   the Nero chpl atom. This duration gate is a conservative SUPERSET of the"
    echo "   drop condition (it may over-warn on safe chapter layouts; it cannot miss)."
    echo "   CHECK the finished build:"
    echo "     ffprobe -v error -show_chapters OUT.mov            # expect every chapter"
    echo "     ffprobe -v error -show_entries stream=codec_type -of csv=p=0 OUT.mov"
    echo "                                       # expect the chapter data track listed"
    echo "   ('Referenced QT chapter track not found' on open = the track WAS dropped)"
    echo "   or drop the chapters deliberately with -map_chapters -1."
    CH_ML=" drop_s=$CH_DROP_SECS"   # append-only field: emitted only when the tier-2 arm fires
  fi
  echo "MOV_CHAPTER_TS_WARN chapters=$CH_N dur_s=$CH_DUR_S limit_s=$CH_WARN_SECS$CH_ML"   # machine-readable (additive, WO 1.12-C)
fi

# --- mid-stream layout-change guard (frame-level, decodes the mapped audio) ---
# Test hook: RTM_LAYOUTS_FILE=<file of "channels,layout" lines> bypasses ffprobe.
lay_profile () {  # $1 = stream spec (a:N) -> distinct channels/layout combos seen
  { if [ -n "${RTM_LAYOUTS_FILE:-}" ]; then cat "$RTM_LAYOUTS_FILE"; else
      ffp -v error -select_streams "$1" -show_entries frame=channels,channel_layout \
        -of csv=p=0 "$IN" 2>/dev/null; fi; } | grep -v '^$' | sort -u
}
ASPECS=""
case "$AMAP" in
  "-map 0:a?")
    na=$(ffp -v error -select_streams a -show_entries stream=index -of csv=p=0 "$IN" 2>/dev/null | sort -un | grep -c . || true)
    i=0; while [ "$i" -lt "${na:-0}" ]; do ASPECS="$ASPECS a:$i"; i=$((i+1)); done ;;
  *) ASPECS=$(printf '%s' "$AMAP" | sed 's/^-map 0://; s/?$//') ;;
esac
for spec in $ASPECS; do
  echo "   scanning $spec for mid-stream layout changes (audio decode; may take a minute)..."
  combos=$(lay_profile "$spec")
  ncombo=$(printf '%s\n' "$combos" | grep -c . || true)
  if [ "${ncombo:-0}" -gt 1 ]; then
    echo ">> REFUSED: mid-stream channel-layout change on $spec:"
    printf '%s\n' "$combos" | sed 's/^/     /'
    echo "   Each change makes ffmpeg rebuild the audio filter graph, and"
    echo "   aresample=async=1:first_pts=0 re-pads silence from t=0 on every rebuild —"
    echo "   the injected-silence incident class (~17 min of silence, all later audio"
    echo "   out of sync, duration parity blind to it). Refusing rather than shipping it."
    echo "   Honest routes:"
    echo "     mov.sh   the dual-track build has no resample filter in its path and is"
    echo "              the correct deliverable when the AUDIO itself is continuous"
    echo "              (a sub-frame video gap costs milliseconds — under sync tolerance)"
    echo "     keep     the source — it is already the archival master"
    echo "     playback lossless MKV mux (holds the discontinuous timeline honestly)"
    if [ "$FORCE" -ne 1 ]; then
      echo "   If you have evidence this stream is safe, --force attempts it anyway and"
      echo "   MANDATES verify.sh --silence on the result (the only gate that can see"
      echo "   injected silence). It is not a way to skip the check; it is a way to"
      echo "   reach it."
      exit 11   # TIER 3 T3.11 injected-silence default (announced --force overrides)
    fi
    echo "** --force: building anyway. The silence content gate is now MANDATORY on this"
    echo "**   run and its verdict is final — a --force build that fails it is not shipped."
    FORCED_LAYOUT=1
  fi
done

trap 'rtm_unlock' EXIT   # writer-lock release however this run ends (WO-1.15.6 A2)
rtm_writer_preflight "$OUT" "$IN" || exit 2
PART="$(rtm_part "$OUT")"   # extension-keeping (D6) + unique per process (A2)
# shellcheck disable=SC2086
ffmpeg -nostdin -v error -fflags +genpts "${FF_INPUT_OPTS[@]}" -i "$IN" \
  -map 0:v:0 -c:v copy $VTAG \
  $AMAP -af "aresample=async=1:first_pts=0" -c:a "$PCM" \
  -movflags "$MOVFLAGS" -f mov "$PART"
# POST-MUX CENSUS (D5, 1.13): ASPECS above IS the audio plan this run mapped —
# reconcile it against the file before blessing. Every re-timed track lands as
# $PCM by construction, so the identity half is assertable too.
# count only the specs that EXIST: the default map is `-map 0:a:0?` — the `?`
# makes it optional, so a video-only source legitimately writes one stream and
# a naive 1+len(ASPECS) plan would MISMATCH on a healthy build.
RS_NA=$(ffp -v error -select_streams a -show_entries stream=index -of csv=p=0 "$IN" 2>/dev/null | sort -u | grep -c . || true)
RS_N=1; RS_C="$vcodec"
for spec in $ASPECS; do
  rs_i=${spec#a:}
  case "$rs_i" in ''|*[!0-9]*) continue;; esac
  [ "$rs_i" -lt "${RS_NA:-0}" ] || continue
  RS_N=$((RS_N+1)); RS_C="$RS_C,$PCM"
done
census_rc=0
mux_census "$PART" "$RS_N" "$RS_C" resync "$IN" || census_rc=$?
if rtm_census_failed "$census_rc"; then
  echo "   NOT blessing the output; kept at $PART."
  exit 1
fi
mv -f "$PART" "$OUT"
echo "   wrote: $OUT"

echo "-- verify (sync + lossless video + silence content-parity) --"
if [ "${FORCED_LAYOUT:-0}" -eq 1 ]; then
  echo "   THIS RUN WAS --force'd past the mid-stream layout guard. The silence"
  echo "   content gate below is the one check that can see injected silence, and"
  echo "   its verdict decides this build: --force reaches the gate, it never"
  echo "   skips it. Listen to the result before archiving either way."
fi
# --silence: duration parity cannot see injected silence (the 2008 build passed
# it with ~17 min inserted) — the content gate compares long-window silence
# source vs output against the legitimate gap-fill budget.
set +e
o=$(bash "$SELF_DIR/verify.sh" "$IN" "$OUT" --silence 2>&1); set -e
printf '%s\n' "$o" | sed 's/^/   /'
case "$o" in
  *">> OK"*)     echo ">> DONE: $OUT — video bit-identical, audio re-timed to the picture."
                 # REVIEW propagation (1.14): an unexpected-surplus census still
                 # blesses the complete artifact and exits 10 ("look"), never 1.
                 if rtm_census_review "${census_rc:-0}"; then
                   echo ">> REVIEW: the census flagged an unexpected surplus stream (see RMX_CENSUS above)."
                   exit 10
                 fi
                 exit 0 ;;
  *">> REVIEW"*) echo ">> REVIEW: $OUT written; see the sync/parity note above (a tail residual can remain — confirm against the source)."
                 [ "${FORCED_LAYOUT:-0}" -eq 1 ] && echo "   (--force run: a REVIEW here is not a pass. The layout change this was forced past is the first thing to listen for.)"
                 exit 10 ;;
  *)             echo ">> FAIL: see verify output above. Source untouched; $OUT is unverified."; exit 1 ;;
esac

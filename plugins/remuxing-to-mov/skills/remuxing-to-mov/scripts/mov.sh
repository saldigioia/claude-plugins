#!/usr/bin/env bash
# mov.sh — the "/mov" shortcut: one call from any capture to a QuickTime-ready
# .mov, lossless-first. Probe -> build the right thing -> verify -> report.
# Video is ALWAYS stream-copied (bit-identical); this never re-encodes video and
# never touches or deletes the source.
#
# Usage: scripts/mov.sh INPUT [OUTPUT.mov] [--always-dual] [--full] [--force-backhaul]
#                       [--no-idr-trim] [--audio-keep all|first|layouts|IDX[,IDX...]]
#                       [--mp4-swap] [metadata flags]
#   --mp4-swap     if the post-build fidelity proof FAILS, take the container-swap
#                  rung automatically (scripts/mp4-swap.sh: same bitstream, MP4,
#                  'mp4v'+esds — measured 2026-08-15 to render correctly where the
#                  .mov of the same bits does not) and report its verdict. WITHOUT
#                  the flag the route is only NAMED, never built: a .mp4 is a
#                  second deliverable the caller did not ask for, and this plugin
#                  does not write files nobody requested. Either way Rung 4 is now
#                  the LAST named route out of a bad render, not the first (D2).
#   OUTPUT         default: <input dir>/<input base>.mov
#                  (<base>.qt.mov if the input is itself a .mov, so the source is safe)
#   --always-dual  build the dual-track even when the source audio already plays in
#                  QuickTime (the plugin's "always dual-track" default deliverable)
#   --no-idr-trim  keep a mid-GOP capture head as-is. DEFAULT is the announced
#                  auto-trim: when the pre-flight sees video packets before the
#                  first keyframe (the mid-GOP-start class ts-health.sh flags),
#                  trim-to-idr.sh cuts BOTH tracks at the first IDR into a temp
#                  intermediate the build then consumes (deleted after a verified
#                  DONE, kept for the closer look otherwise). WHY: the pre-roll is
#                  undecodable by any player (its parameter sets were never
#                  captured) AND ffmpeg streamcopy silently drops the video half
#                  of it while the audio half lands — the untrimmed build then
#                  fails A/V duration parity as a phantom desync (measured:
#                  102 video pkts dropped, REVIEW at 4.25 s mismatch).
#   --audio-keep   which audio tracks survive (QTFF audit 5-2c; default: all —
#                  WO 3.3: every track is content, and dropping buys NO
#                  playability: movenc already enables exactly one audio track
#                  (tkhd 0x0003/0x0002/..., parsed bench 2026-08-13), which is
#                  precisely Apple TN3177's requirement. 'layouts' is the
#                  OPT-IN curation flag — distinct layout+language pairs
#                  survive, same-layout same-language duplicates curated
#                  lossless > lossy-high > lossy-low, every drop announced;
#                  'first' reproduces the historical a:0-only behavior.
#                  REJECTED on the PAFF path, exit 2 — audio policy there
#                  comes from the repair rung; 1.15.1 silently ignored it)
#   --full         archival sign-off: pass --full to verify.sh (whole-file decode)
#   --force-backhaul  skip the pre-build backhaul timeline scan + warning.
#                  Since 1.11 NEITHER backhaul arm refuses — the 4:2:2/pix_fmt
#                  arm builds and is playability-proven post-build (WO 4.1),
#                  and the timeline-rot arm warns + builds + lets verify judge
#                  (WO 4.2) — so this flag only silences the rot scan/warning
#                  (kept as API; a no-op for the pix_fmt arm)
#   metadata (OPT-IN — NOTHING is tagged unless you pass one of these explicitly):
#     --title --description --author --date --copyright --comment --keywords
#     --key NAME=VALUE  --keep-chapters
#     -> embedded in proper QuickTime format via metadata.sh (and the generic chapter
#        "menu" dropped). Never applied automatically.
#
# AUDIO POLICY — dual-track only when needed (classified by QuickTime PLAYABILITY,
# not by whether the codec merely muxes into MOV):
#   QuickTime-native (AAC / ALAC / MP3 / raw PCM / E-AC-3) -> copied as-is, single
#                                                         track (E-AC-3 = Dolby Digital
#                                                         Plus, plays natively in modern
#                                                         QuickTime; raw PCM only —
#                                                         pcm_bluray/pcm_dvd are NOT this)
#   not native but MOV-copyable (AC-3 / DTS / MP2)     -> DUAL-TRACK: PCM "access"
#                                                         track 1 (always plays) +
#                                                         original copied bit-exact track 2
#   not native and not usefully MOV-copyable           -> single PCM access track;
#   (FLAC/Opus/TrueHD; Blu-ray/DVD LPCM — pcm_bluray/     original CANNOT be preserved in
#    pcm_dvd "copy" muxes into an HDMV-tagged track        MOV (keep MKV/MP4/m2ts if you
#    that NO decoder claims, not even ffmpeg's)            need the original bitstream)
#   none                                              -> video-only copy
#
# Field-coded (PAFF) H.264 is routed via auto.sh by timestamp profile:
# pair-timestamped / reordered streams get the pair-mate PTS fill
# (pairfill-paff.sh — dual-track built in, original audio preserved bit-exact);
# only a no-reorder stream gets the elementary rebuild, and THAT path decodes
# audio to PCM (original not preserved — manual route via
# references/timeline-repair.md + references/dual-track-quicktime.md if needed).
#
# Exit: 0 = verified OK; 10 = REVIEW (written, look closer — includes a build
#            whose post-build playability check FAILed or could not run on this
#            platform, WO 4.1); 1 = FAIL; 2 = usage;
#       11 = REFUSED. Since 1.11 neither BACKHAUL arm refuses (the 4:2:2
#            profile builds + is playability-proven, WO 4.1; timeline rot
#            warns + builds + lets verify judge, WO 4.2) — the only refusals
#            mov.sh itself issues are the UNROUTABLE codecs (WO 5.2: VC-1 /
#            VP9 / AV1 video, Dolby E audio — no lossless MOV of these classes
#            exists, so the honest answer is the routes out, pre-flight, never
#            a raw muxer stack trace). A child's refusal — e.g. resync.sh's
#            mid-stream layout guard (11) — does NOT propagate as 11 through
#            auto.sh today: it is flattened to FAIL (CHECKUP-2026-08-27 C5;
#            the old claim here that it propagates was false).
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-exit.sh"   # exit-code contract trap (WO 1.4): no stray code escapes
# lib-paff BEFORE the RTM_TEST guard: it now owns the shared unroutable_v/
# unroutable_a classifiers (1.11 fix round — auto.sh/remux.sh dispatch the SAME
# arms, so no entry point can diverge), and the suite unit-pins them by
# sourcing THIS file under the guard.
. "$SELF_DIR/lib-paff.sh"   # unroutable_* classifiers + refusal voice, backhaul machinery
. "$SELF_DIR/lib-mux.sh"    # rtm_sidecar: extension-keeping intermediates (D6)

# --- audio classifiers (top of file so the RTM_TEST harness can source them) ---
# native_c: does QuickTime PLAY this codec as-is? The pcm_* glob means RAW PCM
# only — pcm_bluray/pcm_dvd are excluded FIRST (WO 3.1): they are
# container-framed LPCM, not raw PCM. The MOV muxer "successfully" copies them
# into an HDMV-tagged track that NO decoder claims — even ffmpeg cannot decode
# the file it just wrote (real 18.5 GB Blu-ray case: the driver reported
# success on a silent output). A mux that succeeds is not a track that plays.
native_c () { case "$1" in pcm_bluray|pcm_dvd) return 1;; aac|alac|mp3|pcm_*|eac3) return 0;; *) return 1;; esac; }
# mode_for: single-kept-track codec -> build MODE. This is the decision table
# the flow below consumes (--always-dual upgrades copy->dual at the call site).
mode_for () { case "$1" in
  pcm_bluray|pcm_dvd)      echo pcm  ;;  # container-framed LPCM: muxes, never decodes (see native_c) -> decode to raw PCM
  aac|alac|mp3|pcm_*|eac3) echo copy ;;  # plays natively in QuickTime (eac3 = DD+; pcm_* = raw PCM here)
  ac3|dts|dca|mp2|mp1)     echo dual ;;  # not native, but MOV-copyable -> keep original via dual-track
  *)                       echo pcm  ;;  # flac/opus/truehd/...: original not MOV-copyable
esac; }
# unroutable_v / unroutable_a live in lib-paff.sh since the 1.11 fix round
# (sourced above, BEFORE the RTM_TEST guard, so the suite's sourced-classifier
# harness still finds them here): auto.sh and remux.sh dispatch the same arms,
# closing the WO 5.2 parity gap (a direct auto/remux run used to die in the
# raw muxer stack trace while only mov.sh refused honestly).
# RTM_TEST sourcing guard: `RTM_TEST=1 . mov.sh` stops here so the regression
# suite can unit-test the classifiers above without running the build flow.
# An executed run (`bash mov.sh ...`) is not a source, so it never returns here.
if [ "${RTM_TEST:-0}" = 1 ] && [ "${BASH_SOURCE[0]:-}" != "$0" ]; then return 0; fi

IN="${1:?usage: mov.sh INPUT [OUTPUT.mov] [--always-dual] [--full] [--force-backhaul] [--no-idr-trim] [--audio-keep POLICY] [metadata flags]}"; shift
OUT=""; ALWAYS=0; FULL=""; MDARGS=(); AKEEP=all; FORCE_BACKHAUL=0; NOIDRTRIM=0; MP4SWAP=0
# optional positional OUTPUT (the next arg, only if it isn't a --flag)
if [ "${1:-}" != "" ] && [ "${1#--}" = "${1:-}" ]; then OUT="$1"; shift; fi
while [ $# -gt 0 ]; do case "$1" in
  --always-dual) ALWAYS=1; shift;;
  --full)        FULL="--full"; shift;;
  --force-backhaul) FORCE_BACKHAUL=1; shift;;
  --no-idr-trim) NOIDRTRIM=1; shift;;
  --mp4-swap)    MP4SWAP=1; shift;;
  --audio-keep)  AKEEP="${2:?--audio-keep needs a value}"; shift 2;;
  --audio-keep=*) AKEEP="${1#*=}"; shift;;
  # OPT-IN metadata: collected and passed verbatim to metadata.sh after the build
  --title|--description|--author|--date|--creationdate|--copyright|--comment|--keywords|--key)
                 MDARGS+=("$1" "${2?need a value for $1}"); shift 2;;
  --keep-chapters) MDARGS+=("$1"); shift;;
  *) echo "unknown opt: $1" >&2; exit 2;;
esac; done
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }

# default output beside the source; never collide with the source name
if [ -z "$OUT" ]; then
  d="$(cd "$(dirname "$IN")" && pwd)"; b="$(basename "$IN")"; stem="${b%.*}"
  OUT="$d/$stem.mov"
  [ "$OUT" = "$d/$b" ] && OUT="$d/$stem.qt.mov"   # input already .mov -> don't target the source
fi

# OPT-IN metadata: applied as a -c copy pass on the finished file ONLY when the user
# passed metadata flags. NEVER automatic. Proper QuickTime format + drops the generic
# chapter "menu" (metadata.sh); A/V stays bit-identical.
apply_metadata () {  # $1 = finished .mov to tag in place via a temp
  [ "${#MDARGS[@]}" -gt 0 ] || return 0
  echo "-- embedding QuickTime metadata (opt-in) --"
  # EXTENSION-KEEPING intermediate (D6, 1.13): this was "$1.premeta", and on a
  # metadata failure that untagged build — a perfectly good deliverable — was
  # left under a name qlmanage/avconvert cannot open, so the operator's first
  # diagnostic move reported a decode failure that did not exist.
  local pre; pre="$(rtm_sidecar "$1" premeta)"
  mv -f "$1" "$pre"
  local rc; set +e; bash "$SELF_DIR/metadata.sh" "$pre" "$1" "${MDARGS[@]}" | sed 's/^/   /'; rc=${PIPESTATUS[0]}; set -e
  [ "$rc" -eq 0 ] || { echo ">> metadata step failed (rc=$rc); untagged build kept at $pre" >&2; return "$rc"; }
  rm -f "$pre"
}

# probe once; consume the structured KEY=VAL (single source of truth). The grep
# whitelists PR_/PF_ lines so a stray line can never become code via eval.
eval "$(bash "$SELF_DIR/probe.sh" "$IN" --kv | grep -E '^(PR|PF)_[A-Z0-9_]+=')"
echo "== mov: $IN -> $OUT =="
echo "   video=$PR_VCODEC  audio=$PR_ACODEC  paff=$PF_PAFF"

# --- unroutable codecs: one honest refusal each, never a raw muxer error ------
# WO 5.2: the never-mentioned classes used to die mid-build as raw ffmpeg
# errors (VP9 verified un-muxable on the bench) or misroute silently. They are
# REFUSED-class outcomes — exit 11 with the routes, nothing written, source
# untouched — because unlike every other gate in this file the failure is not
# a playability question the post-build proof can answer: the MOV cannot exist.
# The classifiers + the refusal voice are shared (lib-paff.sh, 1.11 fix round)
# so auto.sh and remux.sh refuse identically — gate at every entry point.
if unroutable_v "$PR_VCODEC"; then
  unroutable_v_refuse "$PR_VCODEC"
  exit 11
fi
# Dolby E scan honors --audio-keep: the whole per-track manifest is checked
# (a:0-only was the transcript-1 blind-spot class), and an explicit keep-list
# that excludes every Dolby E track is itself one of the refusal's named routes
# — the exclusion is announced here and the drop WARNs again in the plan
# (house rule 5). `layouts` could curate a Dolby E track IN, so it refuses
# like `all`; only explicit indices (or `first` with Dolby E off a:0) pass.
DBE_ORD=""; ua_i=0
while [ "$ua_i" -lt "${PR_AUD_COUNT:-0}" ]; do
  eval "ua_c=\${PR_AUD_${ua_i}_CODEC:-}"
  if unroutable_a "$ua_c"; then
    case "$AKEEP" in
      all|layouts) DBE_ORD=$ua_i;;
      first)       [ "$ua_i" -eq 0 ] && DBE_ORD=$ua_i;;
      *)           case ",$AKEEP," in *,"$ua_i",*) DBE_ORD=$ua_i;; esac;;
    esac
    [ -n "$DBE_ORD" ] && break
    echo "   note: Dolby E track a:$ua_i present but excluded by --audio-keep $AKEEP -> proceeding (the drop is announced in the plan)"
  fi
  ua_i=$((ua_i+1))
done
if [ -n "$DBE_ORD" ]; then
  unroutable_a_refuse "$DBE_ORD"   # shared voice (lib-paff.sh) — same refusal at auto.sh/remux.sh
  exit 11
fi

# --- measured-native video matrix (WO 5.1): recognition, never conversion ----
# The F8 bench (2026-08-14, macOS 26.6.1/ffmpeg 9.0.1) measured mpeg4(mp4v),
# MJPEG 4:2:0(jpeg), DV(dvcp) and ProRes(apcn) muxing -c copy into MOV and
# fully decoding in AVFoundation — joining h264/hevc(hvc1)/mpeg2video as
# plain-copy classes, so a DV/MJPEG/MPEG-4 capture is never talked toward a
# needless conversion. Codec decode verdicts DRIFT with macOS (C63: Tahoe 26.4
# dropped MJPEG variants; C72: 26.6.1 restored 4:2:2 — both directions), so
# the recognition self-dates (Ground Rule 6) and the classes probe.sh could
# NOT vouch for (PR_VNATIVE=variant/no) are announced and routed into the
# WO 4.1 post-build playability proof instead of being silently branded
# "QuickTime-ready". Video is stream-copied on every path here regardless
# (Ground Rule 2) — this block decides messaging + the empirical check, only.
case "${PR_VNATIVE:-na}" in
  yes) case "$PR_VCODEC" in mpeg4|mjpeg|dvvideo|prores)
         echo "   $PR_VCODEC: measured QT-native in MOV (bench 2026-08-14, macOS 26.6.1/ffmpeg 9.0.1) -> lossless copy";;
       esac;;
  variant)
    echo "** WARN mjpeg ${PR_PIX_FMT:-?}: non-4:2:0 MJPEG is the C63 measured-DROP class"
    echo "   (Tahoe 26.4; yuvj422p rendered no frame and hung qlmanage on 26.5.2)."
    echo "   Building the lossless copy anyway — playability is proven post-build." ;;
  no)
    echo "   NOTE: $PR_VCODEC is outside the measured QT-native matrix — the copy is"
    echo "   lossless either way; QuickTime playability is proven post-build, not assumed." ;;
esac

# --- backhaul verdicts: advisory + post-build proof for pix_fmt; warn for rot
#   4:2:2 CONTRIBUTION PROFILE (WO 4.1 — demoted from refusal to empirical
#   proof): the 1.8.0–1.10.0 gate refused yuv422p on MPEG-2/H.264 here,
#   claiming AVFoundation cannot decode it (the 2026-07-30/31 controlled
#   pairs). FALSIFIED on the bench 2026-08-13 (macOS 26.6.1): both refused
#   classes fully decode (qlmanage thumbnail + avconvert whole-file, 50/50
#   frames) — and the exact 8-bit match let the ACTUAL 10-bit contribution
#   profiles (yuv422p10le, AVC-Intra class) bypass the gate unannounced.
#   Decode support drifts by macOS version (C63: Tahoe 26.4 dropped MJPEG
#   variants/AIC), so a hardcoded codec verdict rots; instead the profile is
#   ANNOUNCED here (yuv422p*, all bit depths) and playability is PROVEN on
#   the finished build below (playable-check.sh; FAIL or unverifiable
#   platform -> 10 REVIEW with the Rung-4 route named, never a silent OK).
#   --force-backhaul / RTM_FORCE_BACKHAUL stay API; they are no-ops for this
#   arm now — there is no pix_fmt refusal left to skip.
#   TIMELINE ROT (WO 4.2 — demoted from refusal to pre-build WARNING):
#   mpegts + mpeg2video + forward gaps + non-monotonic DTS, whole-file and
#   demux-only (~1 min on a 12 GB capture). The 1.8.0–1.10.0 refusal claimed
#   "no lossless MOV of this class survives verify" — a PREDICTION, while the
#   plugin already owns the measured judges: the mux-confession HARD STOP
#   (invented timing — measured, KEPT) and verify.sh's post-build timeline
#   gates. Bench 2026-08-14, constructed rot fixture: the demuxer's own
#   discontinuity fixup muxed a monotonic timeline (no confession fired) and
#   verify caught the REAL defect (dual-track access misalignment -> REVIEW)
#   — an artifact plus evidence instead of exit 11. The warning keeps the
#   refusal's three routes; nothing gets blessed that verify won't sign.
#   Forward gaps ALONE never warned and still don't — that class rebuilds
#   (the 2008 recovery); and an H.264 TS with gaps still rides the existing
#   PAFF/resync machinery.
#   F1 (2026-08-16): the rot warning, its routes and its MOV_ROT_WARN line all
#   come from lib-paff.sh now (backhaul_rot_warn + backhaul_gate_routes). The
#   local backhaul_routes() printer that used to live here was deleted with the
#   inline warning it served: a second routes text with no caller is the seam a
#   future edit re-diverges along, and the routes are part of the warning's
#   voice, not mov.sh's.
# WO 4.1: the pix_fmt arm announces and defers to the post-build proof (the
# shared advisory + predicate live in lib-paff.sh so no entry point diverges)
. "$SELF_DIR/lib-paff.sh"   # qt_contribution_profile, contribution_advisory, playability_verdict, disc_scan
PLAYCHECK_DUE=0; PLAYCHECK_WHY="contribution profile"
if qt_contribution_profile "${PR_PIX_FMT:-}"; then
  PLAYCHECK_DUE=1
  contribution_advisory "$PR_VCODEC" "${PR_PIX_FMT:-}"
fi
# WO 5.1: the same empirical machinery (never a fork of it) judges the classes
# probe.sh could not vouch for — a non-4:2:0 MJPEG variant (C63's measured
# drop) and any codec outside the measured matrix. Ordinary measured-native
# builds still pay nothing.
if [ "$PLAYCHECK_DUE" -eq 0 ]; then
  case "${PR_VNATIVE:-na}" in
    variant) PLAYCHECK_DUE=1; PLAYCHECK_WHY="measured-drop MJPEG variant";;
    no)      PLAYCHECK_DUE=1; PLAYCHECK_WHY="unmeasured codec $PR_VCODEC";;
  esac
fi
if [ "$FORCE_BACKHAUL" -eq 0 ] && [ "$PR_VCODEC" = mpeg2video ]; then
  case "${PR_CONTAINER:-}" in *mpegts*)
    echo "   mpegts/mpeg2video -> backhaul timeline scan (whole file, demux-only)..."
    . "$SELF_DIR/lib-paff.sh"
    # F1: this used to be an inline COPY of the shared rot warning, and the copy
    # is the one that ran — mov.sh exports RTM_BACKHAUL_GATED=1 further down, on
    # which the shared backhaul_gate returns early, so the P1.4 presentation
    # census never executed on the /mov path at all. The copy also triggered on
    # the coded-order DISC_COUNT and emitted a MOV_ROT_WARN line missing the
    # disc_p= / disc_p_na= fields: one line name, two schemas, two triggers.
    # There is now exactly ONE implementation (lib-paff.sh backhaul_rot_warn)
    # and it eval's its scan into this shell, so the clear-scan line below still
    # prints the numbers from the very same pass. The routes come from the
    # shared backhaul_gate_routes with the warning that owns them.
    if ! backhaul_rot_warn "$IN" "$PR_VCODEC" "${PR_CONTAINER:-}"; then
      echo "   backhaul scan clear (presentation gaps=${DISC_P_COUNT:-0}, coded-order gaps=${DISC_COUNT:-0}, back=${DISC_BACK:-0} dup=${DISC_DUP:-0}) -> continuing."
    fi
    ;;
  esac
fi
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
# miss) and tells the operator to check the finished build. Announce BEFORE
# dispatch so the warning is expected in whichever child muxes, never
# alarming — NO behavior change, and a probe failure degrades silently
# (announce-or-nothing, never a new exit path). Details:
# references/known-limits.md "Chaptered MOV past ~50 min".
. "$SELF_DIR/lib-probe.sh"   # ffp: the chapter/duration probe opens the input directly
CH_WARN_SECS="${RTM_CHAPTER_TS_WARN_SECS:-2900}"   # just under 2^31/720000 = 2982.6 s
case "$CH_WARN_SECS" in ''|*[!0-9]*) CH_WARN_SECS=2900;; esac
CH_DROP_SECS="${RTM_CHAPTER_TS_DROP_SECS:-5965}"   # 2^32/720000 = 5965.2 s (contested zone)
case "$CH_DROP_SECS" in ''|*[!0-9]*) CH_DROP_SECS=5965;; esac
CH_N=$(ffp -v error -show_chapters -of csv=p=0 "$IN" 2>/dev/null | grep -c . || true)
CH_DUR=$(ffp -v error -show_entries format=duration -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1 || true)
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

# WO 4.1: "QuickTime-ready" on a contribution profile is now EARNED, not
# assumed — the DONE line below is only reachable when the post-build
# playability check returned ok (fail/skip demote to 10 REVIEW first)
READY_TAG="QuickTime-ready"

# gate verdict propagates: every child that writes a .mov (auto/remux/rebuild/
# pairfill) carries its own backhaul_gate, so a cleared or force-approved front
# door must say so — otherwise the child would re-refuse (or re-scan) a source
# this gate already decided.
[ "$FORCE_BACKHAUL" -eq 1 ] && export RTM_FORCE_BACKHAUL=1
export RTM_BACKHAUL_GATED=1

# --- mid-GOP start pre-flight (WO 2.2): PERFORM the trim ts-health prescribes ---
# A capture that joins the broadcast mid-GOP carries pre-roll video before its
# first IDR that no player can decode (parameter sets never captured) — and the
# untrimmed build is not even a faithful copy of it: ffmpeg streamcopy silently
# DROPS initial non-keyframe video packets (-copyinkf default) while the audio
# pre-roll all lands, so verify's duration-parity gate flags a phantom desync
# (measured on late-sps: 102 video pkts vanished, REVIEW at 4.25 s mismatch).
# trim-to-idr.sh cuts BOTH tracks at the first IDR (gop-probe-proven boundary,
# 0-pre-keyframe gated, kept region byte-identical); the build then consumes the
# trimmed intermediate and verify runs against IT — the honest source of what
# was built. Announced, never silent; --no-idr-trim keeps the old behavior
# (also announced — no silent mapping decisions, house rule).
. "$SELF_DIR/lib-probe.sh"   # ffp: this scan opens the input directly
TRIMTMP=""; IDRTRIM=none
# windowed flag scan: pre-keyframe count within the first 600 video packets; a
# window with packets but NO keyframe is still the mid-GOP class (trim-to-idr
# scans deeper). awk consumes to EOF (early exit would SIGPIPE ffprobe under
# pipefail) and 0-guards its counters (the remux.sh:69 POSIX-awk trap).
PREKEY=$(ffp -v error -select_streams v:0 -read_intervals '%+#600' \
           -show_entries packet=flags -of csv=p=0 "$IN" 2>/dev/null | \
         awk '{ if(!f){ if(index($0,"K")) f=1; else n++ } } END{ printf "%d", n+0 }')
if [ "${PREKEY:-0}" -gt 0 ]; then
  if [ "$NOIDRTRIM" -eq 1 ]; then
    echo "** mid-GOP start: $PREKEY pre-keyframe packet(s) KEPT (--no-idr-trim)."
    echo "   Expect the mux to drop the video pre-roll silently while the audio"
    echo "   pre-roll survives — A/V duration parity will read as a desync REVIEW."
    IDRTRIM=skipped
  else
    echo "** mid-GOP start: trimming pre-roll to first IDR ($PREKEY pre-keyframe packets) — --no-idr-trim to skip"
    b="$(basename "$IN")"; ext="${b##*.}"; [ "$ext" = "$b" ] && ext=ts
    TRIMTMP="${OUT%.*}.idrtrim.tmp.$ext"
    set +e; bash "$SELF_DIR/trim-to-idr.sh" "$IN" "$TRIMTMP" | sed 's/^/   /'; trc=${PIPESTATUS[0]}; set -e
    if [ "$trc" -eq 0 ] && [ -s "$TRIMTMP" ]; then
      IN="$TRIMTMP"; IDRTRIM=$PREKEY
      # the pre-roll skewed every windowed probe fact (untimestamped fractions,
      # PAFF ratios measured across undecodable garbage) -> re-probe the input
      # the build will actually consume
      eval "$(bash "$SELF_DIR/probe.sh" "$IN" --kv | grep -E '^(PR|PF)_[A-Z0-9_]+=')"
      echo "   building from the trimmed intermediate: $TRIMTMP"
      echo "   (deleted after a verified DONE; kept for the closer look otherwise)"
    else
      TRIMTMP=""; IDRTRIM=failed
      echo "** WARN: IDR trim failed (rc=$trc) — proceeding with the UNTRIMMED source"
      echo "   (old behavior: the mux drops the video pre-roll silently; expect the"
      echo "   A/V parity REVIEW). Standalone re-run: scripts/trim-to-idr.sh \"$IN\" TRIMMED.$ext"
    fi
  fi
fi
# temp custody: DONE deletes the intermediate; REVIEW/FAIL keeps it — verify and
# any diagnosis compare against the trimmed input, not the untrimmed capture.
trim_cleanup () {  # $1 = final rc
  [ -n "$TRIMTMP" ] || return 0
  if [ "$1" -eq 0 ]; then rm -f "$TRIMTMP"
  else echo "   (trimmed intermediate kept at $TRIMTMP — verify/diagnose against IT, not the untrimmed capture)"
  fi
}

# --- field-coded: hand the timeline repair to the tested ladder driver ---
if [ "$PF_PAFF" = yes ]; then
  echo "   field-coded (PAFF) -> timeline repair via auto.sh (routed by timestamp profile:"
  echo "   pair-fill keeps real PTS + original audio; the rebuild decodes audio to PCM)"
  if [ "${PF_HALF_TS:-no}" = no ] && [ "${PF_REORDER:-no}" = yes ]; then
    # full-TS reordered PAFF goes through auto's COPY rung — remux.sh under it,
    # so every audio track survives (the WO 3.3 `all` default), but auto is the
    # ladder driver, not the deliverable builder: no dual-track pair on this
    # one path. Say so (5e).
    echo "   note: this profile rides the copy rung — every audio track survives, but"
    echo "   the dual-track pair is not built here (auto.sh is the ladder driver). For"
    echo "   the dual-track deliverable, run scripts/dual-track.sh on the source after"
    echo "   this verifies OK (same copy mux + PCM access track)."
  fi
  [ "$ALWAYS" -eq 1 ] && echo "   note: --always-dual does not apply on the PAFF path — audio policy comes from the repair rung (pairfill dual-tracks non-native codecs by itself)."
  if [ "$AKEEP" != all ]; then
    # REJECT, never silently ignore (1.15.2 field UX trap): 1.15.1 accepted
    # the flag here, printed a mid-scroll note, and built a:0 regardless — the
    # operator asked for one track and shipped another.
    echo ">> REFUSED (--audio-keep $AKEEP): the flag is not honoured on the PAFF path —" >&2
    echo "   audio policy comes from the rung (repair rungs build a:0 and pairfill warns" >&2
    echo "   on multi-track sources; the copy rung keeps every track). Re-run without" >&2
    echo "   --audio-keep, or curate tracks on the finished .mov afterwards (the remux" >&2
    echo "   ladder's --audio-keep applies there). Nothing was written." >&2
    exit 2
  fi
  set +e; bash "$SELF_DIR/auto.sh" "$IN" "$OUT" $FULL; rc=$?; set -e
  if [ "$rc" -eq 0 ] && [ "${#MDARGS[@]}" -gt 0 ]; then
    apply_metadata "$OUT" || rc=$?
    if [ "$rc" -eq 0 ]; then
      # the metadata pass REWRITES the container after auto's verify — always
      # verify the file actually shipped, never its pre-rewrite ancestor
      echo "-- re-verify after metadata pass --"
      set +e; o=$(bash "$SELF_DIR/verify.sh" "$IN" "$OUT" $FULL 2>&1); set -e
      printf '%s\n' "$o" | sed 's/^/   /'
      case "$o" in *">> OK"*) : ;; *">> REVIEW"*) rc=10;; *) rc=1;; esac
    fi
  fi
  trim_cleanup "$rc"
  exit "$rc"
fi

# --- classify audio from the FULL track set (QTFF audit 5-2c; WO 3.3
#     2026-08-14: the default keep policy is `all` — the old layouts default
#     lost a same-codec same-rank tie purely on track order (multilang.ts
#     dropped its Spanish track; reversed order dropped English), while the
#     QuickTime hazard it appeared to guard is already handled: movenc enables
#     exactly one audio track (tkhd 0x0003/0x0002/0x0002 parsed on a 3-audio
#     build, bench 2026-08-13 — precisely TN3177). Dropping tracks buys nothing
#     for playability; `layouts` stays as the opt-in curation flag) ---
# The selection logic lives in remux.sh; mov.sh consumes its plan via
# --print-plan (RMX_PLAN + RMX_T machine rows) instead of duplicating it. The
# old classifier read a:0 only — the FLAC-5.1 + MP2-stereo source classified
# 'pcm' off the FLAC and silently dropped track 2 (the transcript-1 defect).
PLANOUT=$(bash "$SELF_DIR/remux.sh" "$IN" "$OUT" --audio-keep "$AKEEP" --print-plan 2>&1 || true)
KEPT=$(printf '%s\n' "$PLANOUT" | sed -n 's/^RMX_PLAN .*kept=\([^ ]*\).*/\1/p' | head -1)
DROPPED=$(printf '%s\n' "$PLANOUT" | sed -n 's/^RMX_PLAN .*dropped=\([^ ]*\).*/\1/p' | head -1)
[ "$KEPT" = none ] && KEPT=""
[ "$DROPPED" = none ] && DROPPED=""
trkinfo () {  # $1 = 1 for kept rows, 0 for dropped -> "ord:codec:layout,..."
  printf '%s\n' "$PLANOUT" | awk -v w="$1" '$1=="RMX_T"{
      o=""; k=""; c=""; l=""
      for(i=2;i<=NF;i++){ eq=index($i,"="); key=substr($i,1,eq-1); v=substr($i,eq+1)
        if(key=="ord")o=v; else if(key=="keep")k=v; else if(key=="codec")c=v; else if(key=="layout")l=v }
      if(k==w){ printf "%s%s:%s:%s", s, o, c, l; s="," }
    }'
}
KINFO=$(trkinfo 1); DINFO=$(trkinfo 0)
NKEPT=0; [ -n "$KEPT" ] && NKEPT=$(printf '%s' "$KEPT" | awk -F, '{print NF}')

# MODE: copy (native) | dual (preserve original as track 2) | pcm (can't
# preserve in MOV) | multi (several layouts survive) | none. The codec decision
# tables live in native_c/mode_for at the top of this file (WO 3.1:
# pcm_bluray/pcm_dvd route to pcm there, never to a dead-on-arrival copy).
if [ "$NKEPT" -eq 0 ]; then MODE=none
elif [ "$NKEPT" -eq 1 ] && [ "$KEPT" = 0 ]; then
  c0=${KINFO#0:}; c0=${c0%%:*}
  MODE=$(mode_for "$c0")
  [ "$ALWAYS" -eq 1 ] && [ "$MODE" = copy ] && MODE=dual  # --always-dual upgrades native -> dual
else MODE=multi; fi

AUDV=""
case "$MODE" in
  dual)
    # dual-track.sh bypasses remux.sh, so announce the plan (incl. any drops) here
    printf '%s\n' "$PLANOUT" | grep -E '^(-- audio|   KEEP|\*\* WARN)' || true
    echo "-- audio a:0 not QuickTime-native -> dual-track (PCM access + original preserved) --"
    bash "$SELF_DIR/dual-track.sh" "$IN" "$OUT"; AUDV="--audio" ;;
  pcm)
    echo "-- audio a:0 can't be preserved in MOV -> single PCM access track --"
    echo "   (to keep the original bitstream, deliver as MP4/MKV instead; see references/ingest-compatibility.md)"
    bash "$SELF_DIR/remux.sh" "$IN" "$OUT" --audio pcm --audio-keep "$AKEEP" ;;
  multi)
    echo "-- $NKEPT audio tracks survive the '$AKEEP' policy --"
    nonnative=0
    for e in $(printf '%s' "$KINFO" | tr ',' ' '); do
      c=${e#*:}; c=${c%%:*}; native_c "$c" || nonnative=1
    done
    if [ "$nonnative" -eq 1 ]; then
      echo "   note: in the multi-track shape, non-native tracks land as PCM ACCESS"
      echo "   audio while QT-native tracks copy bit-exact (remux.sh --audio auto"
      echo "   decides per kept track, WO 3.2); non-native original bitstreams are"
      echo "   NOT preserved in this file (the dual-track original-preserving pair"
      echo "   is a single-layout deliverable — run scripts/dual-track.sh on the"
      echo "   source for the layout you need, or keep the source container for"
      echo "   provenance)."
    fi
    [ "$ALWAYS" -eq 1 ] && echo "   note: --always-dual applies to the single-track dual route, not the multi-track shape."
    # no --audio flag ON PURPOSE (WO 3.2): remux.sh's per-track auto IS the
    # promise above — QT-native tracks copy bit-exact, everything else lands
    # as PCM access. Pre-3.2 this call copied AC-3 through while the banner
    # promised PCM access (entry 1); a blanket --audio pcm would instead
    # decode already-native AAC for nothing.
    bash "$SELF_DIR/remux.sh" "$IN" "$OUT" --audio-keep "$AKEEP" ;;
  none)
    echo "-- no audio (or none kept) -> pure copy --"
    bash "$SELF_DIR/remux.sh" "$IN" "$OUT" --audio copy --audio-keep "$AKEEP" ;;
  copy)
    echo "-- audio a:0 is QuickTime-native -> pure copy --"
    bash "$SELF_DIR/remux.sh" "$IN" "$OUT" --audio copy --audio-keep "$AKEEP" ;;
esac

apply_metadata "$OUT" || { rc=$?; trim_cleanup "$rc"; exit "$rc"; }

# --signaling always: it is demux-only (a handful of ffprobe reads), untagged
# fields compare unknown==unknown cleanly, and it now also guards SAR/pasp —
# which anamorphic broadcast carries even when color is untagged (macro review:
# the old color-gated trigger would have skipped the pasp check exactly there)
SIG="--signaling"

echo "-- verify --"
set +e
o=$(bash "$SELF_DIR/verify.sh" "$IN" "$OUT" $FULL $AUDV $SIG 2>&1); rc=$?
set -e
printf '%s\n' "$o" | sed 's/^/   /'

case "$o" in *">> OK"*) rc=0;; *">> REVIEW"*) rc=10;; *) rc=1;; esac

# --- post-build playability (WO 4.1): the demoted 4:2:2 gate's empirical half.
# Only when a pre-build fact made it due — the contribution profile (yuv422p*),
# or since WO 5.1 a class outside the measured-native matrix (PR_VNATIVE
# variant/no) — and only on a build worth blessing (never on FAIL — nothing
# verified to test). FAIL verdict or an unverifiable platform -> 10 REVIEW,
# never a silent OK; the verdict self-dates its macOS via playable-check.sh
# (Ground Rule 6).
if [ "$PLAYCHECK_DUE" -eq 1 ] && [ "$rc" -ne 1 ] && [ -f "$OUT" ]; then
  # WO-B (2026-08-15): a contribution profile gets the FIDELITY storey on top of
  # the thumbnail floor — two real broadcast 4:2:2 masters false-greened the
  # thumbnail-only check on macOS 26.6.1 (rendered, destroyed); renders !=
  # renders correctly, so this class compares the AVFoundation render against
  # the ffmpeg reference (SSIM). The PR_VNATIVE variant/no arms stay thumbnail-only.
  PC_FID=""
  if [ "$PLAYCHECK_WHY" = "contribution profile" ]; then PC_FID="--fidelity"; fi
  if [ -n "$PC_FID" ]; then
    echo "-- playability ($PLAYCHECK_WHY: prove, don't guess — thumbnail floor + AVFoundation-vs-ffmpeg fidelity SSIM) --"
  else
    echo "-- playability ($PLAYCHECK_WHY: prove, don't guess) --"
  fi
  playability_verdict "$OUT" ${PC_FID:+"$PC_FID"}
  case "$PLAY_VERDICT" in
    fail)
      rc=10
      echo "   -> AVFoundation cannot decode THIS build correctly on THIS macOS: REVIEW."
      echo "      The file itself is a verified lossless NLE/archival master (IINA/VLC/mpv"
      echo "      decode it) — what failed is QuickTime's render, and the next rung is a"
      echo "      LOSSLESS CONTAINER SWAP, not a re-encode (D2, 1.13)."
      # THE CONTAINER-SWAP RUNG (D2): before 1.13 every fidelity FAIL named
      # Rung 4 and nothing else, while the measured remedy for this exact class
      # (2026-08-15, 21 GB MPEG-2 4:2:2 capture) was the same bitstream in an
      # MP4 — SSIM 0.9175+ on the timestamps that failed as .mov.
      if [ "$MP4SWAP" -eq 1 ]; then
        echo "-- container swap (--mp4-swap) --"
        set +e; bash "$SELF_DIR/mp4-swap.sh" "$IN" "${OUT%.*}.mp4" $FULL | sed 's/^/   /'; swrc=${PIPESTATUS[0]}; set -e
        case "$swrc" in
          0)  echo "   >> the CONTAINER SWAP WORKS: ${OUT%.*}.mp4 is verified lossless AND renders"
              echo "      correctly. The .mov beside it is the same bitstream in the container"
              echo "      AVFoundation mis-dispatches; ship the .mp4, keep or delete the .mov." ;;
          10) echo "   >> the container swap built and verified but its own render is not proven"
              echo "      (above) — see ${OUT%.*}.mp4." ;;
          *)  echo "   >> the container swap did not produce a verified artifact (above). The"
              echo "      container axis is exhausted; next is stsd surgery (mp4v+esds inside a"
              echo "      .mov via MP4Box/Bento4 — spec-legal, unbenched) or Rung 4." ;;
        esac
      else
        echo "      Take the swap:  scripts/mp4-swap.sh \"$IN\" \"${OUT%.*}.mp4\""
        echo "      (or re-run this command with --mp4-swap to have it done automatically;"
        echo "       nothing writes a second deliverable unless you ask). If the swap also"
        echo "       fails, THEN Rung 4 (scripts/rung4.sh, operator-attested re-encode —"
        echo "       recipes in references/delivery-encode.md)."
      fi
      ;;
    skip)
      rc=10
      echo "   -> playability unverified on this platform: REVIEW — this class's output"
      echo "      ($PLAYCHECK_WHY) must be proven on the target Mac"
      echo "      (scripts/playable-check.sh OUT)."
      ;;
  esac
fi

echo
echo "MOV_SUMMARY mode=$MODE out=$OUT audio_kept=${KINFO:-none} audio_dropped=${DINFO:-none} idr_trim=$IDRTRIM"   # machine-readable
case "$rc" in
  0)  trim_cleanup 0;  echo ">> DONE: $OUT — $READY_TAG, verified lossless${AUDV:+ + dual-track aligned}."; exit 0 ;;
  10) trim_cleanup 10; echo ">> REVIEW: $OUT written; verify wants a closer look (above). Source untouched."; exit 10 ;;
  *)  trim_cleanup 1;  echo ">> FAIL: see verify output above. Source untouched; $OUT is unverified."; exit 1 ;;
esac

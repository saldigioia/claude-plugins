#!/usr/bin/env bash
# mov.sh — the "/mov" shortcut: one call from any capture to a QuickTime-ready
# .mov, lossless-first. Probe -> build the right thing -> verify -> report.
# Video is ALWAYS stream-copied (bit-identical); this never re-encodes video and
# never touches or deletes the source.
#
# Usage: scripts/mov.sh INPUT [OUTPUT.mov] [--always-dual] [--full] [--force-backhaul]
#                       [--audio-keep all|first|layouts|IDX[,IDX...]] [metadata flags]
#   OUTPUT         default: <input dir>/<input base>.mov
#                  (<base>.qt.mov if the input is itself a .mov, so the source is safe)
#   --always-dual  build the dual-track even when the source audio already plays in
#                  QuickTime (the plugin's "always dual-track" default deliverable)
#   --audio-keep   which audio tracks survive (QTFF audit 5-2c; default: layouts —
#                  distinct channel layouts are distinct deliverables, duplicate
#                  layouts curated lossless > lossy-high > lossy-low, every drop
#                  announced; 'first' reproduces the historical a:0-only behavior)
#   --full         archival sign-off: pass --full to verify.sh (whole-file decode)
#   --force-backhaul  run the build even when the backhaul refusal gate fires
#                  (exit 11 below) — e.g. to build a verified lossless master that
#                  will not play in QuickTime, or to collect failure evidence
#   metadata (OPT-IN — NOTHING is tagged unless you pass one of these explicitly):
#     --title --description --author --date --copyright --comment --keywords
#     --key NAME=VALUE  --keep-chapters
#     -> embedded in proper QuickTime format via metadata.sh (and the generic chapter
#        "menu" dropped). Never applied automatically.
#
# AUDIO POLICY — dual-track only when needed (classified by QuickTime PLAYABILITY,
# not by whether the codec merely muxes into MOV):
#   QuickTime-native (AAC / ALAC / MP3 / PCM / E-AC-3) -> copied as-is, single track
#                                                         (E-AC-3 = Dolby Digital Plus,
#                                                          plays natively in modern QuickTime)
#   not native but MOV-copyable (AC-3 / DTS / MP2)     -> DUAL-TRACK: PCM "access"
#                                                         track 1 (always plays) +
#                                                         original copied bit-exact track 2
#   not native and not MOV-copyable (FLAC/Opus/TrueHD) -> single PCM access track;
#                                                         original CANNOT be preserved in
#                                                         MOV (keep MKV/MP4 if you need it)
#   none                                              -> video-only copy
#
# Field-coded (PAFF) H.264 is routed via auto.sh by timestamp profile:
# pair-timestamped / reordered streams get the pair-mate PTS fill
# (pairfill-paff.sh — dual-track built in, original audio preserved bit-exact);
# only a no-reorder stream gets the elementary rebuild, and THAT path decodes
# audio to PCM (original not preserved — manual route via
# references/timeline-repair.md + references/dual-track-quicktime.md if needed).
#
# Exit: 0 = verified OK; 10 = REVIEW (written, look closer); 1 = FAIL; 2 = usage;
#       11 = REFUSED (backhaul profile — this source cannot honestly deliver a
#            QuickTime-ready MOV; the refusal names the routes out).
set -euo pipefail

IN="${1:?usage: mov.sh INPUT [OUTPUT.mov] [--always-dual] [--full] [--force-backhaul] [--audio-keep POLICY] [metadata flags]}"; shift
OUT=""; ALWAYS=0; FULL=""; MDARGS=(); AKEEP=layouts; FORCE_BACKHAUL=0
# optional positional OUTPUT (the next arg, only if it isn't a --flag)
if [ "${1:-}" != "" ] && [ "${1#--}" = "${1:-}" ]; then OUT="$1"; shift; fi
while [ $# -gt 0 ]; do case "$1" in
  --always-dual) ALWAYS=1; shift;;
  --full)        FULL="--full"; shift;;
  --force-backhaul) FORCE_BACKHAUL=1; shift;;
  --audio-keep)  AKEEP="${2:?--audio-keep needs a value}"; shift 2;;
  --audio-keep=*) AKEEP="${1#*=}"; shift;;
  # OPT-IN metadata: collected and passed verbatim to metadata.sh after the build
  --title|--description|--author|--date|--creationdate|--copyright|--comment|--keywords|--key)
                 MDARGS+=("$1" "${2?need a value for $1}"); shift 2;;
  --keep-chapters) MDARGS+=("$1"); shift;;
  *) echo "unknown opt: $1" >&2; exit 2;;
esac; done
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

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
  mv -f "$1" "$1.premeta"
  local rc; set +e; bash "$SELF_DIR/metadata.sh" "$1.premeta" "$1" "${MDARGS[@]}" | sed 's/^/   /'; rc=${PIPESTATUS[0]}; set -e
  [ "$rc" -eq 0 ] || { echo ">> metadata step failed (rc=$rc); untagged build kept at $1.premeta" >&2; return "$rc"; }
  rm -f "$1.premeta"
}

# probe once; consume the structured KEY=VAL (single source of truth). The grep
# whitelists PR_/PF_ lines so a stray line can never become code via eval.
eval "$(bash "$SELF_DIR/probe.sh" "$IN" --kv | grep -E '^(PR|PF)_[A-Z0-9_]+=')"
echo "== mov: $IN -> $OUT =="
echo "   video=$PR_VCODEC  audio=$PR_ACODEC  paff=$PF_PAFF"

# --- backhaul refusal gate (exit 11): move the verdict the old pipeline reached
# after a full mux + resync + failed verify to the cheapest possible moment.
#   PRIMARY — QT-UNDECODABLE: yuv422p on MPEG-2 OR H.264. AVFoundation has NO
#   working 4:2:2 decode path for either contribution mastering profile:
#   * MPEG-2 4:2:2 — controlled comparison 2026-07-30: a 4:2:2 MOV with a
#     pristine, fully-verified timeline distorts in QuickTime exactly like the
#     failed builds, while the Main/4:2:0 sibling plays perfectly.
#   * H.264 High 4:2:2 — controlled slice test 2026-07-31 (2017 feed, macOS
#     26.5.2): the 4:2:2 slice STALLS qlmanage (the undecodable-variant hang
#     signature), the identical content re-encoded 4:2:0 renders instantly.
#   No container surgery can supply a missing decoder — one instant ffprobe
#   field decides, before the PAFF ladder can spend a multi-GB build.
#   SECONDARY — TIMELINE ROT (buildability): mpegts + mpeg2video + forward gaps
#   + non-monotonic DTS, whole-file and demux-only (~1 min on a 12 GB capture).
#   On that class the copy mux invents DTS (confession hard stop) and a resync
#   build leaves near-zero sample durations that verify gate (d) rightly fails.
#   Forward gaps ALONE do not refuse — that class rebuilds (the 2008 recovery);
#   and an H.264 TS with gaps still rides the existing PAFF/resync machinery.
backhaul_routes () {
  echo "   Honest routes out (the source stays TS/MKV — health-checked, never doomed):"
  echo "     keep     the source as-is — it is already the archival master; prove its"
  echo "              health: scripts/ts-health.sh IN  (transport, timestamps, seek)"
  echo "     playback ffmpeg -i IN -map 0:v:0 -map '0:a?' -c copy OUT.mkv"
  echo "              (lossless; Matroska stores per-block timestamps, so the timeline"
  echo "               survives honestly; plays in IINA/VLC/mpv) — then"
  echo "              scripts/ts-health.sh OUT.mkv to prove the copy's timeline intact"
  echo "     rung4    scripts/rung4.sh — operator-attested re-encode, the ONLY"
  echo "              sanctioned path to a true QuickTime-native deliverable"
  echo "   Override (run the build + verify anyway): --force-backhaul"
}
if [ "$FORCE_BACKHAUL" -eq 0 ] && [ "${PR_PIX_FMT:-}" = yuv422p ]; then
  case "$PR_VCODEC" in mpeg2video|h264)
    echo ">> REFUSED: QT-UNDECODABLE PROFILE — $PR_VCODEC 4:2:2 (pix_fmt yuv422p)."
    echo "   AVFoundation/QuickTime has no 4:2:2 decode path for this codec: a"
    echo "   bit-identical, verify-green MOV of this source will not play in QuickTime"
    echo "   (MPEG-2 4:2:2 distorts; H.264 High 4:2:2 stalls the decoder — both verified"
    echo "   against 4:2:0 controls). FFmpeg players — IINA/VLC/mpv — decode it fine."
    echo "   No lossless remux can keep the QuickTime-ready promise here."
    backhaul_routes
    echo "   (--force-backhaul runs the normal build + verify: when the timeline is"
    echo "    clean the result is a legitimate verified lossless NLE/archival master —"
    echo "    it just will not play in QuickTime.)"
    echo "MOV_REFUSED profile=qt-undecodable vcodec=$PR_VCODEC pix_fmt=${PR_PIX_FMT:-?}"   # machine-readable
    exit 11
    ;;
  esac
fi
if [ "$FORCE_BACKHAUL" -eq 0 ] && [ "$PR_VCODEC" = mpeg2video ]; then
  case "${PR_CONTAINER:-}" in *mpegts*)
    echo "   mpegts/mpeg2video -> backhaul timeline scan (whole file, demux-only)..."
    . "$SELF_DIR/lib-paff.sh"
    eval "$(disc_scan "$IN")"
    if [ "${DISC_COUNT:-0}" -ge 1 ] && [ $(( ${DISC_BACK:-0} + ${DISC_DUP:-0} )) -ge 1 ]; then
      echo ">> REFUSED: BACKHAUL TIMELINE ROT — ${DISC_COUNT} forward timestamp gap(s)"
      echo "   (~${DISC_MISSING}s dropped, first @ ${DISC_FIRST}s) PLUS non-monotonic DTS"
      echo "   (whole-file: backward=${DISC_BACK:-0} duplicate=${DISC_DUP:-0}). On this class a plain"
      echo "   copy makes the MOV muxer invent timing (mux-confession hard stop) and a"
      echo "   resync build leaves near-zero sample durations that verify gate (d)"
      echo "   correctly fails — knowable now, before a multi-gigabyte build."
      backhaul_routes
      echo "MOV_REFUSED profile=timeline-rot vcodec=$PR_VCODEC disc=${DISC_COUNT:-0} back=${DISC_BACK:-0} dup=${DISC_DUP:-0}"   # machine-readable
      exit 11
    fi
    echo "   backhaul scan clear (gaps=${DISC_COUNT:-0} back=${DISC_BACK:-0} dup=${DISC_DUP:-0}) -> continuing."
    ;;
  esac
fi
# a FORCED build of the QT-undecodable profile must never be reported as
# "QuickTime-ready" — the verify gates prove losslessness, not decodability
READY_TAG="QuickTime-ready"
if [ "$FORCE_BACKHAUL" -eq 1 ] && [ "${PR_PIX_FMT:-}" = yuv422p ]; then
  case "$PR_VCODEC" in mpeg2video|h264)
    echo "   NOTE: --force-backhaul on a QT-undecodable profile ($PR_VCODEC 4:2:2) — building"
    echo "   a lossless MASTER; QuickTime will NOT play it (IINA/VLC/mpv and NLEs will)."
    READY_TAG="NOT QuickTime-playable ($PR_VCODEC 4:2:2) — lossless master"
    ;;
  esac
fi

# gate verdict propagates: every child that writes a .mov (auto/remux/rebuild/
# pairfill) carries its own backhaul_gate, so a cleared or force-approved front
# door must say so — otherwise the child would re-refuse (or re-scan) a source
# this gate already decided.
[ "$FORCE_BACKHAUL" -eq 1 ] && export RTM_FORCE_BACKHAUL=1
export RTM_BACKHAUL_GATED=1

# --- field-coded: hand the timeline repair to the tested ladder driver ---
if [ "$PF_PAFF" = yes ]; then
  echo "   field-coded (PAFF) -> timeline repair via auto.sh (routed by timestamp profile:"
  echo "   pair-fill keeps real PTS + original audio; the rebuild decodes audio to PCM)"
  if [ "${PF_HALF_TS:-no}" = no ] && [ "${PF_REORDER:-no}" = yes ]; then
    # full-TS reordered PAFF goes through auto's COPY rung, whose audio policy is
    # single-track (auto is the ladder driver, not the deliverable builder) — so
    # the /mov dual-track promise does not apply on this one path. Say so (5e).
    echo "   note: this profile rides the copy rung — audio lands single-track (auto.sh"
    echo "   policy). For the dual-track deliverable, run scripts/dual-track.sh on the"
    echo "   source after this verifies OK (same copy mux + PCM access track)."
  fi
  [ "$ALWAYS" -eq 1 ] && echo "   note: --always-dual does not apply on the PAFF path — audio policy comes from the repair rung (pairfill dual-tracks non-native codecs by itself)."
  [ "$AKEEP" != layouts ] && echo "   note: --audio-keep does not apply on the PAFF path — audio policy comes from the repair rung (a:0; pairfill warns on multi-track sources)."
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
  exit "$rc"
fi

# --- classify audio from the FULL track set (QTFF audit 5-2c; gate ③ approved
#     2026-07-26: layouts is the default keep policy) ---
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
# preserve in MOV) | multi (several layouts survive) | none
native_c () { case "$1" in aac|alac|mp3|pcm_*|eac3) return 0;; *) return 1;; esac; }
if [ "$NKEPT" -eq 0 ]; then MODE=none
elif [ "$NKEPT" -eq 1 ] && [ "$KEPT" = 0 ]; then
  c0=${KINFO#0:}; c0=${c0%%:*}
  case "$c0" in
    aac|alac|mp3|pcm_*|eac3) MODE=copy ;;                 # plays natively in QuickTime (eac3 = DD+)
    ac3|dts|dca|mp2|mp1)     MODE=dual ;;                 # not native, but MOV-copyable -> keep original via dual-track
    *)                       MODE=pcm  ;;                 # flac/opus/truehd/...: original not MOV-copyable
  esac
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
    echo "-- $NKEPT audio tracks survive the '$AKEEP' policy (distinct deliverables) --"
    nonnative=0
    for e in $(printf '%s' "$KINFO" | tr ',' ' '); do
      c=${e#*:}; c=${c%%:*}; native_c "$c" || nonnative=1
    done
    if [ "$nonnative" -eq 1 ]; then
      echo "   note: in the multi-track shape, non-native tracks land as PCM ACCESS"
      echo "   audio; their original bitstreams are NOT preserved in this file (the"
      echo "   dual-track original-preserving pair is a single-layout deliverable —"
      echo "   run scripts/dual-track.sh on the source for the layout you need, or"
      echo "   keep the source container for provenance)."
    fi
    [ "$ALWAYS" -eq 1 ] && echo "   note: --always-dual applies to the single-track dual route, not the multi-track shape."
    bash "$SELF_DIR/remux.sh" "$IN" "$OUT" --audio-keep "$AKEEP" ;;
  none)
    echo "-- no audio (or none kept) -> pure copy --"
    bash "$SELF_DIR/remux.sh" "$IN" "$OUT" --audio copy --audio-keep "$AKEEP" ;;
  copy)
    echo "-- audio a:0 is QuickTime-native -> pure copy --"
    bash "$SELF_DIR/remux.sh" "$IN" "$OUT" --audio copy --audio-keep "$AKEEP" ;;
esac

apply_metadata "$OUT" || exit $?

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

echo
echo "MOV_SUMMARY mode=$MODE out=$OUT audio_kept=${KINFO:-none} audio_dropped=${DINFO:-none}"   # machine-readable
case "$o" in
  *">> OK"*)     echo ">> DONE: $OUT — $READY_TAG, verified lossless${AUDV:+ + dual-track aligned}."; exit 0 ;;
  *">> REVIEW"*) echo ">> REVIEW: $OUT written; verify wants a closer look (above). Source untouched."; exit 10 ;;
  *)             echo ">> FAIL: see verify output above. Source untouched; $OUT is unverified."; exit 1 ;;
esac

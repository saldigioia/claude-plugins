#!/usr/bin/env bash
# mov.sh — the "/mov" shortcut: one call from any capture to a QuickTime-ready
# .mov, lossless-first. Probe -> build the right thing -> verify -> report.
# Video is ALWAYS stream-copied (bit-identical); this never re-encodes video and
# never touches or deletes the source.
#
# Usage: scripts/mov.sh INPUT [OUTPUT.mov] [--always-dual] [--full]
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
# Exit: 0 = verified OK; 10 = REVIEW (written, look closer); 1 = FAIL; 2 = usage.
set -euo pipefail

IN="${1:?usage: mov.sh INPUT [OUTPUT.mov] [--always-dual] [--full] [--audio-keep POLICY] [metadata flags]}"; shift
OUT=""; ALWAYS=0; FULL=""; MDARGS=(); AKEEP=layouts
# optional positional OUTPUT (the next arg, only if it isn't a --flag)
if [ "${1:-}" != "" ] && [ "${1#--}" = "${1:-}" ]; then OUT="$1"; shift; fi
while [ $# -gt 0 ]; do case "$1" in
  --always-dual) ALWAYS=1; shift;;
  --full)        FULL="--full"; shift;;
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
  *">> OK"*)     echo ">> DONE: $OUT — QuickTime-ready, verified lossless${AUDV:+ + dual-track aligned}."; exit 0 ;;
  *">> REVIEW"*) echo ">> REVIEW: $OUT written; verify wants a closer look (above). Source untouched."; exit 10 ;;
  *)             echo ">> FAIL: see verify output above. Source untouched; $OUT is unverified."; exit 1 ;;
esac
